import SwiftUI
import AppKit
import DeployerKit

/// Settings → Team: the safe switch into (and out of) a shared store.
///
/// A team space is a Git repository: tenant records, history and catalog
/// sources on its main branch, every tenant's encrypted engine state on a
/// separate branch written by the state backend, which also locks a
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
                ? "Tenant records, history and the list of catalog sources sync through the team space. Each tenant's record is stored encrypted on the repository's \(StateBackendService.stateBranch) branch and locked while someone previews, checks or deploys it. Every engineer signs in to tenants with their own API client or account, kept in their own Keychain."
                : "A team space is a Git repository (for example on GitHub) that tenants, history and catalog sources sync through; tenant records are stored encrypted on a separate branch of it. Git authentication uses your existing git, gh or SSH setup. A full backup of this Mac's store is made before anything changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Leave team mode?",
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Leave Team Mode", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every tenant's record is copied back to this Mac and this Mac stops syncing. The team space itself is untouched.")
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
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(TeamPassphrase.item.load() ?? "", forType: .string)
                        }
                        .controlSize(.small)
                    } else {
                        Button("Show") { isShowingPassphrase = true }
                            .controlSize(.small)
                            .help("Shows the passphrase to share with an engineer joining the team space")
                    }
                }
            }
        } else {
            passphraseEntry(prompt: "This Mac needs the team passphrase to read the team's tenant records. Ask a teammate for it.")
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
                Text("It encrypts every tenant record in the team space. Save it in your team's password manager now: engineers enter it when they join, and without it the records cannot be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(newPassphrase)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(newPassphrase, forType: .string)
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
                Button("Join Team Space…") { joinTeamSpace() }
                    .help("Clones an existing team space with its team passphrase; this Mac's current tenants are imported into it")
                    .disabled(passphraseField.isEmpty)
            }
            .disabled(remoteURLField.isEmpty || isWorking || !GitStoreService.isGitAvailable)
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
            if await deployService.teamPassphraseOpensRecords() {
                hasTeamPassphrase = true
                passphraseField = ""
                message = "Team passphrase saved."
            } else {
                TeamPassphrase.item.delete()
                message = "That passphrase does not open the team's tenant records. Check it with a teammate."
            }
        }
    }

    /// Publish this store as a new team space (after a local backup), then
    /// move every tenant's record into it.
    private func createTeamSpace() {
        let remote = remoteURLField.trimmingCharacters(in: .whitespaces)
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try backUpStore()
                try await deployService.gitStore.ensureRepo()
                _ = try await deployService.gitStore.commitAll(message: "Prepare team space")
                do {
                    try await deployService.gitStore.attachRemote(remote)
                } catch {
                    try? await deployService.gitStore.detachRemote()
                    throw TeamError.repositoryNotEmpty
                }
                try await deployService.gitStore.ensureStateBranch()
                guard TeamPassphrase.item.save(newPassphrase) else { throw TeamError.keychain }
                await deployService.syncTeamState()
                try await deployService.moveStateToTeam(tenants: tenantStore.tenants)
                _ = try await deployService.gitStore.commitAll(message: "Move tenant records to the state backend")
                try await deployService.gitStore.pushRebasing()
                hasTeamPassphrase = true
                isCreating = false
                message = "Team space created. Engineers join with the same URL and the team passphrase."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Clone an existing team space and bring this Mac's tenants into it.
    private func joinTeamSpace() {
        let remote = remoteURLField.trimmingCharacters(in: .whitespaces)
        let passphrase = passphraseField.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try backUpStore()
                let imported = try await Self.join(remote: remote)
                tenantStore.reload()
                catalogSources.reload()
                guard TeamPassphrase.item.save(passphrase) else { throw TeamError.keychain }
                await deployService.syncTeamState()
                try await deployService.gitStore.ensureStateBranch()
                guard await deployService.teamPassphraseOpensRecords() else {
                    TeamPassphrase.item.delete()
                    hasTeamPassphrase = false
                    message = "Joined, but that passphrase does not open the team's tenant records. Enter the right one below."
                    return
                }
                try await deployService.moveStateToTeam(
                    tenants: tenantStore.tenants.filter { imported.contains($0.id) })
                if !imported.isEmpty {
                    _ = try await deployService.gitStore.commitAll(
                        message: "Import \(imported.count) tenant\(imported.count == 1 ? "" : "s") from a joining Mac")
                    try await deployService.gitStore.pushRebasing()
                }
                hasTeamPassphrase = true
                passphraseField = ""
                message = imported.isEmpty
                    ? "Joined the team space."
                    : "Joined the team space and imported \(imported.count) local tenant\(imported.count == 1 ? "" : "s")."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
                await deployService.syncTeamState()
                TeamPassphrase.item.delete()
                hasTeamPassphrase = false
                message = "Left team mode — everything stays on this Mac. Save a new recovery sheet for each tenant before its next deploy."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Zip the whole store before any conversion: the universal escape hatch.
    private func backUpStore() throws {
        let store = GitStoreService.storeURL
        guard FileManager.default.fileExists(atPath: store.path) else { return }
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeSeparator(.omitted).dateTimeSeparator(.standard)).replacingOccurrences(of: ":", with: "")
        let backup = store.deletingLastPathComponent().appending(path: "store-backup-\(stamp).zip")
        let ditto = Process()
        ditto.standardInput = FileHandle.nullDevice
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", store.path, backup.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw TeamError.backupFailed }
    }

    nonisolated enum TeamError: LocalizedError {
        case backupFailed
        case repositoryNotEmpty
        case keychain

        var errorDescription: String? {
            switch self {
            case .backupFailed:
                "The store could not be backed up, so nothing was changed. Check the free disk space and try again."
            case .repositoryNotEmpty:
                "The repository could not be used: it already has content, or Git could not push to it. Use an empty repository you can push to, or join the team space instead."
            case .keychain:
                "The Keychain did not accept the team passphrase."
            }
        }
    }

    /// Clone to a fresh folder, swap stores, import local tenants. Returns
    /// the imported tenants' IDs.
    nonisolated static func join(remote: String) async throws -> Set<UUID> {
        let fileManager = FileManager.default
        let store = GitStoreService.storeURL
        let fresh = store.deletingLastPathComponent().appending(path: "store-joining")
        try? fileManager.removeItem(at: fresh)

        let clone = Process()
        clone.standardInput = FileHandle.nullDevice
        clone.executableURL = URL(filePath: "/usr/bin/git")
        clone.arguments = ["clone", "--branch", "main", remote, fresh.path]
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
        }
        try fileManager.moveItem(at: fresh, to: store)
        return imported
    }
}
