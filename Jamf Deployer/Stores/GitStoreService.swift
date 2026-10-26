import Foundation
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
        case remoteHasCredentials

        var errorDescription: String? {
            switch self {
            case .gitUnavailable:
                "Git is not available on this Mac. Install the Xcode Command Line Tools to use versioning and team features."
            case .commandFailed(let command, let output):
                "Git \(command) failed: \(output.prefix(300))"
            case .pushRejected:
                "The team space moved while this Mac was working. Sync and try again."
            case .remoteHasCredentials:
                "Remove the credentials from the repository URL. Git uses your own sign-in (SSH key or gh auth login)."
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
    func ensureRepo() async throws {
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

        let isNew = !fileManager.fileExists(atPath: storeURL.appending(path: ".git").path)
        if isNew {
            try await run("init", "--initial-branch", "main")
        }
        // Commits need an identity; a Mac without a Git setup (or a store
        // just cloned from a team space) gets the app's own.
        if ((try? await run("config", "user.email")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await run("config", "user.name", "Jamf Deployer")
            try await run("config", "user.email", "jamf-deployer@localhost")
        }
        if isNew {
            _ = try? await commitAll(message: "Initialize Jamf Deployer store")
        }
    }

    /// Stages everything and commits when there are changes.
    @discardableResult
    func commitAll(message: String) async throws -> Bool {
        try await run("add", "-A")
        let status = try await run("status", "--porcelain")
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try await run("commit", "-m", message)
        return true
    }

    // MARK: Remote / team space

    var remoteURL: String? {
        get async throws {
            let output = (try? await run("remote", "get-url", "origin")) ?? ""
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func isTeamMode() async -> Bool {
        ((try? await remoteURL) ?? nil) != nil
    }

    func attachRemote(_ url: String) async throws {
        // A token in the URL would land on git's arguments and in
        // .git/config on disk; Git must use the user's own sign-in.
        guard !RepositoryPublisher.hasCredentials(url) else { throw GitError.remoteHasCredentials }
        if ((try? await remoteURL) ?? nil) != nil {
            try await run("remote", "set-url", "origin", url)
        } else {
            try await run("remote", "add", "origin", url)
        }
        try await run("push", "-u", "origin", "main")
    }

    func detachRemote() async throws {
        try await run("remote", "remove", "origin")
    }

    func pull() async throws {
        guard ((try? await remoteURL) ?? nil) != nil else { return }
        try await run("pull", "--rebase", "--autostash", "origin", "main")
    }

    func push() async throws {
        guard ((try? await remoteURL) ?? nil) != nil else { return }
        do {
            try await run("push", "origin", "main")
        } catch let error as GitError {
            if case .commandFailed(_, let output) = error,
               output.contains("rejected") || output.contains("fetch first") || output.contains("non-fast-forward") {
                throw GitError.pushRejected
            }
            throw error
        }
    }

    /// Publishes local commits, rebasing onto what teammates pushed first.
    func pushRebasing() async throws {
        do {
            try await push()
        } catch GitError.pushRejected {
            try await pull()
            try await push()
        }
    }

    // MARK: State branch

    /// Creates the state branch on the remote when it does not exist yet:
    /// the state backend only writes to an existing branch.
    func ensureStateBranch() async throws {
        let branch = StateBackendService.stateBranch
        let existing = try await run("ls-remote", "--heads", "origin", branch)
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A one-file root commit, made with plumbing so the store's working
        // tree and main branch are untouched.
        let readme = "# Jamf Deployer state\n\nEngine state for this team space, written by the state backend. Do not edit by hand.\n"
        let blob = try await runWithInput(readme, "hash-object", "-w", "--stdin").trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = try await runWithInput("100644 blob \(blob)\tREADME.md\n", "mktree").trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await runWithInput("Create the state branch", "commit-tree", tree).trimmingCharacters(in: .whitespacesAndNewlines)
        try await run("push", "origin", "\(commit):refs/heads/\(branch)")
    }

    /// The engine's current state locks, one per locked tenant.
    func stateLocks() async -> [UUID: StateBackendService.StateLock] {
        guard let heads = try? await run("ls-remote", "--heads", "origin", "locks/tenants/*") else { return [:] }
        var locks: [UUID: StateBackendService.StateLock] = [:]
        for line in heads.split(separator: "\n") {
            guard let ref = line.split(separator: "\t").last.map(String.init),
                  let match = ref.firstMatch(of: /locks\/tenants\/([0-9A-Fa-f-]{36})\//),
                  let tenantID = UUID(uuidString: String(match.1))
            else { continue }
            let localRef = "refs/jamf-deployer/locks/\(tenantID.uuidString)"
            let path = "tenants/\(tenantID.uuidString)/terraform.tfstate.lock"
            guard (try? await run("fetch", "-q", "--depth", "1", "origin", "+\(ref):\(localRef)")) != nil,
                  let text = try? await run("show", "\(localRef):\(path)"),
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

    /// Releases a tenant's state lock by deleting its lock branch, when it
    /// still holds `lockID`. terraform-backend-git keeps each lock on a
    /// `locks/<state path>` branch; while one is left behind, a backend
    /// started fresh cannot even read the state, so the engine's own
    /// force-unlock (which needs init first) cannot release it.
    func deleteStateLock(tenantID: UUID, lockID: String) async throws {
        guard await stateLocks()[tenantID]?.lockID == lockID else { return }
        try await run("push", "-q", "origin", "--delete", "locks/tenants/\(tenantID.uuidString)/terraform.tfstate")
    }

    // MARK: Plumbing

    @discardableResult
    private func run(_ arguments: String...) async throws -> String {
        try await execute(arguments, input: nil)
    }

    private func runWithInput(_ input: String, _ arguments: String...) async throws -> String {
        try await execute(arguments, input: input)
    }

    /// Runs git off the actor: network operations (pull, push, ls-remote)
    /// can stall for minutes and must not park an executor thread.
    private func execute(_ arguments: [String], input: String?) async throws -> String {
        let storeURL = storeURL
        let logger = logger
        return try await Task.detached {
            try Self.executeSync(arguments, input: input, storeURL: storeURL, logger: logger)
        }.value
    }

    private nonisolated static func executeSync(
        _ arguments: [String], input: String?, storeURL: URL, logger: Logger
    ) throws -> String {
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
