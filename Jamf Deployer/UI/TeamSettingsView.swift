import SwiftUI
import AppKit

/// Settings → Team: the safe switch into (and out of) a shared store.
///
/// A team space is a Git repository: tenant records, history and catalog
/// sources on its main branch, every tenant's encrypted deployment state on
/// a separate branch written by the state backend, which also locks a
/// tenant's state while an engineer previews, checks or deploys it.
struct TeamSettingsView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(CatalogSourceStore.self) private var catalogSources
    @Environment(TenantDeployService.self) private var deployService

    @State private var remoteURLField = ""
    @State private var passphraseField = ""
    @State private var newPassphrase = TeamPassphrase.generate()
    @State private var hasSavedPassphrase = false
    @State private var isCreating = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var isConfirmingLeave = false
    @State private var isShowingPassphrase = false
    @State private var hasTeamPassphrase = TeamPassphrase.item.load() != nil

    var body: some View {
        Section {
            if deployService.isTeamMode {
                teamModeControls
            } else {
                soloControls
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let syncMessage = deployService.syncMessage {
                Label(syncMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        } header: {
            Text("Team")
        } footer: {
            Text(deployService.isTeamMode
                ? "Tenant records, history and the list of catalog sources sync through the team space. Each tenant's deployment state is stored encrypted on the repository's \(StateBackendService.stateBranch) branch and locked while someone previews, checks or deploys it. Every engineer signs in to tenants with their own API client or account, kept in their own Keychain."
                : "A team space is a Git repository (for example on GitHub) that tenants, history and catalog sources sync through; each tenant's deployment state is stored encrypted on a separate branch of it. Git authentication uses your existing git, gh or SSH setup. A full backup of this Mac's store is made before anything changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Leave Team Mode?",
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Leave Team Mode", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every tenant's deployment state is copied back to this Mac and this Mac stops syncing. The team space itself is untouched.")
        }
    }

    // MARK: Team mode

    @ViewBuilder
    private var teamModeControls: some View {
        LabeledContent("Team space") {
            Text(deployService.teamRemoteURL ?? "—")
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        if let lastSync = deployService.lastSync {
            LabeledContent("Last synced", value: lastSync.formatted(.relative(presentation: .named)))
        }
        HStack {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync() }
            Button("Leave Team Mode…", role: .destructive) { isConfirmingLeave = true }
        }
        .disabled(isWorking)

        if hasTeamPassphrase {
            LabeledContent("Team passphrase") {
                HStack {
                    if isShowingPassphrase {
                        Text(TeamPassphrase.item.load() ?? "")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Button("Copy") {
                            Self.copyConcealed(TeamPassphrase.item.load() ?? "")
                        }
                        .controlSize(.small)
                    }
                    Button(isShowingPassphrase ? "Hide" : "Show") { isShowingPassphrase.toggle() }
                        .controlSize(.small)
                        .help("Shows the passphrase to share with an engineer joining the team space")
                }
            }
        } else {
            passphraseEntry(prompt: "This Mac needs the team passphrase to read the team's deployment state. Ask a teammate for it.")
        }
    }

    // MARK: Solo

    @ViewBuilder
    private var soloControls: some View {
        TextField(
            "Repository URL",
            text: $remoteURLField,
            prompt: Text("https://github.com/org/jamf-deployer-space.git")
        )
        .font(.callout.monospaced())
        if isCreating {
            VStack(alignment: .leading, spacing: 6) {
                Text("Team passphrase")
                    .font(.callout.bold())
                Text("It encrypts every tenant's deployment state in the team space. Save it in your team's password manager now: engineers enter it when they join, and without it the state cannot be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(newPassphrase)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("Copy") {
                        Self.copyConcealed(newPassphrase)
                    }
                    .controlSize(.small)
                }
                Toggle("I saved the team passphrase", isOn: $hasSavedPassphrase)
                    .toggleStyle(.checkbox)
                HStack {
                    Button("Cancel") { isCreating = false }
                    Button("Create Team Space") { createTeamSpace() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasSavedPassphrase || isWorking)
                }
            }
        } else {
            SecureField("Team passphrase", text: $passphraseField, prompt: Text("Needed to join"))
            HStack {
                Button("Create Team Space…") {
                    newPassphrase = TeamPassphrase.generate()
                    hasSavedPassphrase = false
                    isCreating = true
                }
                .help("Publishes this Mac's tenants to an empty repository as a new team space")
                Button("Join Team Space") { joinTeamSpace() }
                    .help("Clones an existing team space with its team passphrase; this Mac's current tenants are imported into it")
                    .disabled(passphraseField.isEmpty)
            }
            .disabled(remoteURLField.isEmpty || isWorking || !GitStoreService.isGitAvailable)
            if !GitStoreService.isGitAvailable {
                Text("Team spaces need Git. Install the Xcode Command Line Tools (xcode-select --install), then reopen Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func passphraseEntry(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(prompt, systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            HStack {
                SecureField("Team passphrase", text: $passphraseField)
                Button("Save") { savePassphrase() }
                    .disabled(passphraseField.isEmpty || isWorking)
            }
        }
    }

    // MARK: Actions

    private func sync() {
        isWorking = true
        Task {
            await deployService.syncTeamState()
            isWorking = false
        }
    }

    private func savePassphrase() {
        let passphrase = passphraseField.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task {
            defer { isWorking = false }
            guard TeamPassphrase.item.save(passphrase) else {
                message = "The Keychain did not accept the passphrase."
                return
            }
            do {
                if try await deployService.checkTeamPassphrase() {
                    hasTeamPassphrase = true
                    passphraseField = ""
                    message = "Team passphrase saved."
                } else {
                    TeamPassphrase.item.delete()
                    message = TeamError.wrongPassphrase.errorDescription
                }
            } catch {
                TeamPassphrase.item.delete()
                message = "The passphrase could not be checked: \(Self.describe(error))"
            }
        }
    }

    /// Publishes this store as a new team space (after a local backup) and
    /// moves every tenant's deployment state into it. If any step after
    /// publishing fails, this Mac goes back to working alone, unchanged.
    private func createTeamSpace() {
        let remote = remoteURLField.trimmingCharacters(in: .whitespaces)
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await Self.backUpStore()
                try await deployService.gitStore.ensureRepo()
                _ = try await deployService.commitStore(message: "Prepare team space")
                do {
                    try await deployService.gitStore.attachRemote(remote)
                } catch {
                    try? await deployService.gitStore.detachRemote()
                    throw TeamError.repositoryNotEmpty
                }
                do {
                    try await deployService.gitStore.ensureStateBranch()
                    guard TeamPassphrase.item.save(newPassphrase) else { throw TeamError.keychain }
                    await deployService.syncTeamState()
                    try await deployService.moveStateToTeam(tenants: tenantStore.tenants)
                    _ = try await deployService.commitStore(message: "Create team space")
                    try await deployService.gitStore.pushRebasing()
                } catch {
                    // Local state is only retired once everything succeeded.
                    try? await deployService.gitStore.detachRemote()
                    TeamPassphrase.item.delete()
                    await deployService.syncTeamState()
                    throw TeamError.createFailed(Self.describe(error))
                }
                deployService.retireLocalState(of: tenantStore.tenants)
                hasTeamPassphrase = true
                isCreating = false
                message = "Team space created. Engineers join with the same URL and the team passphrase."
            } catch {
                message = Self.describe(error)
            }
        }
    }

    /// Clones an existing team space and brings this Mac's tenants into it.
    /// If any step after the clone fails, this Mac's own store comes back.
    private func joinTeamSpace() {
        let remote = remoteURLField.trimmingCharacters(in: .whitespaces)
        let passphrase = passphraseField.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await Self.backUpStore()
                let imported: Set<UUID>
                do {
                    imported = try await Task.detached { try Self.join(remote: remote) }.value
                } catch {
                    // The swap can fail after the store moved aside.
                    try? await Task.detached { try Self.restoreReplacedStore() }.value
                    tenantStore.reload()
                    catalogSources.reload()
                    throw TeamError.joinFailed(Self.describe(error))
                }
                do {
                    tenantStore.reload()
                    catalogSources.reload()
                    try await deployService.gitStore.ensureRepo()
                    guard TeamPassphrase.item.save(passphrase) else { throw TeamError.keychain }
                    await deployService.syncTeamState()
                    try await deployService.gitStore.ensureStateBranch()
                    guard try await deployService.checkTeamPassphrase() else { throw TeamError.wrongPassphrase }
                    let importedTenants = tenantStore.tenants.filter { imported.contains($0.id) }
                    try await deployService.moveStateToTeam(tenants: importedTenants)
                    if !imported.isEmpty {
                        _ = try await deployService.commitStore(
                            message: "Import \(imported.count) tenant\(imported.count == 1 ? "" : "s") from a joining Mac")
                        try await deployService.gitStore.pushRebasing()
                    }
                    deployService.retireLocalState(of: importedTenants)
                } catch {
                    TeamPassphrase.item.delete()
                    try? await Task.detached { try Self.restoreReplacedStore() }.value
                    tenantStore.reload()
                    catalogSources.reload()
                    await deployService.syncTeamState()
                    throw TeamError.joinFailed(Self.describe(error))
                }
                hasTeamPassphrase = true
                passphraseField = ""
                message = imported.isEmpty
                    ? "Joined the team space."
                    : "Joined the team space and imported \(imported.count) local tenant\(imported.count == 1 ? "" : "s")."
            } catch {
                message = Self.describe(error)
            }
        }
    }

    private func leave() {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await deployService.moveStateToLocal()
                try await deployService.gitStore.detachRemote()
                adoptEngineerClientIDs()
                _ = try? await deployService.commitStore(message: "Leave team space")
                await deployService.syncTeamState()
                TeamPassphrase.item.delete()
                hasTeamPassphrase = false
                isShowingPassphrase = false
                message = "Left Team Mode — everything stays on this Mac. Save a new recovery sheet for each tenant before its next deploy."
            } catch {
                message = Self.describe(error)
            }
        }
    }

    /// Working alone, this Mac's own API client or account becomes the one in
    /// each tenant's record.
    private func adoptEngineerClientIDs() {
        for tenant in tenantStore.tenants {
            let item = TenantSecrets(tenantID: tenant.id).engineerClientID
            guard let clientID = item.load() else { continue }
            var updated = tenant
            updated.clientID = clientID
            tenantStore.update(updated)
            item.delete()
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Zips the whole store before any conversion: the universal escape hatch.
    nonisolated static func backUpStore() async throws {
        try await Task.detached {
            let store = GitStoreService.storeURL
            guard FileManager.default.fileExists(atPath: store.path) else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let backup = store.deletingLastPathComponent()
                .appending(path: "store-backup-\(formatter.string(from: .now)).zip")
            let ditto = Process()
            ditto.standardInput = FileHandle.nullDevice
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--sequesterRsrc", store.path, backup.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw TeamError.backupFailed }
        }.value
    }

    nonisolated enum TeamError: LocalizedError {
        case backupFailed
        case repositoryNotEmpty
        case keychain
        case wrongPassphrase
        case createFailed(String)
        case joinFailed(String)

        var errorDescription: String? {
            switch self {
            case .backupFailed:
                "The store could not be backed up, so nothing was changed. Check the free disk space and try again."
            case .repositoryNotEmpty:
                "The repository could not be used: it already has content, or Git could not push to it. Use an empty repository you can push to, or join the team space instead."
            case .keychain:
                "The Keychain did not accept the team passphrase."
            case .wrongPassphrase:
                "That passphrase does not open the team's deployment state. Check it with a teammate."
            case .createFailed(let reason):
                "The team space could not be created: \(reason) This Mac is unchanged. The repository may hold a partial copy now, so empty it before trying again."
            case .joinFailed(let reason):
                "\(reason) This Mac is unchanged; join again when that is resolved."
            }
        }
    }

    /// Puts this Mac's own store back after a join that did not finish.
    /// Copies a secret to the pasteboard marked concealed, so clipboard
    /// managers and pasteboard history skip it.
    private static func copyConcealed(_ text: String) {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealed)
    }

    nonisolated static func restoreReplacedStore() throws {
        let fileManager = FileManager.default
        let store = GitStoreService.storeURL
        let retired = store.deletingLastPathComponent().appending(path: "store-replaced")
        // No retired copy means the swap never happened: leave the store be.
        guard fileManager.fileExists(atPath: retired.path) else { return }
        try? fileManager.removeItem(at: store)
        try fileManager.moveItem(at: retired, to: store)
    }

    /// Clone to a fresh folder, swap stores, import local tenants. Returns
    /// the imported tenants' IDs.
    nonisolated static func join(remote: String) throws -> Set<UUID> {
        guard !RepositoryPublisher.hasCredentials(remote) else { throw GitStoreService.GitError.remoteHasCredentials }
        let fileManager = FileManager.default
        let store = GitStoreService.storeURL
        let fresh = store.deletingLastPathComponent().appending(path: "store-joining")
        try? fileManager.removeItem(at: fresh)

        let clone = Process()
        clone.standardInput = FileHandle.nullDevice
        clone.executableURL = URL(filePath: "/usr/bin/git")
        clone.arguments = ["clone", "--branch", "main", "--", remote, fresh.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        clone.environment = environment
        let output = Pipe()
        clone.standardOutput = output
        clone.standardError = output
        try clone.run()
        let log = output.fileHandleForReading.readDataToEndOfFile()
        clone.waitUntilExit()
        guard clone.terminationStatus == 0 else {
            throw GitStoreService.GitError.commandFailed("clone", output: String(decoding: log, as: UTF8.self))
        }
        guard fileManager.fileExists(atPath: fresh.appending(path: "store.json").path) else {
            try? fileManager.removeItem(at: fresh)
            throw GitStoreService.GitError.commandFailed("clone", output: "The repository is not a Jamf Deployer team space (store.json missing).")
        }

        // Import local tenants the team space doesn't know yet.
        var imported: Set<UUID> = []
        let localTenants = store.appending(path: "tenants")
        let freshTenants = fresh.appending(path: "tenants")
        try? fileManager.createDirectory(at: freshTenants, withIntermediateDirectories: true)
        for folder in (try? fileManager.contentsOfDirectory(at: localTenants, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let destination = freshTenants.appending(path: folder.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.copyItem(at: folder, to: destination)
            imported.insert(id)
        }

        // Swap stores (the zip backup already exists).
        let retired = store.deletingLastPathComponent().appending(path: "store-replaced")
        try? fileManager.removeItem(at: retired)
        if fileManager.fileExists(atPath: store.path) {
            try fileManager.moveItem(at: store, to: retired)
        } else {
            // A marker, so a failed join knows the swap happened and
            // restores "no store" rather than keeping a half-joined one.
            try fileManager.createDirectory(at: retired, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: fresh, to: store)
        return imported
    }
}
