import Foundation
import Testing
import JamfDeployerCore
@testable import Jamf_Deployer

/// The secret check before every store commit and the one-time check of
/// existing stores, on a throwaway store in the temporary folder. Uses the
/// obviously fake values from the real jamformer test run.
@Suite("Store secret check")
struct StoreSecretCheckTests {
    static let fakeScriptSecret = "FAKE-NotARealSecret-123"
    static let scriptPath = "tenants/00000000-0000-4000-8000-000000000001/adopted/support_files/scripts/ZZ Secret Scan Test.zsh"

    /// jamformer's real output from the test run (terminal colours removed).
    static func jamformerLines() throws -> [String] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "JamfDeployerCore/Tests/JamfDeployerCoreTests/Fixtures/secret-scan/jamformer-output.txt")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map(JamformerRunner.stripTerminalNoise)
    }

    static func makeStore() async throws -> (GitStoreService, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "secret-store-\(UUID().uuidString)")
        let store = GitStoreService(storeURL: url)
        try await store.ensureRepo()
        return (store, url)
    }

    static func write(_ text: String, to path: String, in store: URL) throws {
        let file = store.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func jamformerFindingsAreReadAndNeverLogged() throws {
        let result = JamformerRunner.result(lines: try Self.jamformerLines(), exitCode: 0)
        #expect(result.secretFindings.map(\.location.line) == [18, 3])
        #expect(result.secretFindings.map(\.location.path) == [
            "support_files/macos_configuration_profiles/ZZ Secret Scan Test.mobileconfig",
            "support_files/scripts/ZZ Secret Scan Test.zsh",
        ])
        let log = result.logLines.joined(separator: "\n")
        #expect(!log.contains("FAKE"))
        #expect(log.contains("Line 18  (Password or secret in plist/XML configuration)"))
    }

    @Test func aPossibleSecretStopsTheCommit() async throws {
        let (store, url) = try await Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write("#!/bin/zsh\n# Fake values.\nPASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: Self.scriptPath, in: url)

        await #expect {
            try await store.commitAll(message: "Adopt")
        } throws: { error in
            guard case GitStoreService.GitError.possibleSecrets(let findings) = error else { return false }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            return findings == [SecretFinding(path: Self.scriptPath, line: 3, rule: "Password value in HCL attribute")]
                && !message.contains("FAKE")
        }
        // Nothing was committed: the file is still untracked.
        let tracked = try Self.git(["ls-files"], in: url)
        #expect(!tracked.contains("ZZ Secret Scan Test"))
    }

    @Test func notASecretIsStoredAsLocationAndRuleOnly() async throws {
        let (store, url) = try await Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: Self.scriptPath, in: url)
        let findings = try await store.unacknowledgedFindings()
        #expect(findings.count == 1)

        for finding in findings { try await store.acknowledge(finding) }
        #expect(try await store.commitAll(message: "Adopt") == true)

        let acknowledgements = try String(
            contentsOf: url.appending(path: GitStoreService.acknowledgementsFile), encoding: .utf8)
        #expect(acknowledgements.contains("ZZ Secret Scan Test.zsh"))
        #expect(acknowledgements.contains("Password value in HCL attribute"))
        #expect(!acknowledgements.contains("FAKE"))

        // A finding whose line moves is asked about again.
        try Self.write("# moved\nPASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: Self.scriptPath, in: url)
        #expect(try await store.unacknowledgedFindings().map(\.line) == [2])
    }

    @Test func theWholeStoreIsChecked() async throws {
        let (store, url) = try await Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // A block README captured before this check, and a history log line.
        try Self.write("## Secret scan findings\n\n- Line 3    FAKE***************-123  (Password value in HCL attribute)\n",
                       to: "catalog/blocks/captured/README.md", in: url)
        try Self.write(#"{"message":"client_secret = \"FAKE-NotARealSecret-123\""}"# + "\n",
                       to: "tenants/00000000-0000-4000-8000-000000000001/history/1/log.jsonl", in: url)
        // Ignored folders are not part of a commit and not checked.
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n",
                       to: "tenants/00000000-0000-4000-8000-000000000001/generated/x.sh", in: url)
        let paths = Set(try await store.unacknowledgedFindings().map(\.path))
        #expect(paths == [
            "catalog/blocks/captured/README.md",
            "tenants/00000000-0000-4000-8000-000000000001/history/1/log.jsonl",
        ])
    }

    @Test func theOneTimeCheckFindsEarlierVersions() async throws {
        let (store, url) = try await Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // A secret committed before the check existed, then removed.
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: Self.scriptPath, in: url)
        try Self.git(["add", "-A"], in: url)
        try Self.git(["-c", "user.name=t", "-c", "user.email=t@localhost", "commit", "-qm", "Old adopt"], in: url)
        try FileManager.default.removeItem(at: url.appending(path: Self.scriptPath))
        #expect(try await store.commitAll(message: "Remove") == true)

        let findings = try await store.fullCheck()
        #expect(findings == [GitStoreService.StoreFinding(
            finding: SecretFinding(path: Self.scriptPath, line: 1, rule: "Password value in HCL attribute"),
            inEarlierVersion: true)])
    }

    @discardableResult
    static func git(_ arguments: [String], in url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
