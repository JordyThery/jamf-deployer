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
        let store = GitStoreService(storeURL: storeURL, tools: .app)
        try await store.ensureRepo()

        let sources = CatalogSourceStore(fileURL: storeURL.appending(path: "catalog-sources.json"), tools: .app)
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
}
