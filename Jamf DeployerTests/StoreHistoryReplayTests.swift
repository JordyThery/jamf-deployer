import Foundation
import Testing
import JTKit
@testable import Jamf_Deployer

/// Replays every tenant.json version in this Mac's own store history
/// (Application Support/Jamf Deployer/store) through Settings › Connections.
///
/// Read only: in the store it runs only `git rev-list` and `git cat-file`
/// (with optional locks off, so Git doesn't even refresh its index). Every
/// copy is loaded and saved in a temporary folder. Failures name only Git
/// object IDs, never what a tenant contains. Skipped on a Mac without a store.
@MainActor
@Suite("Store history replay")
struct StoreHistoryReplayTests {

    nonisolated static let storeURL = GitStoreService.storeURL

    nonisolated static var hasStoreHistory: Bool {
        FileManager.default.fileExists(atPath: storeURL.appending(path: ".git").path)
    }

    @Test(.enabled(if: hasStoreHistory, "No Jamf Deployer store with Git history on this Mac"))
    func everyVersionInTheStoreHistoryIsSavedBackByteForByte() throws {
        let listing = String(decoding: try Self.git("rev-list", "--all", "--objects", "--", "tenants"), as: UTF8.self)
        let objects = Set(listing.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[1].hasSuffix("/tenant.json") ? String(parts[0]) : nil
        }).sorted()

        var unreadable = [String]()
        var changedWithoutEdits = [String]()
        var renameChangedMore = [String]()
        for object in objects {
            let data = try Self.git("cat-file", "blob", object)
            guard (try? TenantConnectionTests.Workspace.decode(data)) != nil else {
                unreadable.append(object)
                continue
            }
            let workspace = try TenantConnectionTests.Workspace(files: [data])
            defer { workspace.clean() }
            let record = try #require(workspace.store.records.first)

            // saved back without changes: the same bytes
            try workspace.store.save(record)
            if try workspace.file(record.id) != data {
                changedWithoutEdits.append(object)
                continue
            }

            // renamed: only the name line changes
            var renamed = record
            renamed.connection.name = "Renamed Tenant"
            try workspace.store.save(renamed)
            let lines = TenantConnectionTests.changedLines(data, try workspace.file(record.id))
            let onlyName = lines.removed.count == 1 && lines.removed[0].hasPrefix("\"name\" : ")
                && lines.added == ["\"name\" : \"Renamed Tenant\","]
            if !onlyName {
                renameChangedMore.append(object)
            }
        }

        #expect(!objects.isEmpty, "The store history has no tenant.json versions.")
        // Bool checks only, so a failure never prints a tenant's contents
        #expect(unreadable.isEmpty, "Versions this version can't read (Git object IDs): \(unreadable)")
        #expect(changedWithoutEdits.isEmpty, "Versions not saved back byte for byte (Git object IDs): \(changedWithoutEdits)")
        #expect(renameChangedMore.isEmpty, "Versions where a rename changed more than the name line (Git object IDs): \(renameChangedMore)")
    }

    /// Runs a read-only Git command in the store and returns its output.
    private nonisolated static func git(_ arguments: String...) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", storeURL.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFailure(command: arguments.first ?? "", status: process.terminationStatus)
        }
        return data
    }

    private struct GitFailure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        var description: String { "git \(command) failed with status \(status)" }
    }
}
