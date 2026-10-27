import Foundation
import JamfDeployerCore

/// Fetches catalog sources from Git by release tag: one shallow checkout per
/// tag, cached under Application Support. Tags are immutable, so a cached
/// checkout never needs refreshing.
nonisolated enum GitCatalogManager {
    enum CatalogError: LocalizedError {
        case fetchFailed(String)
        case notACatalog
        case checkoutMissing(String)

        var errorDescription: String? {
            switch self {
            case .fetchFailed(let output):
                "The catalog source could not be fetched: \(output.prefix(200))"
            case .notACatalog:
                "The repository is not a building-block catalog (catalog.json missing at its root)."
            case .checkoutMissing(let tag):
                "Catalog tag \(tag) has not been downloaded yet. Check the network connection and try again."
            }
        }
    }

    /// Lists release tags on the remote, newest-style tags last.
    /// Runs off the caller's actor — `git ls-remote` goes to the network.
    static func availableTags(remote: String, tools: ToolDoorway) async throws -> [String] {
        try await Task.detached { try availableTagsSync(remote: remote, tools: tools) }.value
    }

    /// Shallow-clones one tag into the cache (no-op when already cached).
    /// Runs off the caller's actor — cloning goes to the network.
    static func fetchTag(remote: String, tag: String, into destination: URL, tools: ToolDoorway) async throws {
        try await Task.detached { try fetchTagSync(remote: remote, tag: tag, into: destination, tools: tools) }.value
    }

    private static func availableTagsSync(remote: String, tools: ToolDoorway) throws -> [String] {
        let output = try git(["ls-remote", "--tags", "--refs", "--", remote], in: nil, tools: tools)
        return output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "refs/tags/") else { return nil }
                return String(line[range.upperBound...])
            }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    private static func fetchTagSync(remote: String, tag: String, into destination: URL, tools: ToolDoorway) throws {
        if FileManager.default.fileExists(atPath: destination.appending(path: "catalog.json").path) {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try git(["clone", "--depth", "1", "--branch", tag, "--", remote, destination.path], in: nil, tools: tools)
        // The checkout is a snapshot; its git history is dead weight.
        try? FileManager.default.removeItem(at: destination.appending(path: ".git"))
        guard FileManager.default.fileExists(atPath: destination.appending(path: "catalog.json").path) else {
            try? FileManager.default.removeItem(at: destination)
            throw CatalogError.notACatalog
        }
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL?, tools: ToolDoorway) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let process = try tools.process(.git, executable: URL(filePath: "/usr/bin/git"), arguments: arguments,
                                        directory: directory, environment: environment)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CatalogError.fetchFailed(output)
        }
        return output
    }
}
