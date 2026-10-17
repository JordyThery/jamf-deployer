import SwiftUI
import AppKit
import DeployerKit

/// Settings → Team: the safe switch into (and out of) a shared store.
struct TeamSettingsView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(CatalogSourceStore.self) private var catalogSources
    @Environment(TenantDeployService.self) private var deployService

    @State private var remoteURLField = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var isConfirmingLeave = false
    @AppStorage("engineerName") private var engineerName = ""

    var body: some View {
        Section {
            if deployService.isTeamMode {
                LabeledContent("Team space") {
                    Text(deployService.teamRemoteURL ?? "—")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if let lastSync = deployService.lastSync {
                    LabeledContent("Last synced", value: lastSync.formatted(.relative(presentation: .named)))
                }
                HStack {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        sync()
                    }
                    Button("Leave Team Mode…", role: .destructive) {
                        isConfirmingLeave = true
                    }
                }
                .disabled(isWorking)

                // End-to-end encrypted credential sharing.
                let secrets = deployService.teamSecrets
                VStack(alignment: .leading, spacing: 6) {
                    Button("Share Credentials with the Team…", systemImage: "key.radiowaves.forward") {
                        shareSecrets()
                    }
                    .disabled(isWorking)
                    .help("Encrypts each tenant's credentials to every published engineer key and commits only the ciphertext. New engineers get working tenants on their first sync.")
                    if !secrets.publishedEngineers.isEmpty {
                        Text("Keys published: \(secrets.publishedEngineers.map(\.name).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let waiting = secrets.engineersNeedingAccess()
                    if !waiting.isEmpty {
                        Label("Waiting for access: \(waiting.joined(separator: ", ")) — share credentials again to grant them.", systemImage: "person.badge.key")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if secrets.lastAbsorbed > 0 {
                        Label("Received credentials for \(secrets.lastAbsorbed) tenant(s) on the last sync.", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            } else {
                TextField(
                    "Repository URL",
                    text: $remoteURLField,
                    prompt: Text("https://github.com/org/jamf-deployer-space.git")
                )
                .font(.callout.monospaced())
                HStack {
                    Button("Create Team Space…") { createTeamSpace() }
                        .help("Backs up this Mac's store, then publishes it to the empty repository as the shared team space")
                    Button("Join Team Space…") { joinTeamSpace() }
                        .help("Clones an existing team space; this Mac's current tenants are imported into it")
                }
                .disabled(remoteURLField.isEmpty || isWorking || !GitStoreService.isGitAvailable)
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
                ? "Tenant records, history and presets sync through the team space. Credentials never sync — each engineer keeps secrets in their own Keychain."
                : "A team space is a Git repository (GitHub works great) that this Mac's tenants, history and presets sync through. Git authentication uses your existing git/gh/SSH setup. A full backup is made before anything changes.")
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
            Text("This Mac keeps a full local copy and stops syncing. The team space itself is untouched.")
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

    private func shareSecrets() {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                let name = engineerName.isEmpty ? NSFullUserName() : engineerName
                try await deployService.teamSecrets.publishAllSecrets(engineerName: name)
                message = "Credentials shared — encrypted end-to-end; the repository only carries ciphertext."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Publish this store as the team space (after a local backup).
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
                try await deployService.gitStore.attachRemote(remote)
                await deployService.syncTeamState()
                message = "Team space created. Other engineers can now join with the same URL."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Clone an existing team space and bring local tenants into it.
    private func joinTeamSpace() {
        let remote = remoteURLField.trimmingCharacters(in: .whitespaces)
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try backUpStore()
                let imported = try await Self.join(remote: remote)
                tenantStore.reload()
                catalogSources.reload()
                await deployService.syncTeamState()
                message = imported == 0
                    ? "Joined the team space."
                    : "Joined the team space and imported \(imported) local tenant\(imported == 1 ? "" : "s")."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func leave() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await deployService.gitStore.detachRemote()
                await deployService.syncTeamState()
                message = "Left team mode — everything stays on this Mac."
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
    }

    /// Clone to a fresh folder, swap stores, import local tenants.
    nonisolated static func join(remote: String) async throws -> Int {
        let fileManager = FileManager.default
        let store = GitStoreService.storeURL
        let fresh = store.deletingLastPathComponent().appending(path: "store-joining")
        try? fileManager.removeItem(at: fresh)

        let clone = Process()
        clone.standardInput = FileHandle.nullDevice
        clone.executableURL = URL(filePath: "/usr/bin/git")
        clone.arguments = ["clone", remote, fresh.path]
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
        var imported = 0
        let localTenants = store.appending(path: "tenants")
        let freshTenants = fresh.appending(path: "tenants")
        try? fileManager.createDirectory(at: freshTenants, withIntermediateDirectories: true)
        for folder in (try? fileManager.contentsOfDirectory(at: localTenants, includingPropertiesForKeys: nil)) ?? [] {
            let destination = freshTenants.appending(path: folder.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.copyItem(at: folder, to: destination)
            imported += 1
        }

        // Swap stores (the zip backup already exists).
        let retired = store.deletingLastPathComponent().appending(path: "store-replaced")
        try? fileManager.removeItem(at: retired)
        if fileManager.fileExists(atPath: store.path) {
            try fileManager.moveItem(at: store, to: retired)
        }
        try fileManager.moveItem(at: fresh, to: store)

        if imported > 0 {
            let joined = GitStoreService()
            _ = try await joined.commitAll(message: "Import \(imported) tenant(s) from a joining Mac")
            try await joined.push()
        }
        return imported
    }
}
