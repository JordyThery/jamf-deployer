import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Adopt a hand-configured tenant: discover its objects, pick the ones the
/// app should manage, and import them into the tenant record — nothing is
/// recreated.
struct AdoptView: View {
    enum Step {
        case pickTypes
        case discovering
        case pickObjects
        case ready(count: Int)
        case failed(String)
    }

    @Environment(TenantStore.self) private var tenantStore
    @Environment(ActivityLog.self) private var activityLog
    @Environment(TerraformManager.self) private var terraform
    @Environment(TenantDeployService.self) private var deployService
    @Environment(\.dismiss) private var dismiss

    let tenant: Tenant
    /// Set when the user chooses Adopt → the caller opens the preview.
    @Binding var openPreviewAfterAdopt: Bool

    @State private var step: Step = .pickTypes
    @State private var resourceTypes: [JamformerRunner.ResourceType] = []
    @State private var selectedTypes: Set<String> = [
        "category", "script", "policy", "smart_computer_group",
        "static_computer_group", "computer_extension_attribute",
    ]
    @State private var typeFilter = ""
    @State private var exportURL: URL?
    @State private var objects: [ExportedObject] = []
    @State private var selectedObjects: Set<String> = []
    @State private var logTail: [String] = []

    private let runner = JamformerRunner()

    var body: some View {
        SheetFrame(
            title: "Adopt Existing Configuration — \(tenant.name)",
            systemImage: "square.and.arrow.down.on.square",
            isBusy: isBusy
        ) {
            content
        } footer: {
            footer
        }
        .frame(width: 680, height: 560)
        .task {
            resourceTypes = (try? await runner.listResourceTypes(provider: "jamfplatform")) ?? []
        }
    }

    private var isBusy: Bool {
        if case .discovering = step { return true }
        return false
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .pickTypes:
            VStack(alignment: .leading, spacing: 10) {
                Text("The app reads the tenant, shows what it finds, and imports the objects you choose into its record. Nothing in Jamf is created, changed or removed by adopting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if terraform.binaryURL == nil {
                    Label("Discovery needs the Terraform download from the Export tab first.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                HStack {
                    TextField("Filter types", text: $typeFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Button("All") { selectedTypes = Set(resourceTypes.map(\.filterKey)) }
                    Button("None") { selectedTypes = [] }
                    Spacer()
                    Text("\(selectedTypes.count) types")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(filteredTypes) { type in
                            Toggle(type.filterKey, isOn: Binding(
                                get: { selectedTypes.contains(type.filterKey) },
                                set: { on in
                                    if on { selectedTypes.insert(type.filterKey) } else { selectedTypes.remove(type.filterKey) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.callout)
                        }
                    }
                }
            }
            .padding()

        case .discovering:
            VStack(spacing: 10) {
                ProgressView("Reading the tenant…")
                ForEach(Array(logTail.suffix(3).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .pickObjects:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(objects.count) objects found — choose what the app should manage.")
                        .font(.callout)
                    Spacer()
                    Button("All") { selectedObjects = Set(objects.map(\.address)) }
                    Button("None") { selectedObjects = [] }
                }
                .controlSize(.small)
                List(objects) { object in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { selectedObjects.contains(object.address) },
                            set: { on in
                                if on { selectedObjects.insert(object.address) } else { selectedObjects.remove(object.address) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(object.displayName)
                                Text(object.resourceType)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        if object.hasProvenanceTag {
                            StatusBadge("Created by a building block", style: .warning)
                                .help("This object carries a Jamf Deployer provenance tag — it probably belongs to a building block. Adopting it here manages it as a standalone object instead.")
                        }
                    }
                }
                .listStyle(.inset)
            }
            .padding([.horizontal, .top])

        case .ready(let count):
            ContentUnavailableView {
                Label("Ready to Adopt", systemImage: "square.and.arrow.down.on.square")
            } description: {
                Text("\(count) object\(count == 1 ? "" : "s") staged. Preview Changes shows each one as “Adopt”; anything the first deploy would also change is listed with its exact differences.")
            }

        case .failed(let message):
            ContentUnavailableView(
                "Discovery Failed",
                systemImage: "xmark.octagon",
                description: Text(message)
            )
        }
    }

    private var filteredTypes: [JamformerRunner.ResourceType] {
        let base = resourceTypes.sorted { $0.filterKey < $1.filterKey }
        guard !typeFilter.isEmpty else { return base }
        return base.filter { $0.filterKey.localizedCaseInsensitiveContains(typeFilter) }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        Spacer()
        Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        switch step {
        case .pickTypes:
            Button("Discover Objects") { discover() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTypes.isEmpty || terraform.binaryURL == nil)
        case .pickObjects:
            Button("Stage \(selectedObjects.count) for Adoption") { stage() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedObjects.isEmpty)
        case .ready:
            Button("Preview Changes") {
                openPreviewAfterAdopt = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        case .discovering, .failed:
            EmptyView()
        }
    }

    // MARK: Actions

    private func discover() {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load(),
              let terraformURL = terraform.binaryURL else { return }
        step = .discovering
        logTail = []
        let types = Array(selectedTypes)
        Task {
            do {
                let result = try await runner.export(
                    tenant: tenant,
                    clientSecret: secret,
                    includeResources: types,
                    includePackageFiles: false,
                    terraformPath: terraformURL.path
                )
                logTail = result.logLines
                guard result.exitCode == 0 else {
                    step = .failed("The discovery stopped with an error. Check the Activity Log.")
                    return
                }
                exportURL = result.outputURL
                objects = try ExportedObjectInventory.scan(directory: result.outputURL)
                selectedObjects = Set(objects.filter { !$0.hasProvenanceTag }.map(\.address))
                step = objects.isEmpty
                    ? .failed("No objects of the chosen types were found.")
                    : .pickObjects
                activityLog.append(ActivityLogEntry(
                    category: "Adopt", operation: "discover", detail: tenant.name,
                    status: 200, duration: nil, note: "\(objects.count) objects"
                ))
            } catch {
                step = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func stage() {
        guard let exportURL else { return }
        do {
            try ExportedObjectInventory.prune(directory: exportURL, keeping: selectedObjects)
            try ExportedObjectInventory.normalizeImportBlocks(directory: exportURL)

            // Strip provider wiring; the workspace supplies its own.
            let fileManager = FileManager.default
            for name in ["provider.tf", "variables.tf", "terraform.tfvars", ".terraform.lock.hcl", ".gitignore", ".terraform"] {
                try? fileManager.removeItem(at: exportURL.appending(path: name))
            }

            let destination = deployService.adoptedURL(for: tenant)
            try? fileManager.removeItem(at: destination)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: exportURL, to: destination)
            step = .ready(count: selectedObjects.count)
            activityLog.append(ActivityLogEntry(
                category: "Adopt", operation: "stage", detail: tenant.name,
                status: 200, duration: nil, note: "\(selectedObjects.count) objects"
            ))
        } catch {
            step = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
