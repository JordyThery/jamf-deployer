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

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                "The Team Mode state backend is missing from the app. Reinstall Jamf Deployer."
            case .didNotStart(let detail):
                "The Team Mode state backend did not start: \(detail)"
            case .missingGitCredentials(let host):
                "No Git credentials for \(host) were found. Sign in with git or gh (for example `gh auth login`), or use an SSH repository URL with your SSH agent."
            case .request(let detail):
                "The Team Mode state backend refused the request: \(detail)"
            }
        }
    }

    private var process: Process?
    private var port: Int = 0
    private var password = ""
    private var runningRemote: String?
    /// A start in progress, shared by callers that arrive meanwhile (a fleet
    /// check runs several tenants at once).
    private var starting: (remote: String, task: Task<Void, Error>)?
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "StateBackend")

    static var binaryURL: URL {
        EngineLocator.locateTool("Vendor/terraform-backend-git/terraform-backend-git")
    }

    /// The backend's own temporary folder: it keeps a PID file there and
    /// refuses to start while another copy runs, so it must not share the
    /// system one.
    nonisolated static var workFolderURL: URL {
        URL.applicationSupportDirectory.appending(path: "Jamf Deployer/engine/state-backend")
    }

    /// Stops a backend left running by an app that crashed or was force-quit,
    /// when the recorded process is the app's bundled copy.
    nonisolated static func stopLeftoverBackend() {
        let pidFile = workFolderURL.appending(path: ".terraform-backend-git.pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer).hasSuffix("/Vendor/terraform-backend-git/terraform-backend-git") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// The engine's HTTP backend settings for one tenant (TF_HTTP_*). Starts
    /// the backend for `remote` first when needed. Never written to disk.
    func environment(tenantID: UUID, remote: String) async throws -> [String: String] {
        try await ensureRunning(remote: remote)
        let address = stateAddress(tenantID: tenantID, remote: remote)
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
        } catch {
            try? await send("UNLOCK", address, body: unlock)
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
            try? await send("UNLOCK", address, body: unlock)
            throw error
        }
        try await send("UNLOCK", address, body: unlock)
    }

    func stop() {
        process?.terminate()
        process = nil
        runningRemote = nil
    }

    // MARK: Plumbing

    private func stateAddress(tenantID: UUID, remote: String) -> String {
        Self.address(port: port, remote: remote, ref: Self.stateBranch,
                     path: "tenants/\(tenantID.uuidString)/terraform.tfstate")
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
        if let starting, starting.remote == remote {
            try await starting.task.value
            return
        }
        if let process, process.isRunning, runningRemote == remote { return }
        let task = Task { try await self.start(remote: remote) }
        starting = (remote, task)
        defer { starting = nil }
        try await task.value
    }

    private func start(remote: String) async throws {
        stop()
        let binary = Self.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw BackendError.missingBinary }

        Self.stopLeftoverBackend()
        try FileManager.default.createDirectory(at: Self.workFolderURL, withIntermediateDirectories: true)
        // A credential helper can take a while (gh may refresh its token).
        var environment = try await Task.detached { try Self.gitCredentialEnvironment(remote: remote) }.value
        port = try Self.freePort()
        password = UUID().uuidString + UUID().uuidString
        environment["TF_BACKEND_GIT_HTTP_USERNAME"] = "jamf-deployer"
        environment["TF_BACKEND_GIT_HTTP_PASSWORD"] = password
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "/usr/bin:/bin"
        environment["TMPDIR"] = Self.workFolderURL.path

        let launched = Process()
        launched.executableURL = binary
        launched.arguments = ["--address=127.0.0.1:\(port)"]
        launched.environment = environment
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
                if launched.isRunning { return }
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        let errorHandle = errors.fileHandleForReading
        let output = await Task.detached { errorHandle.readDataToEndOfFile() }.value
        let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw BackendError.didNotStart(detail.isEmpty ? "it did not respond on its local port" : String(detail.prefix(200)))
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
            throw BackendError.request("\(method) answered HTTP \(status)")
        }
        return data
    }

    /// The engineer's Git credentials for the repository, as the backend's
    /// environment: HTTPS through the user's credential helper (git or gh),
    /// SSH through their agent and key. Nothing is stored.
    nonisolated static func gitCredentialEnvironment(remote: String) throws -> [String: String] {
        var environment: [String: String] = [:]
        if remote.hasPrefix("https://") || remote.hasPrefix("http://") {
            guard let url = URL(string: remote), let host = url.host() else {
                throw BackendError.missingGitCredentials(remote)
            }
            let filled = try credentialFill(protocol: url.scheme ?? "https", host: host)
            guard let password = filled["password"], !password.isEmpty else {
                throw BackendError.missingGitCredentials(host)
            }
            environment["GIT_USERNAME"] = filled["username"] ?? "x-access-token"
            environment["GIT_PASSWORD"] = password
        } else {
            if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                environment["SSH_AUTH_SOCK"] = agent
            }
            let ssh = URL.homeDirectory.appending(path: ".ssh")
            if let key = ["id_ed25519", "id_ecdsa", "id_rsa"].map({ ssh.appending(path: $0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                environment["SSH_PRIVATE_KEY"] = key.path
            }
        }
        return environment
    }

    /// `git credential fill`: the same lookup git itself does for a push.
    nonisolated static func credentialFill(protocol scheme: String, host: String) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["credential", "fill"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        try? input.fileHandleForWriting.write(contentsOf: Data("protocol=\(scheme)\nhost=\(host)\n\n".utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
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
