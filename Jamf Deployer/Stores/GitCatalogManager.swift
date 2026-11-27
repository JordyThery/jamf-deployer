import Foundation
import JTKit
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
                "The catalog source couldn’t be fetched: \(output.prefix(200))"
            case .notACatalog:
                "The repository isn’t a building-block catalog (catalog.json missing at its root)."
            case .checkoutMissing(let tag):
                "Catalog tag \(tag) hasn’t been downloaded yet. Check the network connection and try again."
            }
        }
    }

    /// Lists the remote's tags: other tags first, then release tags
    /// (`vMAJOR.MINOR[.PATCH]`, with or without the v) oldest to newest.
    /// Runs off the caller's actor — `git ls-remote` goes to the network.
    static func availableTags(remote: String, tools: ToolDoorway) async throws -> [String] {
        try await Task.detached { try availableTagsSync(remote: remote, tools: tools) }.value
    }

    /// The newest release tag remote's tags hold, or nil. Prerelease tags
    /// (`v1.4.0-rc1`) and other names (`wip`) are never the latest release.
    static func latestRelease(remote: String, tools: ToolDoorway) async throws -> String? {
        latestRelease(in: try await availableTags(remote: remote, tools: tools))
    }

    static func latestRelease(in tags: [String]) -> String? {
        tags.filter(isReleaseTag).max { isNewer($1, than: $0) }
    }

    static func isReleaseTag(_ tag: String) -> Bool {
        tag.wholeMatch(of: /v?\d+\.\d+(\.\d+)?/) != nil
    }

    /// Other tags first (by name), then release tags by version.
    static func ordered(_ tags: [String]) -> [String] {
        let others = tags.filter { !isReleaseTag($0) }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        let releases = tags.filter(isReleaseTag).sorted { isNewer($1, than: $0) }
        return others + releases
    }

    /// JTKit's version comparison, without the tag's leading "v".
    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        func version(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
        return UpdateChecker.isNewer(version(candidate), than: version(current))
    }

    /// Shallow-clones one tag into the cache (no-op when already cached).
    /// Runs off the caller's actor — cloning goes to the network.
    static func fetchTag(remote: String, tag: String, into destination: URL, tools: ToolDoorway) async throws {
        try await Task.detached { try fetchTagSync(remote: remote, tag: tag, into: destination, tools: tools) }.value
    }

    private static func availableTagsSync(remote: String, tools: ToolDoorway) throws -> [String] {
        let output = try git(["ls-remote", "--tags", "--refs", "--", remote], in: nil, tools: tools)
        let tags = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "refs/tags/") else { return nil }
                return String(line[range.upperBound...])
            }
        return ordered(tags)
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
        let output = try GitCommand.run(arguments, in: directory, tools: tools)
        guard output.status == 0 else {
            throw CatalogError.fetchFailed(output.text)
        }
        return output.text
    }
}
