import Foundation
import DeployerKit
import os

/// The store on disk is a Git repository — always, remote or not. Solo use
/// gets free local versioning; team mode is the same repo with a GitHub
/// remote. Locking rides on Git's atomic push: a push only lands if the
/// remote hasn't moved, which makes committing a lock file a compare-and-swap.
actor GitStoreService {
    nonisolated static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "Jamf Deployer/store")
    }

    nonisolated struct LockInfo: Codable, Sendable {
        var tenantID: UUID
        var engineer: String
        var host: String
        var operation: String
        var acquiredAt: Date
    }

    enum LockResult: Sendable {
        case acquired
        case heldByOther(LockInfo)
    }

    enum GitError: LocalizedError {
        case gitUnavailable
        case commandFailed(String, output: String)
        case pushRejected

        var errorDescription: String? {
            switch self {
            case .gitUnavailable:
                "Git is not available on this Mac. Install the Xcode Command Line Tools to use versioning and team features."
            case .commandFailed(let command, let output):
                "Git \(command) failed: \(output.prefix(300))"
            case .pushRejected:
                "The team space moved while this Mac was working. Sync and try again."
            }
        }
    }

    private let storeURL: URL
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "GitStore")

    init(storeURL: URL = GitStoreService.storeURL) {
        self.storeURL = storeURL
    }

    nonisolated static var isGitAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    // MARK: Repo lifecycle

    /// Initializes the repo on first use (idempotent) with the ignore rules
    /// and manifest.
    func ensureRepo() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)

        let ignoreURL = storeURL.appending(path: ".gitignore")
        if !fileManager.fileExists(atPath: ignoreURL.path) {
            try Data("""
            # Regenerated on every run — never shared.
            tenants/*/generated/
            tenants/*/exports/
            .DS_Store
            """.utf8).write(to: ignoreURL)
        }

        let manifestURL = storeURL.appending(path: "store.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            let manifest: [String: Any] = [
                "schemaVersion": 1,
                "createdAt": Date.now.formatted(.iso8601),
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: manifestURL)
        }

        if !fileManager.fileExists(atPath: storeURL.appending(path: ".git").path) {
            try run("init", "--initial-branch", "main")
            try run("config", "user.name", "Jamf Deployer")
            try run("config", "user.email", "jamf-deployer@localhost")
            _ = try? commitAll(message: "Initialize Jamf Deployer store")
        }
    }

    /// Stages everything and commits when there are changes.
    @discardableResult
    func commitAll(message: String) throws -> Bool {
        try run("add", "-A")
        let status = try run("status", "--porcelain")
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try run("commit", "-m", message)
        return true
    }

    // MARK: Remote / team space

    var remoteURL: String? {
        get throws {
            let output = (try? run("remote", "get-url", "origin")) ?? ""
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func isTeamMode() -> Bool {
        ((try? remoteURL) ?? nil) != nil
    }

    func attachRemote(_ url: String) throws {
        if ((try? remoteURL) ?? nil) != nil {
            try run("remote", "set-url", "origin", url)
        } else {
            try run("remote", "add", "origin", url)
        }
        try run("push", "-u", "origin", "main")
    }

    func detachRemote() throws {
        try run("remote", "remove", "origin")
    }

    func pull() throws {
        guard ((try? remoteURL) ?? nil) != nil else { return }
        try run("pull", "--rebase", "--autostash", "origin", "main")
    }

    func push() throws {
        guard ((try? remoteURL) ?? nil) != nil else { return }
        do {
            try run("push", "origin", "main")
        } catch let error as GitError {
            if case .commandFailed(_, let output) = error,
               output.contains("rejected") || output.contains("fetch first") || output.contains("non-fast-forward") {
                throw GitError.pushRejected
            }
            throw error
        }
    }

    // MARK: Locks (compare-and-swap via push)

    private func lockURL(_ tenantID: UUID) -> URL {
        storeURL.appending(path: "locks/\(tenantID.uuidString).json")
    }

    func currentLock(for tenantID: UUID) -> LockInfo? {
        try? JSONFile.load(LockInfo.self, from: lockURL(tenantID))
    }

    func allLocks() -> [LockInfo] {
        let locksURL = storeURL.appending(path: "locks")
        let files = (try? FileManager.default.contentsOfDirectory(at: locksURL, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONFile.load(LockInfo.self, from: $0) }
    }

    /// This Mac's name as recorded in lock files.
    private var hostName: String { Host.current().localizedName ?? "this Mac" }

    /// Acquire = commit the lock file and win the push race. Only the lock
    /// file is committed, so a lost race never touches other work.
    func acquireLock(tenantID: UUID, engineer: String, operation: String, attempt: Int = 0) throws -> LockResult {
        guard isTeamMode() else { return .acquired }
        try pull()
        if let existing = currentLock(for: tenantID), existing.host != hostName || existing.engineer != engineer {
            return .heldByOther(existing)
        }
        let info = LockInfo(
            tenantID: tenantID,
            engineer: engineer,
            host: hostName,
            operation: operation,
            acquiredAt: .now
        )
        try JSONFile.save(info, to: lockURL(tenantID))
        let lockPath = "locks/\(tenantID.uuidString).json"
        try run("add", "--", lockPath)
        try run("commit", "-m", "Lock \(tenantID.uuidString.prefix(8)) — \(engineer) (\(operation))", "--", lockPath)
        do {
            try push()
            return .acquired
        } catch GitError.pushRejected {
            // Lost the race: undo only the lock commit, then take theirs.
            try run("reset", "--soft", "HEAD~1")
            try run("reset", "-q", "--", lockPath)
            try? FileManager.default.removeItem(at: lockURL(tenantID))
            try pull()
            if let holder = currentLock(for: tenantID) {
                return .heldByOther(holder)
            }
            // The race was about something else: retry a couple of times.
            guard attempt < 2 else { throw GitError.pushRejected }
            return try acquireLock(tenantID: tenantID, engineer: engineer, operation: operation, attempt: attempt + 1)
        }
    }

    /// Release = commit the workspace outcome plus the lock removal, push.
    /// A lock held by someone else is left in place.
    func releaseLock(tenantID: UUID, engineer: String, message: String) throws {
        guard isTeamMode() else { return }
        if let existing = currentLock(for: tenantID), existing.engineer == engineer, existing.host == hostName {
            try? FileManager.default.removeItem(at: lockURL(tenantID))
        }
        try commitAll(message: message)
        do {
            try push()
        } catch GitError.pushRejected {
            // Under the lock nothing conflicting can land for this tenant;
            // rebase whatever else arrived and push again.
            try pull()
            try push()
        }
    }

    /// Force-remove a stale lock (crash recovery) — recorded in history.
    func breakLock(tenantID: UUID, by engineer: String) throws {
        try pull()
        try? FileManager.default.removeItem(at: lockURL(tenantID))
        try commitAll(message: "Break stale lock \(tenantID.uuidString.prefix(8)) — \(engineer)")
        try push()
    }

    // MARK: Plumbing

    @discardableResult
    private func run(_ arguments: String...) throws -> String {
        guard Self.isGitAvailable else { throw GitError.gitUnavailable }
        let process = Process()
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = Array(arguments)
        process.currentDirectoryURL = storeURL
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0" // never hang on auth prompts
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            // Only the subcommand: arguments can hold a remote URL with credentials.
            logger.error("git \(arguments.first ?? "", privacy: .public) failed: \(text.prefix(200), privacy: .private)")
            throw GitError.commandFailed(arguments.first ?? "", output: text)
        }
        return text
    }
}
