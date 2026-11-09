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

    @Test func anUnreadableSourceListIsCopiedAsideAndNeverCommitted() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appending(path: "catalog-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = GitStoreService(storeURL: storeURL, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        let fileURL = storeURL.appending(path: "catalog-sources.json")
        let damaged = Data("{ not json".utf8)
        for _ in 0..<2 {
            try damaged.write(to: fileURL)
            let sources = CatalogSourceStore(fileURL: fileURL, tools: .real(isDemoOn: { false }))
            #expect(sources.customSources.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path), "set aside, so a save can't overwrite it")
        }
        // Each one kept, bytes intact; the second didn't replace the first.
        let copies = try FileManager.default.contentsOfDirectory(atPath: storeURL.path)
            .filter { $0.hasPrefix("catalog-sources.json.unreadable-") }
        #expect(copies.count == 2)
        for copy in copies {
            #expect(try Data(contentsOf: storeURL.appending(path: copy)) == damaged)
        }
        // Kept on this Mac only: never committed, so never shared with a team.
        _ = try await store.commitAll(message: "After an unreadable file")
        let tracked = try StoreSecretCheckTests.git(["ls-files"], in: storeURL)
        #expect(!tracked.contains("unreadable"))
    }
}
