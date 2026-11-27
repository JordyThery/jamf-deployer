import Foundation
import Testing
@testable import Jamf_Deployer

/// Adding or removing a catalog source is recorded in the store, on a
/// throwaway store in the temporary folder.
@MainActor
@Suite("Catalog source changes")
struct CatalogSourceStoreTests {
    @Test func addingAndRemovingASourceIsCommitted() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appending(path: "catalog-store-\(UUID().uuidString)")
        let folder = FileManager.default.temporaryDirectory.appending(path: "catalog-folder-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = GitStoreService(storeURL: storeURL, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()

        let sources = CatalogSourceStore(fileURL: storeURL.appending(path: "catalog-sources.json"), tools: .real(isDemoOn: { false }))
        var messages: [String] = []
        sources.onChange = { messages.append($0) }

        let added = try sources.addSource(name: "My Blocks", folderURL: folder)
        #expect(messages == ["Add catalog source “My Blocks”"])
        // What the deploy service does with each change.
        #expect(try await store.commitAll(message: messages[0]) == true)
        let tracked = try StoreSecretCheckTests.git(["show", "HEAD:catalog-sources.json"], in: storeURL)
        #expect(tracked.contains("My Blocks"))

        sources.removeSource(added)
        #expect(messages.last == "Remove catalog source “My Blocks”")
        #expect(try await store.commitAll(message: messages[1]) == true)
        let log = try StoreSecretCheckTests.git(["log", "--format=%s"], in: storeURL)
        #expect(log.contains("Add catalog source “My Blocks”"))
        #expect(log.contains("Remove catalog source “My Blocks”"))
        #expect(try StoreSecretCheckTests.git(["status", "--porcelain"], in: storeURL).isEmpty)

        // Removing a source that is not there changes nothing.
        sources.removeSource(added)
        #expect(messages.count == 2)
    }

    @Test func anUnreadableSourceListStaysInPlaceAndIsNeverCommittedAway() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appending(path: "catalog-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = GitStoreService(storeURL: storeURL, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        let fileURL = storeURL.appending(path: "catalog-sources.json")
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: fileURL)
        _ = try await store.commitAll(message: "A damaged list")

        let sources = CatalogSourceStore(fileURL: fileURL, tools: .real(isDemoOn: { false }))
        #expect(sources.customSources.isEmpty)
        #expect(sources.isListUnreadable)
        #expect(try Data(contentsOf: fileURL) == damaged, "left in place, bytes intact")
        // The next store commit doesn't stage a deletion, so a team sync can't publish one.
        _ = try await store.commitAll(message: "After an unreadable file")
        #expect(try StoreSecretCheckTests.git(["ls-files"], in: storeURL).contains("catalog-sources.json"))
        #expect(try StoreSecretCheckTests.git(["status", "--porcelain"], in: storeURL).isEmpty)
    }

    /// A list written by a newer app (a source kind this one doesn't know)
    /// still loads, and saving keeps that source as it was.
    @Test func aSourceOfANewerKindLoadsAndIsKept() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "catalog-newer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appending(path: "catalog-sources.json")
        let id = UUID()
        try Data(#"[{"id":"\#(id.uuidString)","name":"Future","path":"/x","kind":"s3Bucket"}]"#.utf8).write(to: fileURL)

        let sources = CatalogSourceStore(fileURL: fileURL, tools: .real(isDemoOn: { false }))
        #expect(!sources.isListUnreadable)
        let future = try #require(sources.customSources.first)
        #expect(future.kind == .other("s3Bucket"))
        #expect(throws: CatalogSourceStore.NewerSourceKind.self) { _ = try sources.load(source: future) }
        _ = try sources.addSource(name: "Mine", folderURL: folder.appending(path: "blocks"))
        #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("s3Bucket"))
    }

    /// A list that can't be read stays as it is, and nothing is saved over it.
    @Test func anUnreadableSourceListThatCantBeCopiedIsNeverSavedOver() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "catalog-locked-\(UUID().uuidString)")
        let blocks = FileManager.default.temporaryDirectory.appending(path: "catalog-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appending(path: "catalog-sources.json")
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: fileURL)
        // A folder nothing can be written to.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: blocks)
        }

        let sources = CatalogSourceStore(fileURL: fileURL, tools: .real(isDemoOn: { false }))
        #expect(sources.isListUnreadable)
        #expect(sources.customSources.isEmpty)
        var messages: [String] = []
        sources.onChange = { messages.append($0) }

        // Writable again, so only the store's own refusal can keep the file intact.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(throws: CatalogSourceStore.ListUnreadable.self) {
            _ = try sources.addSource(name: "My Blocks", folderURL: blocks)
        }
        sources.removeSource(CatalogSourceStore.CustomSource(id: UUID(), name: "Gone", path: blocks.path))
        #expect(messages.isEmpty)
        #expect(try Data(contentsOf: fileURL) == damaged)

        // Once it reads again, saving works as before.
        try Data("[]".utf8).write(to: fileURL)
        sources.reload()
        #expect(!sources.isListUnreadable)
        _ = try sources.addSource(name: "My Blocks", folderURL: blocks)
        #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("My Blocks"))
    }

    @Test func theLatestReleaseIsTheNewestVersionTag() {
        let tags = ["v1.10.0", "v1.4.0-rc1", "wip", "v1.4.0", "v1.9.2", "v1.0.0"]
        #expect(GitCatalogManager.latestRelease(in: tags) == "v1.10.0")
        #expect(GitCatalogManager.latestRelease(in: ["v1.4.0", "v1.4.0-rc1", "zzz"]) == "v1.4.0")
        #expect(GitCatalogManager.latestRelease(in: ["1.2.0", "v1.1.9"]) == "1.2.0")
        #expect(GitCatalogManager.latestRelease(in: ["wip", "v2.0.0-beta"]) == nil)
        #expect(GitCatalogManager.latestRelease(in: ["v1.2", "v1.1.9"]) == "v1.2")
        #expect(GitCatalogManager.latestRelease(in: ["v1.3", "v1.2.9", "v1"]) == "v1.3")
        #expect(!GitCatalogManager.isReleaseTag("v1"))
        #expect(GitCatalogManager.ordered(tags) == ["v1.4.0-rc1", "wip", "v1.0.0", "v1.4.0", "v1.9.2", "v1.10.0"])
    }
}
