import Foundation
import JamfDeployerCore
import os

/// The store on disk is a Git repository — always, remote or not. Solo use
/// gets free local versioning of tenant records, history and catalog
/// sources; Team Mode is the same repository with a remote. Engine state is
/// never part of it: solo state stays in each workspace, team state goes
/// through the state backend (see `StateBackendService`), which also locks.
///
/// Git commands run strictly one at a time, and a whole sequence (commit,
/// pull, push) runs as one unit: the actor alone would let callers interleave
/// at every `await`.
actor GitStoreService {
    nonisolated static var storeURL: URL {
        AppFiles.url("store")
    }

    enum GitError: LocalizedError {
        case gitUnavailable
        case commandFailed(String, output: String)
        case pushRejected
        case remoteHasCredentials
        /// The store holds possible secrets nobody marked "not a secret":
        /// nothing was committed.
        case possibleSecrets([SecretFinding])
        /// A pull ran into a conflict; it was undone, and this Mac's own
        /// commits are kept as they were.
        case syncConflict(files: [String])
        /// The repository has a merge nobody finished (files with conflict
        /// markers): nothing is committed or synced until it's resolved.
        case unfinishedMerge(files: [String])

        var errorDescription: String? {
            switch self {
            case .gitUnavailable:
                "Versioning and team spaces need Git. Install the Xcode Command Line Tools (xcode-select --install)."
            case .commandFailed(let command, let output):
                "Git \(command) failed: \(output.prefix(300))"
            case .pushRejected:
                "The team space moved while this Mac was working. Sync and try again."
            case .remoteHasCredentials:
                "Remove the credentials from the repository URL. Git uses your own sign-in (SSH key or gh auth login)."
            case .possibleSecrets(let findings):
                "Nothing was saved to the store: \(findings.count == 1 ? "one place looks" : "\(findings.count) places look") like a secret (\(findings.prefix(3).map { "\($0.path), line \($0.line)" }.joined(separator: "; "))\(findings.count > 3 ? "; …" : "")). Review \(findings.count == 1 ? "it" : "them") in the main window."
            case .syncConflict(let files):
                "This Mac and the team space both changed \(Self.list(files)), so nothing was synced. This Mac’s changes are kept, and previews, checks and deploys wait until the store syncs. Ask the teammate who changed it, then sync again; if it keeps happening, merge the store with Git in Terminal (git pull --rebase in the store folder)."
            case .unfinishedMerge(let files):
                "The store has an unfinished Git merge in \(Self.list(files)), so nothing was saved or synced, and previews, checks and deploys wait. Resolve it with Git in Terminal (git status in the store folder), then sync again."
            }
        }

        private static func list(_ files: [String]) -> String {
            guard !files.isEmpty else { return "the same records" }
            return files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
        }
    }

    private let storeURL: URL
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "GitStore")

    /// The doorway git is started through; demo mode's never starts it.
    private let tools: ToolDoorway

    init(storeURL: URL = GitStoreService.storeURL, tools: ToolDoorway) {
        self.storeURL = storeURL
        self.tools = tools
    }

    nonisolated static var isGitAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    // MARK: One sequence at a time

    private var isRunningSequence = false
    private var waitingSequences: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` once every earlier sequence has finished; later callers
    /// wait for it in turn. Public methods take this once and call the
    /// unlocked helpers below, never each other.
    private func exclusively<T>(_ body: () async throws -> T) async throws -> T {
        if isRunningSequence {
            await withCheckedContinuation { waitingSequences.append($0) }
        } else {
            isRunningSequence = true
        }
        defer {
            if waitingSequences.isEmpty {
                isRunningSequence = false
            } else {
                waitingSequences.removeFirst().resume()
            }
        }
        return try await body()
    }

    // MARK: Repo lifecycle

    static let ignoreRules = """
    # Regenerated on every run — never shared.
    tenants/*/generated/
    tenants/*/exports/
    # Engine state never goes into this repository: solo state stays on
    # this Mac, team state lives in the state backend.
    tenants/*/state/
    .DS_Store
    """

    /// Initializes the repo on first use (idempotent) with the ignore rules
    /// and manifest.
    func ensureRepo() async throws {
        try await exclusively {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)

            // Written only when it differs: an unchanged file stays untouched.
            let ignoreURL = storeURL.appending(path: ".gitignore")
            let rules = Data(Self.ignoreRules.utf8)
            if (try? Data(contentsOf: ignoreURL)) != rules {
                try rules.write(to: ignoreURL)
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
                _ = try? await commitUnlocked(message: "Initialize Jamf Deployer store")
            }
        }
    }

    /// Stages everything and commits when there are changes. First the
    /// whole store is checked for possible secrets; any not marked "not a
    /// secret" stop the commit, except those in a tenant's deploy history
    /// (`blocksCommit`). A store with an unfinished merge is never staged:
    /// that would commit the conflict markers.
    @discardableResult
    func commitAll(message: String) async throws -> Bool {
        try await exclusively { try await commitUnlocked(message: message) }
    }

    private func commitUnlocked(message: String) async throws -> Bool {
        try await requireNoUnfinishedMerge()
        let findings = try await unacknowledgedFindingsUnlocked().filter(Self.blocksCommit)
        guard findings.isEmpty else { throw GitError.possibleSecrets(findings) }
        try await run("add", "-A")
        let status = try await run("status", "--porcelain")
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try await run("commit", "-m", message)
        return true
    }

    /// Throws when the store can't take part in a sync or commit: a merge
    /// left unfinished (conflict markers in files). A rebase or merge left
    /// in progress without conflicts (an interrupted sync of an earlier
    /// version) is undone first, which puts back the commit it started from.
    func checkHealthy() async throws {
        try await exclusively { try await requireNoUnfinishedMerge() }
    }

    private func requireNoUnfinishedMerge() async throws {
        let git = storeURL.appending(path: ".git")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: git.path) else { return }
        if fileManager.fileExists(atPath: git.appending(path: "rebase-merge").path)
            || fileManager.fileExists(atPath: git.appending(path: "rebase-apply").path) {
            _ = try? await run("rebase", "--abort")
        }
        if fileManager.fileExists(atPath: git.appending(path: "MERGE_HEAD").path) {
            _ = try? await run("merge", "--abort")
        }
        let unmerged = try await unmergedFiles()
        let stillInProgress = fileManager.fileExists(atPath: git.appending(path: "rebase-merge").path)
            || fileManager.fileExists(atPath: git.appending(path: "rebase-apply").path)
            || fileManager.fileExists(atPath: git.appending(path: "MERGE_HEAD").path)
        if !unmerged.isEmpty || stillInProgress { throw GitError.unfinishedMerge(files: unmerged) }
    }

    private func unmergedFiles() async throws -> [String] {
        try await run("diff", "--name-only", "--diff-filter=U").split(separator: "\n").map(String.init)
    }

    // MARK: Secret check

    /// "Not a secret" acknowledgements: location and rule only, never the
    /// value. Committed, so the whole team shares them. A finding whose line
    /// moves is asked about again.
    nonisolated static let acknowledgementsFile = "secret-scan-acknowledgements.json"

    struct Acknowledgements: Codable {
        var notSecrets: [SecretFinding] = []
    }

    /// One possible secret in the store.
    struct StoreFinding: Sendable, Hashable, Identifiable {
        var finding: SecretFinding
        /// Only in an earlier version: removed or changed since. Git keeps it.
        var inEarlierVersion: Bool
        var id: SecretFinding { finding }
    }

    /// Possible secrets in what the next commit would hold (every file Git
    /// tracks or would add), without the acknowledged ones.
    func unacknowledgedFindings() async throws -> [SecretFinding] {
        try await exclusively { try await unacknowledgedFindingsUnlocked() }
    }

    private func unacknowledgedFindingsUnlocked() async throws -> [SecretFinding] {
        let acknowledged = Set(acknowledgements().notSecrets)
        return try await currentFindingsUnlocked().filter { !acknowledged.contains($0) }
    }

    /// Possible secrets in the files the next commit would hold.
    func currentFindings() async throws -> [SecretFinding] {
        try await exclusively { try await currentFindingsUnlocked() }
    }

    private func currentFindingsUnlocked() async throws -> [SecretFinding] {
        let listing = try await run("ls-files", "-z", "--cached", "--others", "--exclude-standard")
        let paths = Set(listing.split(separator: "\0").map(String.init))
            .filter { $0 != Self.acknowledgementsFile }
            .sorted()
        let storeURL = storeURL
        return await Task.detached {
            var findings: [SecretFinding] = []
            for path in paths {
                guard let data = try? Data(contentsOf: storeURL.appending(path: path)),
                      let text = SecretScan.scannableText(data) else { continue }
                findings += SecretScan.scan(text: text, path: path)
            }
            return findings
        }.value
    }

    /// Whether a finding stops a commit. A tenant's deploy history
    /// (`tenants/<id>/history/…`) is the app's own record of what was
    /// deployed, already redacted, and can't be fixed afterwards: a finding
    /// there is shown in the one-time review but never stops a commit, so
    /// it never stops a preview, check or deploy either.
    nonisolated static func blocksCommit(_ finding: SecretFinding) -> Bool {
        !isDeployHistory(finding.path)
    }

    nonisolated static func isDeployHistory(_ path: String) -> Bool {
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        return parts.count >= 4 && parts[0] == "tenants" && UUID(uuidString: String(parts[1])) != nil
            && parts[2] == "history"
    }

    /// Marks a finding as not a secret; the next commit records it.
    func acknowledge(_ finding: SecretFinding) throws {
        try acknowledge([finding])
    }

    /// Marks several findings as not a secret at once (the review's "Mark
    /// All as Not a Secret"); the next commit records them.
    func acknowledge(_ findings: [SecretFinding]) throws {
        var current = acknowledgements()
        let new = findings.filter { !current.notSecrets.contains($0) }
        guard !new.isEmpty else { return }
        current.notSecrets.append(contentsOf: Set(new))
        current.notSecrets.sort { ($0.path, $0.line, $0.rule) < ($1.path, $1.line, $1.rule) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(current).write(to: storeURL.appending(path: Self.acknowledgementsFile), options: .atomic)
    }

    func acknowledgements() -> Acknowledgements {
        guard let data = try? Data(contentsOf: storeURL.appending(path: Self.acknowledgementsFile)),
              let decoded = try? JSONDecoder().decode(Acknowledgements.self, from: data) else { return Acknowledgements() }
        return decoded
    }

    /// The one-time check of a store from before this check existed: the
    /// current files (acknowledged ones left out) and every earlier version
    /// Git keeps.
    func fullCheck() async throws -> [StoreFinding] {
        try await exclusively {
            var result = try await unacknowledgedFindingsUnlocked().map { StoreFinding(finding: $0, inEarlierVersion: false) }
            var seen = Set(result.map(\.finding))
            guard (try? await run("rev-parse", "--verify", "-q", "HEAD")) != nil else { return result }
            let current = Set(try await run("ls-tree", "-r", "HEAD").split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(separator: " ", maxSplits: 3)
                return fields.count >= 3 ? String(fields[2].prefix(while: { !$0.isWhitespace })) : nil
            })
            // Every blob the store's history reached, with a path it had. Only
            // main: the state branch holds encrypted engine state, not files.
            var pathByBlob: [String: String] = [:]
            for line in try await run("rev-list", "--objects", "HEAD").split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, pathByBlob[String(parts[0])] == nil else { continue }
                pathByBlob[String(parts[0])] = String(parts[1])
            }
            let objects = pathByBlob.keys.filter { !current.contains($0) }.sorted()
            guard !objects.isEmpty else { return result }
            let types = try await runWithInput(objects.joined(separator: "\n") + "\n",
                                               "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)")
            let blobs = types.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(separator: " ")
                guard fields.count == 3, fields[1] == "blob", let size = Int(fields[2]),
                      size <= SecretScan.maximumFileSize else { return nil }
                return String(fields[0])
            }
            // Every blob's contents in one git run, not one run per blob.
            let wanted = blobs.filter { pathByBlob[$0] != Self.acknowledgementsFile }
            guard !wanted.isEmpty else { return result }
            let batch = try await execute(["cat-file", "--batch"], input: Data((wanted.joined(separator: "\n") + "\n").utf8))
            for (blob, data) in Self.batchContents(batch) {
                guard let path = pathByBlob[blob], let text = SecretScan.scannableText(data) else { continue }
                for finding in SecretScan.scan(text: text, path: path) where seen.insert(finding).inserted {
                    result.append(StoreFinding(finding: finding, inEarlierVersion: true))
                }
            }
            return result
        }
    }

    /// `git cat-file --batch` output: per object a "<id> <type> <size>"
    /// line, its contents and a newline.
    nonisolated static func batchContents(_ output: Data) -> [(id: String, data: Data)] {
        var objects: [(id: String, data: Data)] = []
        var index = output.startIndex
        while index < output.endIndex, let newline = output[index...].firstIndex(of: 0x0A) {
            let header = String(decoding: output[index..<newline], as: UTF8.self).split(separator: " ")
            index = output.index(after: newline)
            guard header.count == 3, let size = Int(header[2]) else { continue } // "<id> missing"
            guard output.distance(from: index, to: output.endIndex) >= size else { break }
            let end = output.index(index, offsetBy: size)
            objects.append((String(header[0]), Data(output[index..<end])))
            index = end < output.endIndex ? output.index(after: end) : end
        }
        return objects
    }

    // MARK: Remote / team space

    var remoteURL: String? {
        get async throws {
            try await exclusively { await remoteURLUnlocked() }
        }
    }

    private func remoteURLUnlocked() async -> String? {
        let output = (try? await run("remote", "get-url", "origin")) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func isTeamMode() async -> Bool {
        ((try? await remoteURL) ?? nil) != nil
    }

    func attachRemote(_ url: String) async throws {
        // A token in the URL would land on git's arguments and in
        // .git/config on disk; Git must use the user's own sign-in.
        guard !RepositoryPublisher.hasCredentials(url) else { throw GitError.remoteHasCredentials }
        try await exclusively {
            if await remoteURLUnlocked() != nil {
                try await run("remote", "set-url", "origin", url)
            } else {
                try await run("remote", "add", "origin", url)
            }
            try await run("push", "-u", "origin", "main")
        }
    }

    func detachRemote() async throws {
        try await exclusively { _ = try await run("remote", "remove", "origin") }
    }

    /// Brings in what teammates pushed. Every change on this Mac is
    /// committed first (`message`), so nothing has to be stashed; a pull that
    /// runs into a conflict is undone, leaving the store as it was.
    func pull(savingChangesAs message: String = "Save changes before syncing") async throws {
        try await exclusively { try await pullUnlocked(savingChangesAs: message) }
    }

    private func pullUnlocked(savingChangesAs message: String) async throws {
        guard await remoteURLUnlocked() != nil else { return }
        _ = try await commitUnlocked(message: message)
        do {
            try await run("pull", "--rebase", "--no-autostash", "origin", "main")
        } catch {
            let git = storeURL.appending(path: ".git")
            let inProgress = FileManager.default.fileExists(atPath: git.appending(path: "rebase-merge").path)
                || FileManager.default.fileExists(atPath: git.appending(path: "rebase-apply").path)
            guard inProgress else { throw error }
            let files = (try? await unmergedFiles()) ?? []
            _ = try? await run("rebase", "--abort")
            throw GitError.syncConflict(files: files)
        }
    }

    func push() async throws {
        try await exclusively { try await pushUnlocked() }
    }

    private func pushUnlocked() async throws {
        guard await remoteURLUnlocked() != nil else { return }
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
        try await exclusively { try await pushRebasingUnlocked() }
    }

    private func pushRebasingUnlocked() async throws {
        do {
            try await pushUnlocked()
        } catch GitError.pushRejected {
            try await pullUnlocked(savingChangesAs: "Save changes before syncing")
            try await pushUnlocked()
        }
    }

    /// One whole team sync as a single unit: commits this Mac's changes
    /// (`message`), pulls the team's, and publishes this Mac's commits.
    /// Without a team space it only commits.
    func sync(savingChangesAs message: String) async throws {
        try await exclusively {
            guard await remoteURLUnlocked() != nil else {
                _ = try await commitUnlocked(message: message)
                return
            }
            try await pullUnlocked(savingChangesAs: message)
            let ahead = (try? await run("rev-list", "--count", "origin/main..HEAD"))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
            if ahead > 0 { try await pushRebasingUnlocked() }
        }
    }

    // MARK: State branch

    /// Creates the state branch on the remote when it does not exist yet:
    /// the state backend only writes to an existing branch.
    func ensureStateBranch() async throws {
        try await exclusively {
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
    }

    /// Where fetched lock and state refs are read from; deleted right after.
    nonisolated static let scratchRefs = "refs/jamf-deployer/"

    /// What the team space's state branch holds: the tenants with state,
    /// and whether the passphrase check (`StateBackendService.passphraseCheckPath`)
    /// is there.
    struct TeamStateContents: Equatable, Sendable {
        var tenantIDs: Set<UUID>
        var hasPassphraseCheck: Bool

        init(listing: String) {
            tenantIDs = GitStoreService.tenantIDs(inStateListing: listing)
            hasPassphraseCheck = listing.split(separator: "\n").contains { $0 == StateBackendService.passphraseCheckPath }
        }
    }

    /// The state branch's files, read from a temporary ref that is deleted again.
    func teamStateContents() async throws -> TeamStateContents {
        try await exclusively {
            let ref = Self.scratchRefs + "state"
            try await run("fetch", "-q", "--depth", "1", "origin",
                          "+refs/heads/\(StateBackendService.stateBranch):\(ref)")
            let listing = try? await run("ls-tree", "-r", "--name-only", ref)
            _ = try? await run("update-ref", "-d", ref)
            guard let listing else { throw GitError.commandFailed("ls-tree", output: "The state branch couldn’t be read.") }
            return TeamStateContents(listing: listing)
        }
    }

    /// The tenants whose state is in the team space now: the files on the
    /// state branch. The passphrase check isn't a tenant.
    func tenantIDsWithTeamState() async throws -> Set<UUID> {
        try await teamStateContents().tenantIDs
    }

    nonisolated static func tenantIDs(inStateListing listing: String) -> Set<UUID> {
        Set(listing.split(separator: "\n").compactMap { line -> UUID? in
            guard let match = line.wholeMatch(of: /tenants\/([0-9A-Fa-f-]{36})\/terraform\.tfstate/) else { return nil }
            return UUID(uuidString: String(match.1))
        })
    }

    /// The engine's current state locks, one per locked tenant. Each lock is
    /// read from a temporary ref that is deleted again, so none pile up.
    func stateLocks() async -> [UUID: StateBackendService.StateLock] {
        (try? await exclusively { await stateLocksUnlocked() }) ?? [:]
    }

    private func stateLocksUnlocked() async -> [UUID: StateBackendService.StateLock] {
        // Refs earlier versions left behind.
        await deleteScratchRefs()
        guard let heads = try? await run("ls-remote", "--heads", "origin", "locks/tenants/*") else { return [:] }
        var locks: [UUID: StateBackendService.StateLock] = [:]
        for line in heads.split(separator: "\n") {
            guard let ref = line.split(separator: "\t").last.map(String.init),
                  let match = ref.firstMatch(of: /locks\/tenants\/([0-9A-Fa-f-]{36})\//),
                  let tenantID = UUID(uuidString: String(match.1))
            else { continue }
            let localRef = Self.scratchRefs + "locks/\(tenantID.uuidString)"
            let path = "tenants/\(tenantID.uuidString)/terraform.tfstate.lock"
            let fetched = (try? await run("fetch", "-q", "--depth", "1", "origin", "+\(ref):\(localRef)")) != nil
            let text = fetched ? try? await run("show", "\(localRef):\(path)") : nil
            if fetched { _ = try? await run("update-ref", "-d", localRef) }
            guard let text,
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

    private func deleteScratchRefs() async {
        guard let refs = try? await run("for-each-ref", "--format=%(refname)", Self.scratchRefs) else { return }
        for ref in refs.split(separator: "\n") {
            _ = try? await run("update-ref", "-d", String(ref))
        }
    }

    /// Releases a tenant's state lock by deleting its lock branch, when it
    /// still holds `lockID`. terraform-backend-git keeps each lock on a
    /// `locks/<state path>` branch; while one is left behind, a backend
    /// started fresh cannot even read the state, so the engine's own
    /// force-unlock (which needs init first) cannot release it.
    func deleteStateLock(tenantID: UUID, lockID: String) async throws {
        try await exclusively {
            guard await stateLocksUnlocked()[tenantID]?.lockID == lockID else { return }
            try await run("push", "-q", "origin", "--delete", "locks/tenants/\(tenantID.uuidString)/terraform.tfstate")
        }
    }

    // MARK: Plumbing

    @discardableResult
    private func run(_ arguments: String...) async throws -> String {
        String(decoding: try await execute(arguments, input: nil), as: UTF8.self)
    }

    private func runWithInput(_ input: String, _ arguments: String...) async throws -> String {
        String(decoding: try await execute(arguments, input: Data(input.utf8)), as: UTF8.self)
    }

    /// Runs git off the actor: network operations (pull, push, ls-remote)
    /// can stall for minutes and must not park an executor thread. Callers
    /// hold `exclusively`, so this never runs two at once.
    private func execute(_ arguments: [String], input: Data?) async throws -> Data {
        let storeURL = storeURL
        let logger = logger
        let tools = tools
        return try await Task.detached {
            guard Self.isGitAvailable else { throw GitError.gitUnavailable }
            let output = try GitCommand.run(arguments, in: storeURL, input: input, tools: tools)
            guard output.status == 0 else {
                // Only the subcommand: arguments can hold a remote URL with credentials.
                logger.error("git \(arguments.first ?? "", privacy: .public) failed: \(output.text.prefix(200), privacy: .private)")
                throw GitError.commandFailed(arguments.first ?? "", output: output.text)
            }
            return output.data
        }.value
    }
}
