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
    static let scriptPath = "tenants/00000000-0000-4000-9000-000000000001/adopted/support_files/scripts/ZZ Secret Scan Test.zsh"

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
        let store = GitStoreService(storeURL: url, tools: .real(isDemoOn: { false }))
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
                       to: "tenants/00000000-0000-4000-9000-000000000001/history/1/log.jsonl", in: url)
        // Ignored folders are not part of a commit and not checked.
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n",
                       to: "tenants/00000000-0000-4000-9000-000000000001/generated/x.sh", in: url)
        let paths = Set(try await store.unacknowledgedFindings().map(\.path))
        #expect(paths == [
            "catalog/blocks/captured/README.md",
            "tenants/00000000-0000-4000-9000-000000000001/history/1/log.jsonl",
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

    static let historyFolder = "tenants/00000000-0000-4000-9000-000000000001/history/20261101-120000"

    @Test("A finding in a deploy's history plan never stops a commit, but its log still does")
    func deployHistoryPlanDoesNotStopCommits() async throws {
        let (store, url) = try await Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: "\(Self.historyFolder)/plan.json", in: url)
        #expect(try await store.unacknowledgedFindings().count == 1, "it's still found, for the notice")
        #expect(try await store.commitAll(message: "Deploy") == true)
        #expect(try Self.git(["ls-files"], in: url).contains("history/20261101-120000/plan.json"))

        // The run's log is checked like any other file (review finding 1).
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: "\(Self.historyFolder)/log.jsonl", in: url)
        await #expect { try await store.commitAll(message: "Deploy") } throws: { error in
            guard case GitStoreService.GitError.possibleSecrets(let findings) = error else { return false }
            return findings.map(\.path) == ["\(Self.historyFolder)/log.jsonl"]
        }

        #expect(GitStoreService.isDeployHistoryPlan("\(Self.historyFolder)/plan.json"))
        #expect(!GitStoreService.isDeployHistoryPlan("\(Self.historyFolder)/log.jsonl"))
        #expect(!GitStoreService.isDeployHistoryPlan("\(Self.historyFolder)/tenant-snapshot.json"))
        #expect(!GitStoreService.isDeployHistoryPlan(Self.scriptPath))
        #expect(!GitStoreService.isDeployHistoryPlan("history/plan.json"))
        #expect(!GitStoreService.isDeployHistoryPlan("tenants/not-a-tenant/history/x/plan.json"))
    }

    @Test("Deploy history is masked by the app's own rules before it's written")
    func historyIsMaskedWhenWritten() throws {
        let plan = #"{"after":{"payloads":"<key>Password</key>\n<string>\#(Self.fakeScriptSecret)</string>","script":"PASSWORD=\"\#(Self.fakeScriptSecret)\""}}"#
        let masked = String(decoding: TenantDeployService.historyText(plan, path: "plan.json"), as: UTF8.self)
        #expect(!masked.contains("FAKE"))
        #expect(masked.contains(SecretScan.mask))
        #expect(SecretScan.scan(text: masked, path: "plan.json").isEmpty, "nothing left for the store check")
        #expect((try? JSONSerialization.jsonObject(with: Data(masked.utf8))) != nil, "still JSON")
        let log = "{\"@message\":\"curl -u admin:\(Self.fakeScriptSecret) https://example.com\"}\n"
        #expect(!String(decoding: TenantDeployService.historyText(log, path: "log.jsonl"), as: UTF8.self).contains("FAKE"))
    }

    @Test("The review marks several findings as not a secret at once")
    func bulkAcknowledgement() async throws {
        let (store, url) = try await Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let second = Self.scriptPath.replacingOccurrences(of: "ZZ Secret Scan Test", with: "ZZ Second")
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: Self.scriptPath, in: url)
        try Self.write("PASSWORD=\"\(Self.fakeScriptSecret)\"\n", to: second, in: url)
        let findings = try await store.unacknowledgedFindings()
        #expect(findings.count == 2)

        try await store.acknowledge(findings)
        #expect(try await store.unacknowledgedFindings().isEmpty)
        #expect(try await store.commitAll(message: "Adopt") == true)
        #expect(await store.acknowledgements().notSecrets.count == 2)
    }

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
