import Foundation
import Testing
import JamfDeployerCore
import JTKit
@testable import Jamf_Deployer

@Suite("Pinned component versions")
struct PinnedVersionTests {
    static var repoRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `NAME="value"` lines of Vendor/fetch.sh, where the versions are pinned.
    static func fetchPins() throws -> [String: String] {
        let text = try String(contentsOf: repoRoot.appending(path: "Vendor/fetch.sh"), encoding: .utf8)
        var pins: [String: String] = [:]
        for match in text.matches(of: /(?m)^([A-Z_]+_VERSION)="([^"]+)"/) {
            pins[String(match.1)] = String(match.2)
        }
        return pins
    }

    @Test("EngineInfo matches Vendor/fetch.sh")
    func engineInfoMatchesFetchScript() throws {
        let pins = try Self.fetchPins()
        #expect(pins["OPENTOFU_VERSION"] == EngineInfo.openTofuVersion)
        #expect(pins["JAMFPLATFORM_VERSION"] == EngineInfo.jamfPlatformProviderVersion)
        #expect(pins["JAMFPROTECT_VERSION"] == EngineInfo.jamfProtectProviderVersion)
        #expect(pins["JAMFPRO_VERSION"] == EngineInfo.jamfProProviderVersion)
        #expect(pins["JAMFORMER_VERSION"] == EngineInfo.jamformerVersion)
        #expect(pins["BACKEND_GIT_VERSION"] == EngineInfo.stateBackendVersion)
    }

    @Test("The workspace generator's default versions are the bundled ones")
    func generatorDefaultsMatch() {
        let input = WorkspaceInput(namePrefix: "", selections: [], providerVersion: EngineInfo.jamfPlatformProviderVersion)
        #expect(input.protectProviderVersion == EngineInfo.jamfProtectProviderVersion)
        #expect(input.jamfProProviderVersion == EngineInfo.jamfProProviderVersion)
    }
}

@Suite("State backend housekeeping")
struct StateBackendHousekeepingTests {
    static let backend = "/Applications/Jamf Deployer.app/Contents/Resources/Vendor/terraform-backend-git/terraform-backend-git"

    @Test("Only an orphaned copy of the bundled backend is stopped")
    func leftoverBackendVerdicts() {
        // Its app still runs (the installed app, while unit tests run): left alone.
        #expect(StateBackendService.leftoverVerdict(path: Self.backend, parent: 4242, parentIsAlive: { _ in true })
            == .ownedByARunningApp)
        // Adopted by launchd after a crash: stopped.
        #expect(StateBackendService.leftoverVerdict(path: Self.backend, parent: 1, parentIsAlive: { _ in true }) == .stop)
        #expect(StateBackendService.leftoverVerdict(path: Self.backend, parent: 4242, parentIsAlive: { _ in false }) == .stop)
        // Another program with that number, or none: never signalled.
        #expect(StateBackendService.leftoverVerdict(path: "/usr/bin/ssh", parent: 1, parentIsAlive: { _ in false }) == .gone)
        #expect(StateBackendService.leftoverVerdict(path: nil, parent: nil, parentIsAlive: { _ in false }) == .gone)
    }

    /// An OpenSSH private key's text with the given cipher (the rest is filler).
    static func openSSHKey(cipher: String) -> String {
        var data = Data("openssh-key-v1\0".utf8)
        let name = Data(cipher.utf8)
        withUnsafeBytes(of: UInt32(name.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(name)
        data.append(Data(repeating: 0, count: 32))
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(data.base64EncodedString(options: .lineLength64Characters))\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    @Test("Passphrase-protected keys are recognized")
    func encryptedKeys() {
        #expect(!StateBackendService.isPassphraseProtected(keyText: Self.openSSHKey(cipher: "none")))
        #expect(StateBackendService.isPassphraseProtected(keyText: Self.openSSHKey(cipher: "aes256-ctr")))
        #expect(StateBackendService.isPassphraseProtected(
            keyText: "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----\n"))
        #expect(!StateBackendService.isPassphraseProtected(
            keyText: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"))
    }

    @Test("SSH sign-in: the agent when it reaches the remote, else the unlocked key file alone")
    func sshEnvironment() throws {
        let plain = (path: "/Users/example/.ssh/id_ed25519", text: Self.openSSHKey(cipher: "none"))
        let locked = (path: "/Users/example/.ssh/id_rsa", text: Self.openSSHKey(cipher: "aes256-ctr"))

        // terraform-backend-git takes the agent whenever SSH_AUTH_SOCK is set:
        // the two are never passed together.
        // An agent whose keys reach the remote: the agent.
        #expect(try StateBackendService.sshEnvironment(agentSocket: "/tmp/agent", agentHasKeys: true, keys: [plain],
                                                       agentReachesRemote: { true })
            == ["SSH_AUTH_SOCK": "/tmp/agent"])
        // An agent holding only a key this remote doesn't take (a work key):
        // the unlocked key file, without the agent (R6).
        #expect(try StateBackendService.sshEnvironment(agentSocket: "/tmp/agent", agentHasKeys: true, keys: [plain],
                                                       agentReachesRemote: { false })
            == ["SSH_PRIVATE_KEY": plain.path])
        // An agent with keys and only a locked key file: the agent alone, never probed.
        #expect(try StateBackendService.sshEnvironment(agentSocket: "/tmp/agent", agentHasKeys: true, keys: [locked],
                                                       agentReachesRemote: { Issue.record("probed"); return false })
            == ["SSH_AUTH_SOCK": "/tmp/agent"])
        // An empty agent: the first key without a passphrase, without the agent.
        #expect(try StateBackendService.sshEnvironment(agentSocket: "/tmp/agent", agentHasKeys: false, keys: [locked, plain])
            == ["SSH_PRIVATE_KEY": plain.path])
        // Only locked keys and no agent keys: asked to add one to the agent.
        #expect(throws: StateBackendService.BackendError.self) {
            _ = try StateBackendService.sshEnvironment(agentSocket: "/tmp/agent", agentHasKeys: false, keys: [locked])
        }
        // No keys at all: the backend uses whatever the agent offers.
        #expect(try StateBackendService.sshEnvironment(agentSocket: nil, agentHasKeys: false, keys: []) == [:])
    }
}

/// Answers GitHub's "latest release" requests for the component check.
final class ReleaseStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var fails = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseStub.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
@Suite("Component update check", .serialized)
struct ComponentUpdateCheckerTests {
    /// A defaults domain of its own, removed again after the test.
    static func withDefaults(_ body: (UserDefaults) async -> Void) async {
        let name = "jd-component-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    @Test("An offline check doesn't count as today's")
    func offlineCheckIsRetried() async {
        ReleaseStub.fails = true
        defer { ReleaseStub.fails = false }
        await Self.withDefaults { defaults in
            let checker = ComponentUpdateChecker(defaults: defaults, session: ReleaseStub.session())
            await checker.checkIfDue()
            #expect(defaults.object(forKey: ComponentUpdateChecker.lastCheckKey) == nil)
            #expect(checker.updatesAvailable.isEmpty)
        }
    }

    @Test("A successful check is remembered and finds newer versions")
    func successfulCheck() async {
        ReleaseStub.status = 200
        ReleaseStub.body = Data("{\"tag_name\": \"v99.0.0\", \"prerelease\": false}".utf8)
        await Self.withDefaults { defaults in
            let checker = ComponentUpdateChecker(defaults: defaults, session: ReleaseStub.session())
            await checker.checkIfDue()
            #expect(defaults.object(forKey: ComponentUpdateChecker.lastCheckKey) is Date)
            #expect(checker.updatesAvailable.count == checker.components.count)
        }
    }

    @Test("A prerelease is never offered")
    func prereleaseIsIgnored() async {
        ReleaseStub.status = 200
        ReleaseStub.body = Data("{\"tag_name\": \"v99.0.0-beta1\", \"prerelease\": true}".utf8)
        await Self.withDefaults { defaults in
            let checker = ComponentUpdateChecker(defaults: defaults, session: ReleaseStub.session())
            await checker.checkIfDue()
            #expect(checker.updatesAvailable.isEmpty)
        }
    }
}

@Suite("Documentation links")
struct DocsLinksTests {
    @Test("Every stage the app links to has its heading in the learning path")
    func stageAnchorsExist() throws {
        let text = try String(contentsOf: PinnedVersionTests.repoRoot.appending(path: "docs/graduating.md"), encoding: .utf8)
        let anchors = Set(text.split(separator: "\n").filter { $0.hasPrefix("## ") }.map { heading in
            String(heading.dropFirst(3)).lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
                .replacingOccurrences(of: " ", with: "-")
        })
        for stage in [1, 3] {
            let anchor = try #require(DocsLinks.stage(stage).fragment)
            #expect(anchors.contains(anchor), "stage \(stage)")
        }
    }
}

@Suite("State locks and test isolation")
struct LockAndIsolationTests {
    @Test("OpenTofu's lock error names who holds the lock and since when")
    func lockFromEngineOutput() throws {
        let lines = [
            "╷",
            "│ Error: Error acquiring the state lock",
            "│ ",
            "│ Error message: HTTP remote state already locked: ID=00000000-0000-4000-9000-0000000000dd",
            "│ Lock Info:",
            "│   ID:        00000000-0000-4000-9000-0000000000dd",
            "│   Operation: OperationTypeApply",
            "│   Who:       alex@example-mac",
            "│   Version:   1.13.2",
            "│   Created:   2026-10-30 14:02:11.123456 +0000 UTC",
            "│   Info:      ",
            "╵",
        ]
        let lock = try #require(StateBackendService.lock(fromEngineOutput: lines))
        #expect(lock.lockID == "00000000-0000-4000-9000-0000000000dd")
        #expect(lock.engineer == "alex" && lock.host == "example-mac")
        #expect(lock.activity == "deployed")
        let created = try #require(lock.created)
        #expect(abs(created.timeIntervalSince1970 - 1_793_368_931.123) < 0.01)
        #expect(StateBackendService.lock(fromEngineOutput: ["Error: something else"]) == nil)
    }

    @MainActor
    @Test("The unit tests' host never opens the real store")
    func unitTestHostUsesItsOwnStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "jd-isolation-\(UUID().uuidString)"))
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        #expect(AppWorlds.sandboxFolder(demo: demo, isUnitTestHost: true) == AppWorlds.unitTestHostFolder)
        #expect(AppWorlds.sandboxFolder(demo: demo, isUnitTestHost: false) == nil)
        #expect(AppWorlds.unitTestHostFolder.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
