import Foundation
import DeployerKit
import os

/// The store on disk is a Git repository — always, remote or not. Solo use
/// gets free local versioning of tenant records, history and catalog
/// sources; Team Mode is the same repository with a remote. Engine state is
/// never part of it: solo state stays in each workspace, team state goes
/// through the state backend (see `StateBackendService`), which also locks.
actor GitStoreService {
    nonisolated static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "Jamf Deployer/store")
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
        try Data("""
        # Regenerated on every run — never shared.
        tenants/*/generated/
        tenants/*/exports/
        # Engine state never goes into this repository: solo state stays on
        # this Mac, team state lives in the state backend.
        tenants/*/state/
        .DS_Store
        """.utf8).write(to: ignoreURL)

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
        // State files committed before the ignore rule leave the index.
        if !((try? run("ls-files", "--", "tenants/*/state/*")) ?? "").isEmpty {
            try run("rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", "tenants/*/state")
            _ = try? commitAll(message: "Keep engine state out of the store repository")
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

    /// Publishes local commits, rebasing onto what teammates pushed first.
    func pushRebasing() throws {
        do {
            try push()
        } catch GitError.pushRejected {
            try pull()
            try push()
        }
    }

    // MARK: State branch

    /// Creates the state branch on the remote when it does not exist yet:
    /// the state backend only writes to an existing branch.
    func ensureStateBranch() throws {
        let branch = StateBackendService.stateBranch
        let existing = try run("ls-remote", "--heads", "origin", branch)
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A one-file root commit, made with plumbing so the store's working
        // tree and main branch are untouched.
        let readme = "# Jamf Deployer state\n\nEngine state for this team space, written by the state backend. Do not edit by hand.\n"
        let blob = try runWithInput(readme, "hash-object", "-w", "--stdin").trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = try runWithInput("100644 blob \(blob)\tREADME.md\n", "mktree").trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try runWithInput("Create the state branch", "commit-tree", tree).trimmingCharacters(in: .whitespacesAndNewlines)
        try run("push", "origin", "\(commit):refs/heads/\(branch)")
    }

    /// The engine's current state locks, one per locked tenant.
    func stateLocks() -> [UUID: StateBackendService.StateLock] {
        guard let heads = try? run("ls-remote", "--heads", "origin", "locks/tenants/*") else { return [:] }
        var locks: [UUID: StateBackendService.StateLock] = [:]
        for line in heads.split(separator: "\n") {
            guard let ref = line.split(separator: "\t").last.map(String.init),
                  let match = ref.firstMatch(of: /locks\/tenants\/([0-9A-Fa-f-]{36})\//),
                  let tenantID = UUID(uuidString: String(match.1))
            else { continue }
            let localRef = "refs/jamf-deployer/locks/\(tenantID.uuidString)"
            let path = "tenants/\(tenantID.uuidString)/terraform.tfstate.lock"
            guard (try? run("fetch", "-q", "--depth", "1", "origin", "+\(ref):\(localRef)")) != nil,
                  let text = try? run("show", "\(localRef):\(path)"),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }
            locks[tenantID] = StateBackendService.StateLock(
                lockID: object["ID"] as? String ?? "",
                who: object["Who"] as? String ?? "another engineer",
                operation: object["Operation"] as? String ?? "",
                created: (object["Created"] as? String).flatMap(StateBackendService.parseLockDate))
        }
        return locks
    }

    // MARK: Plumbing

    @discardableResult
    private func run(_ arguments: String...) throws -> String {
        try execute(arguments, input: nil)
    }

    private func runWithInput(_ input: String, _ arguments: String...) throws -> String {
        try execute(arguments, input: input)
    }

    private func execute(_ arguments: [String], input: String?) throws -> String {
        guard Self.isGitAvailable else { throw GitError.gitUnavailable }
        let process = Process()
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
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
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
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
