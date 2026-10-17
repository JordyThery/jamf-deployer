import Foundation
import Testing
@testable import DeployerKit

@Suite("Version comparison")
struct VersionComparisonTests {
    @Test(arguments: [
        ("1.1", "1.0", true),
        ("1.0", "1.1", false),
        ("1.0", "1.0", false),
        ("1.0.1", "1.0", true),
        ("1.0", "1.0.0", false),
        ("2.0", "1.9.9", true),
        ("0.10", "0.9", true),
    ])
    func comparesDotSeparatedVersions(candidate: String, installed: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: installed) == expected)
    }
}

@Suite("Update feed trust")
struct UpdateFeedTrustTests {
    @Test func acceptsGitHubHosts() {
        #expect(UpdateChecker.isTrustedHost(URL(string: "https://github.com/x/y/releases/download/v1/a.zip")!))
        #expect(UpdateChecker.isTrustedHost(URL(string: "https://objects.githubusercontent.com/a.zip")!))
    }

    @Test func rejectsOtherHostsAndSchemes() {
        #expect(!UpdateChecker.isTrustedHost(URL(string: "https://example.com/a.zip")!))
        #expect(!UpdateChecker.isTrustedHost(URL(string: "http://github.com/a.zip")!))
        #expect(!UpdateChecker.isTrustedHost(URL(string: "https://github.com.evil.example/a.zip")!))
    }
}

@Suite("JSON file store")
struct JSONFileTests {
    nonisolated struct Sample: Codable, Equatable {
        var name: String
        var date: Date
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deployerkit-tests/\(UUID().uuidString)/sample.json")
        let value = Sample(name: "tenant", date: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONFile.save(value, to: url)
        let loaded = try JSONFile.load(Sample.self, from: url)
        #expect(loaded == value)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
