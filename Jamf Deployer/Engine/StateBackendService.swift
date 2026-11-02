import Foundation
import Darwin
import os

/// Team Mode keeps each tenant's engine state in the team repository
/// through the bundled terraform-backend-git: a state backend for the
/// engine's standard HTTP protocol, including its locking, that stores
/// state on its own branch of a Git repository. The app runs it on this Mac
/// only, on a random local port behind a one-time password, and hands it
/// the engineer's own Git credentials.
@Observable
final class StateBackendService {
    /// The branch that holds every tenant's state; tenant records stay on `main`.
    nonisolated static let stateBranch = "jamf-deployer-state"

    /// A lock the engine holds on a tenant's state, read from the backend.
    nonisolated struct StateLock: Sendable, Equatable {
        var lockID: String
        /// "<user>@<host>", as the engine records it.
        var who: String
        var operation: String
        var created: Date?

        var engineer: String { who.split(separator: "@").first.map(String.init) ?? who }
        var host: String { who.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }

        /// "deploy" or "check", for display.
        var activity: String {
            operation.contains("Apply") ? "deployed" : operation.contains("Plan") || operation.contains("Refresh") ? "checked" : "worked on"
        }
    }

    nonisolated enum BackendError: LocalizedError {
        case missingBinary
        case didNotStart(String)
        case missingGitCredentials(String)
        case request(String)
        case status(String, Int)
        case sshKeyNeedsAgent

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                "The Team Mode state backend is missing from the app. Reinstall Jamf Deployer."
            case .didNotStart(let detail):
                "The Team Mode state backend didn’t start: \(detail)"
            case .missingGitCredentials(let host):
                "No Git credentials for \(host) were found. Sign in with git or gh (for example `gh auth login`), or use an SSH repository URL with your SSH agent."
            case .request(let detail):
                "The Team Mode state backend refused the request: \(detail)"
            case .status(let method, let status):
                "The Team Mode state backend refused the request: \(method) answered HTTP \(status)"
            case .sshKeyNeedsAgent:
                "Your SSH key is protected by a passphrase, which the Team Mode state backend can’t ask for. Add the key to your SSH agent (in Terminal: ssh-add --apple-use-keychain followed by the key’s path), then try again."
            }
        }
    }

    private var process: Process?
    /// The doorway the backend and git are started through.
    let tools: ToolDoorway

    init(tools: ToolDoorway) {
        self.tools = tools
    }
    private var port: Int = 0
    private var password = ""
    private var runningRemote: String?
    /// A start in progress, shared by callers that arrive meanwhile (a fleet
    /// check runs several tenants at once).
    private var starting: (remote: String, token: UUID, task: Task<Void, Error>)?
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "StateBackend")

    static var binaryURL: URL {
        EngineLocator.locateTool("Vendor/terraform-backend-git/terraform-backend-git")
    }

    /// The backend's own temporary folder: it keeps a PID file there and
    /// refuses to start while another copy runs, so it must not share the
    /// system one.
    nonisolated static var workFolderURL: URL {
        AppFiles.url("engine/state-backend")
    }

    /// Stops a backend left running by an app that crashed or was force-quit:
    /// the recorded process is the app's bundled copy and the app that
    /// started it is gone (launchd adopted it). A backend another running
    /// copy of the app owns (the installed app while unit tests or a
    /// release-check build run) is left alone, and so is its PID file.
    nonisolated static func stopLeftoverBackend() {
        let pidFile = workFolderURL.appending(path: ".terraform-backend-git.pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        switch leftoverVerdict(path: processPath(pid), parent: parentProcess(of: pid), parentIsAlive: { kill($0, 0) == 0 }) {
        case .stop:
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(at: pidFile)
        case .gone:
            try? FileManager.default.removeItem(at: pidFile)
        case .ownedByARunningApp:
            break
        }
    }

    nonisolated enum LeftoverVerdict: Equatable {
        /// An orphaned copy of the bundled backend.
        case stop
        /// Not running any more (or another program reuses the number).
        case gone
        /// Its app still runs: never touched.
        case ownedByARunningApp
    }

    /// What to do with the process a PID file names.
    nonisolated static func leftoverVerdict(path: String?, parent: pid_t?,
                                            parentIsAlive: (pid_t) -> Bool) -> LeftoverVerdict {
        guard let path, path.hasSuffix("/Vendor/terraform-backend-git/terraform-backend-git") else { return .gone }
        guard let parent, parent > 1, parentIsAlive(parent) else { return .stop }
        return .ownedByARunningApp
    }

    private nonisolated static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private nonisolated static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Where the team passphrase check lives on the state branch: a tiny
    /// state with nothing in it, encrypted by OpenTofu with the team
    /// passphrase. Outside `tenants/`, so it's never taken for a tenant.
    nonisolated static let passphraseCheckPath = "_passphrase-check/terraform.tfstate"

    /// The engine's HTTP backend settings for one tenant (TF_HTTP_*). Starts
    /// the backend for `remote` first when needed. Never written to disk.
    func environment(tenantID: UUID, remote: String) async throws -> [String: String] {
        try await environment(statePath: Self.statePath(tenantID: tenantID), remote: remote)
    }

    nonisolated static func statePath(tenantID: UUID) -> String {
        "tenants/\(tenantID.uuidString)/terraform.tfstate"
    }

    /// The same for any state on the state branch (the passphrase check).
    func environment(statePath: String, remote: String) async throws -> [String: String] {
        try await ensureRunning(remote: remote)
        let address = Self.address(port: port, remote: remote, ref: Self.stateBranch, path: statePath)
        return [
            "TF_HTTP_ADDRESS": address,
            "TF_HTTP_LOCK_ADDRESS": address,
            "TF_HTTP_UNLOCK_ADDRESS": address,
            "TF_HTTP_USERNAME": "jamf-deployer",
            "TF_HTTP_PASSWORD": password,
            // A lock held by a teammate is refused like a server error, and
            // the engine retries those; keep that wait short.
            "TF_HTTP_RETRY_WAIT_MAX": "5",
        ]
    }

    /// Removes a tenant's state from the team repository (Remove Tenant):
    /// the backend only writes under a lock, so lock, delete, unlock.
    func deleteState(tenantID: UUID, remote: String) async throws {
        try await ensureRunning(remote: remote)
        let address = stateAddress(tenantID: tenantID, remote: remote)
        let lockID = UUID().uuidString.lowercased()
        let info: [String: String] = [
            "ID": lockID, "Operation": "OperationTypeDelete",
            "Who": "\(NSUserName())@\(ProcessInfo.processInfo.hostName)",
            "Version": "", "Created": Date.now.formatted(.iso8601), "Path": "", "Info": "Remove tenant",
        ]
        let body = try JSONSerialization.data(withJSONObject: info)
        let unlock = try JSONSerialization.data(withJSONObject: ["ID": lockID])
        try await send("LOCK", address, body: body)
        do {
            try await send("DELETE", address + "&ID=\(lockID)", body: nil)
        } catch BackendError.status(_, 404) {
            // Nothing to delete: the tenant never had state in the team space.
        } catch {
            _ = try? await send("UNLOCK", address, body: unlock)
            throw error
        }
        try await send("UNLOCK", address, body: unlock)
    }

    /// Writes `state` to `path` on branch `ref` of `remote` (Export as
    /// Terraform): lock, write, unlock, like the engine does.
    func pushState(_ state: Data, remote: String, ref: String, path: String) async throws {
        try await ensureRunning(remote: remote)
        let address = Self.address(port: port, remote: remote, ref: ref, path: path)
        let lockID = UUID().uuidString.lowercased()
        let info: [String: String] = [
            "ID": lockID, "Operation": "OperationTypeApply",
            "Who": "\(NSUserName())@\(ProcessInfo.processInfo.hostName)",
            "Version": "", "Created": Date.now.formatted(.iso8601), "Path": "", "Info": "Export from Jamf Deployer",
        ]
        let unlock = try JSONSerialization.data(withJSONObject: ["ID": lockID])
        try await send("LOCK", address, body: try JSONSerialization.data(withJSONObject: info))
        do {
            try await send("POST", address + "&ID=\(lockID)", body: state)
        } catch {
            _ = try? await send("UNLOCK", address, body: unlock)
            throw error
        }
        try await send("UNLOCK", address, body: unlock)
    }

    /// Whether this app's backend runs now.
    var isRunning: Bool { process?.isRunning == true }

    func stop() {
        process?.terminate()
        process = nil
        runningRemote = nil
    }

    /// Stops the backend and empties its working folder, so the next run
    /// starts from a fresh clone. After a lock branch is deleted behind its
    /// back, a running backend's clone still holds the old lock ref and every
    /// read of that state fails ("non-fast-forward update"); a fresh one reads
    /// it normally.
    func restartFresh() async {
        if let running = process {
            running.terminate()
            await Task.detached { running.waitUntilExit() }.value
        }
        process = nil
        runningRemote = nil
        try? FileManager.default.removeItem(at: Self.workFolderURL)
    }

    // MARK: Plumbing

    private func stateAddress(tenantID: UUID, remote: String) -> String {
        Self.address(port: port, remote: remote, ref: Self.stateBranch, path: Self.statePath(tenantID: tenantID))
    }

    private static func address(port: Int, remote: String, ref: String, path: String) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "type", value: "git"),
            URLQueryItem(name: "repository", value: remote),
            URLQueryItem(name: "ref", value: ref),
            URLQueryItem(name: "state", value: path),
        ]
        return components.url?.absoluteString ?? ""
    }

    private func ensureRunning(remote: String) async throws {
        if let starting {
            if starting.remote == remote {
                try await starting.task.value
                return
            }
            // Let an in-flight start for another remote settle before
            // replacing its backend; start() begins by stopping it.
            try? await starting.task.value
        }
        if let process, process.isRunning, runningRemote == remote { return }
        let token = UUID()
        let task = Task { try await self.start(remote: remote) }
        starting = (remote, token, task)
        defer { if starting?.token == token { starting = nil } }
        try await task.value
    }

    private func start(remote: String) async throws {
        stop()
        let binary = Self.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw BackendError.missingBinary }

        Self.stopLeftoverBackend()
        try FileManager.default.createDirectory(at: Self.workFolderURL, withIntermediateDirectories: true)
        // A credential helper can take a while (gh may refresh its token).
        let tools = tools
        var environment = try await Task.detached { try Self.gitCredentialEnvironment(remote: remote, tools: tools) }.value
        port = try Self.freePort()
        password = UUID().uuidString + UUID().uuidString
        environment["TF_BACKEND_GIT_HTTP_USERNAME"] = "jamf-deployer"
        environment["TF_BACKEND_GIT_HTTP_PASSWORD"] = password
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "/usr/bin:/bin"
        environment["TMPDIR"] = Self.workFolderURL.path

        let launched = try tools.process(.stateBackend, executable: binary, arguments: ["--address=127.0.0.1:\(port)"],
                                         environment: environment)
        launched.standardInput = FileHandle.nullDevice
        launched.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        launched.standardError = errors
        try launched.run()
        process = launched
        runningRemote = remote

        // Ready once the port accepts connections while the backend still
        // runs: if it exited (for example because another process took the
        // port), whatever listens there is not ours.
        for _ in 0..<50 {
            guard launched.isRunning else { break }
            if Self.isListening(port: port) {
                try await Task.sleep(for: .milliseconds(200))
                if launched.isRunning {
                    // The backend logs every request to stderr; drain it for
                    // its lifetime or the pipe fills and the backend blocks.
                    errors.fileHandleForReading.readabilityHandler = { handle in
                        if handle.availableData.isEmpty { handle.readabilityHandler = nil }
                    }
                    return
                }
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        let errorHandle = errors.fileHandleForReading
        let output = await Task.detached { errorHandle.readDataToEndOfFile() }.value
        let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw BackendError.didNotStart(detail.isEmpty ? "it didn’t respond on its local port" : String(detail.prefix(200)))
    }

    @discardableResult
    private func send(_ method: String, _ address: String, body: Data?) async throws -> Data {
        guard let url = URL(string: address) else { throw BackendError.request("invalid address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let credentials = Data("jamf-deployer:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BackendError.status(method, status)
        }
        return data
    }

    /// The engineer's Git credentials for the repository, as the backend's
    /// environment: HTTPS through the user's credential helper (git or gh),
    /// SSH through their agent and key. Nothing is stored.
    nonisolated static func gitCredentialEnvironment(remote: String, tools: ToolDoorway) throws -> [String: String] {
        var environment: [String: String] = [:]
        if remote.hasPrefix("https://") || remote.hasPrefix("http://") {
            guard let url = URL(string: remote), let host = url.host() else {
                throw BackendError.missingGitCredentials(remote)
            }
            let filled = try credentialFill(protocol: url.scheme ?? "https", host: host, tools: tools)
            guard let password = filled["password"], !password.isEmpty else {
                throw BackendError.missingGitCredentials(host)
            }
            environment["GIT_USERNAME"] = filled["username"] ?? "x-access-token"
            environment["GIT_PASSWORD"] = password
        } else {
            let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            let ssh = URL.homeDirectory.appending(path: ".ssh")
            let keys = ["id_ed25519", "id_ecdsa", "id_rsa"].map { ssh.appending(path: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { (path: $0.path, text: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
            environment = try sshEnvironment(
                agentSocket: agent, agentHasKeys: agent != nil && !tools.refusesEverything && agentHasKeys(),
                keys: keys)
        }
        return environment
    }

    /// SSH sign-in for the backend: the engineer's agent, and alongside it
    /// the first default key file without a passphrase (which the backend
    /// can't ask for), so a key in the agent that this remote doesn't take
    /// (a work key, say) doesn't hide the one it does. Only locked key files
    /// and an empty agent: the engineer is asked to add a key to the agent.
    nonisolated static func sshEnvironment(
        agentSocket: String?, agentHasKeys: Bool, keys: [(path: String, text: String)]
    ) throws -> [String: String] {
        var environment: [String: String] = [:]
        if let agentSocket { environment["SSH_AUTH_SOCK"] = agentSocket }
        if let key = keys.first(where: { !isPassphraseProtected(keyText: $0.text) }) {
            environment["SSH_PRIVATE_KEY"] = key.path
        } else if !keys.isEmpty && !(agentSocket != nil && agentHasKeys) {
            throw BackendError.sshKeyNeedsAgent
        }
        return environment
    }

    /// Whether a private key file is encrypted: a PEM key says so in its
    /// header, an OpenSSH key names a cipher other than "none".
    nonisolated static func isPassphraseProtected(keyText: String) -> Bool {
        if keyText.contains("ENCRYPTED") { return true }
        guard keyText.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let body = keyText.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return true }
        // "openssh-key-v1\0", then the cipher name as a length-prefixed string.
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic), data.count >= magic.count + 4 else { return true }
        let lengthBytes = data[data.startIndex + magic.count ..< data.startIndex + magic.count + 4]
        let length = lengthBytes.reduce(0) { $0 << 8 | Int($1) }
        let start = data.startIndex + magic.count + 4
        guard length > 0, data.count >= magic.count + 4 + length else { return true }
        return String(decoding: data[start ..< start + length], as: UTF8.self) != "none"
    }

    /// Whether the SSH agent holds at least one key (`ssh-add -l` exits 0).
    private nonisolated static func agentHasKeys() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh-add")
        process.arguments = ["-l"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `git credential fill`: the same lookup git itself does for a push.
    nonisolated static func credentialFill(protocol scheme: String, host: String,
                                           tools: ToolDoorway) throws -> [String: String] {
        let output = try GitCommand.run(["credential", "fill"], in: nil,
                                        input: Data("protocol=\(scheme)\nhost=\(host)\n\n".utf8),
                                        discardsErrors: true, tools: tools)
        guard output.status == 0 else { return [:] }
        var values: [String: String] = [:]
        for line in output.text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    /// A free local port, found by binding to port 0.
    nonisolated static func freePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw BackendError.didNotStart("no local socket") }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard bound == 0 else { throw BackendError.didNotStart("no free local port") }
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    nonisolated static func isListening(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Parses the engine's "state already locked" output into the lock.
    nonisolated static func lock(fromEngineOutput lines: [String]) -> StateLock? {
        let text = lines.joined(separator: "\n")
        guard text.contains("already locked") || text.contains("Error acquiring the state lock") else { return nil }
        func field(_ name: String) -> String? {
            guard let match = text.firstMatch(of: try! Regex("\(name):\\s+([^\\n\\\\]*)")) else { return nil }
            let value = String(match.output[1].substring ?? "").trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        guard let id = field("ID") else { return nil }
        return StateLock(
            lockID: id,
            who: field("Who") ?? "another engineer",
            operation: field("Operation") ?? "",
            created: field("Created").flatMap(Self.parseLockDate))
    }

    nonisolated static func parseLockDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS Z 'UTC'", "yyyy-MM-dd HH:mm:ss Z 'UTC'"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
