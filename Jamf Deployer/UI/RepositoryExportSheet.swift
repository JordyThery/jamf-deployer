import SwiftUI
import AppKit
import DeployerKit

/// Export as Terraform: writes tenants as an ordinary Terraform repository
/// (one module per building block, one folder per tenant, GitHub workflows),
/// either to review, or to move the tenants there for good.
struct RepositoryExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService

    @State private var chosen: Set<UUID> = []
    @State private var folder: URL?
    @State private var movesTenants = false
    @State private var remoteURL = ""
    @State private var acceptsMove = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var result: TenantDeployService.RepositoryExportResult?

    private var tenants: [Tenant] {
        tenantStore.tenants.filter { !$0.isHandedOver }
    }

    private func blocker(for tenant: Tenant) -> String? {
        if tenant.handOverPending { return "A hand-over is in progress." }
        if !tenant.pendingRemovals.isEmpty { return "Removals are waiting to be deployed." }
        if let lock = deployService.lock(for: tenant.id) { return "\(lock.engineer) is working on this tenant." }
        return nil
    }

    /// Baseline edits that were never deployed are exported as they are; a
    /// move refuses them (the repository must start with nothing to apply).
    private func hasUndeployedBlocks(_ tenant: Tenant) -> Bool {
        tenant.blockSelections.contains { tenant.deployedBlockVersions[$0.blockID] == nil }
            || tenant.deployedBlockVersions.keys.contains { id in !tenant.blockSelections.contains { $0.blockID == id } }
    }

    private var canExport: Bool {
        !chosen.isEmpty && folder != nil && !isWorking
            && (!movesTenants || (!remoteURL.trimmingCharacters(in: .whitespaces).isEmpty && acceptsMove))
    }

    var body: some View {
        SheetFrame(title: "Export as Terraform", systemImage: "shippingbox", isBusy: isWorking) {
            if let result {
                outcome(result)
            } else {
                form
            }
        } footer: {
            Spacer()
            if result != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(movesTenants ? "Export and Move" : "Export") { export() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .frame(width: 620, height: 720)
        .onAppear {
            // Moving archives tenants here, so the choice is always explicit
            // unless there is only one.
            if tenants.count == 1, let only = tenants.first, blocker(for: only) == nil {
                chosen = [only.id]
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Text("Writes the chosen tenants as an ordinary Terraform repository: one module per building block, one folder per tenant with its settings, and GitHub workflows that plan pull requests, apply merges and check for changes made in Jamf. Nothing is recreated: each tenant's objects carry over as they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Tenants") {
                ForEach(tenants) { tenant in
                    let reason = blocker(for: tenant)
                    Toggle(isOn: Binding(
                        get: { chosen.contains(tenant.id) },
                        set: { if $0 { chosen.insert(tenant.id) } else { chosen.remove(tenant.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tenant.name)
                            Text(reason ?? (hasUndeployedBlocks(tenant)
                                    ? "\(tenant.connectionLabel) · has blocks that are not deployed"
                                    : tenant.connectionLabel))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(reason != nil)
                }
            }

            Section("Folder") {
                LabeledContent("Repository folder") {
                    HStack {
                        Text(folder?.path(percentEncoded: false) ?? "None chosen")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Text("An empty folder. It becomes the repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After the export") {
                Picker("After the export", selection: $movesTenants) {
                    Text("Keep managing here").tag(false)
                    Text("Move to a repository").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if movesTenants {
                    TextField("Repository URL", text: $remoteURL, prompt: Text("https://github.com/org/jamf-tenants.git"))
                        .font(.callout.monospaced())
                    Text("An empty private repository you can push to. Each tenant's state moves to its terraform-state branch, and the export becomes its first commit. Tenants must have nothing left to deploy. Terraform stores state unencrypted, so keep the repository private.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Stop managing these tenants in this app", isOn: $acceptsMove)
                        .toggleStyle(.checkbox)
                    Text("From then on the repository manages them: change them with pull requests. Here they are archived, and every object stays in Jamf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Review the code at your own pace. The tenants and their state stay in this app; export again with Move to a repository when you are ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func outcome(_ result: TenantDeployService.RepositoryExportResult) -> some View {
        Form {
            Section {
                Label(
                    result.moved
                        ? "Moved \(result.tenantFolders.count) tenant\(result.tenantFolders.count == 1 ? "" : "s") to \(remoteURL)."
                        : "Exported \(result.tenantFolders.count) tenant\(result.tenantFolders.count == 1 ? "" : "s").",
                    systemImage: "checkmark.circle.fill"
                )
                LabeledContent("Folder", value: result.folder.path(percentEncoded: false))
            }
            Section("Next steps") {
                if result.moved {
                    Text("1. Create each tenant's GitHub Environments: in the folder, run ./create-environments.sh with the repository's OWNER/NAME. It asks for each secret with typing hidden and sends it straight to GitHub; plans can use a read-only client.")
                    Text("2. Protect main: require a pull request, an approving review and the Plan result check (README.md, Setting up).")
                    Text("3. Make the next change with a pull request. Its plan should show only that change.")
                } else {
                    Text("Read README.md for how the repository works. Each tenant's folder under tenants/ holds its settings in tenant.auto.tfvars.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Section {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.folder])
                    }
                    Button("Open README") {
                        NSWorkspace.shared.open(result.folder.appending(path: "README.md"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose an empty folder for the repository."
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func export() {
        guard let folder else { return }
        let selected = tenants.filter { chosen.contains($0.id) }
        let remote = movesTenants ? remoteURL.trimmingCharacters(in: .whitespaces) : nil
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                result = try await deployService.exportRepository(selected, to: folder, remote: remote)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
