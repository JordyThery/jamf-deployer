import SwiftUI
import JTKit
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
        "category", "script", "policy", "device_groups", "computer_extension_attribute",
    ]
    @State private var typeFilter = ""
    @State private var objectFilter = ""
    @State private var exportURL: URL?
    @State private var objects: [ExportedObject] = []
    @State private var selectedObjects: Set<String> = []
    /// Objects left out because the app cannot manage them, by reason.
    @State private var unmanageableNotes: [String] = []
    /// Addresses already in the tenant's adopted configuration.
    @State private var alreadyAdopted: Set<String> = []
    /// Addresses in the export the app cannot manage.
    @State private var unmanageableAddresses: Set<String> = []
    /// Selected objects that could not be staged, and why.
    @State private var stagingNote: String?
    @State private var logTail: [String] = []
    /// Possible secrets, by object: from jamformer's scan and the app's own.
    @State private var secretObjects: [SecretObjectFinding] = []
    /// Objects holding a possible secret: they cannot be staged, because
    /// adopted objects are saved in the store (and in Team Mode shared).
    @State private var secretAddresses: Set<String> = []

    private var runner: JamformerRunner { JamformerRunner(tools: deployService.tools) }

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
            resourceTypes = (try? await runner.listResourceTypes(provider: tenant.connection.exporterProvider)) ?? []
            // The defaults are Jamf Platform API type names; keep only the
            // ones this connection offers.
            if !resourceTypes.isEmpty {
                selectedTypes.formIntersection(resourceTypes.map(\.filterKey))
            }
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
                    Text("\(selectedTypes.count) type\(selectedTypes.count == 1 ? "" : "s") selected")
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
                    Text("\(objects.count) object\(objects.count == 1 ? "" : "s") found — choose what the app should manage.")
                        .font(.callout)
                    Spacer()
                    TextField("Filter objects", text: $objectFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Button("All") { selectedObjects.formUnion(filteredObjects.map(\.address).filter { !secretAddresses.contains($0) }) }
                        .help("Selects every object the filter shows")
                    Button("None") { selectedObjects.subtract(filteredObjects.map(\.address)) }
                        .help("Deselects every object the filter shows")
                }
                .controlSize(.small)
                if !secretObjects.isEmpty {
                    SecretObjectsNotice(
                        findings: secretObjects,
                        message: "These may contain a secret, so they can't be adopted: adopted objects are saved in the tenant record. Remove the secret in Jamf (a script parameter, for example), then discover again.")
                }
                if !unmanageableNotes.isEmpty {
                    Text("Left out — the app cannot manage these: " + unmanageableNotes.joined(separator: "; ") + ". They stay in Jamf unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !alreadyAdopted.isEmpty {
                    Text("Objects already adopted are not listed; they stay managed as they are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                List(filteredObjects) { object in
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
                        .disabled(secretAddresses.contains(object.address))
                        Spacer()
                        if secretAddresses.contains(object.address) {
                            let rules = secretObjects.filter { $0.address == object.address }.map(\.rule).joined(separator: ", ")
                            StatusBadge("Possible secret", style: .warning)
                                .help(rules)
                                .accessibilityLabel("Possible secret: \(rules)")
                        } else if object.hasProvenanceTag {
                            StatusBadge("Created by a building block", style: .warning)
                                .help("Tagged by Jamf Deployer, so it likely belongs to a building block")
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
                VStack(spacing: 6) {
                    Text("\(count) object\(count == 1 ? "" : "s") staged. Preview Changes shows each one as “Adopt”; anything the first deploy would also change is listed with its exact differences.")
                    if let stagingNote {
                        Text(stagingNote)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

        case .failed(let message):
            ContentUnavailableView(
                "Discovery Failed",
                systemImage: "xmark.octagon",
                description: Text(message)
            )
        }
    }

    /// Objects whose name or type matches the filter; selections outside
    /// the filter are kept.
    private var filteredObjects: [ExportedObject] {
        guard !objectFilter.isEmpty else { return objects }
        return objects.filter {
            $0.displayName.localizedCaseInsensitiveContains(objectFilter)
                || $0.resourceType.localizedCaseInsensitiveContains(objectFilter)
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
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            step = .failed("The tenant's stored credentials are missing. Enter them on the tenant page (Update Client Secret… or Update Password…).")
            return
        }
        guard let terraformURL = terraform.binaryURL else { return }
        step = .discovering
        logTail = []
        // Only names the exporter offers: an unknown name aborts the export.
        let available = Set(resourceTypes.map(\.filterKey))
        let types = available.isEmpty ? Array(selectedTypes) : Array(selectedTypes.intersection(available))
        Task {
            do {
                let result = try await runner.export(
                    tenant: tenant,
                    clientSecret: secret,
                    provider: tenant.connection.exporterProvider,
                    includeResources: types,
                    includePackageFiles: false,
                    terraformPath: terraformURL.path,
                    onLine: { line in
                        Task { @MainActor in logTail.append(line) }
                    }
                )
                guard result.exitCode == 0 else {
                    step = .failed("The discovery stopped with an error. Check the Activity Log.")
                    return
                }
                exportURL = result.outputURL
                let unmanageable = ExportedObjectInventory.unmanageable(directory: result.outputURL)
                unmanageableAddresses = Set(unmanageable.keys)
                alreadyAdopted = Set(((try? ExportedObjectInventory.scan(
                    directory: deployService.adoptedURL(for: tenant))) ?? []).map(\.address))
                let found = try ExportedObjectInventory.scan(directory: result.outputURL)
                    .filter { unmanageable[$0.address] == nil }
                objects = found.filter { !alreadyAdopted.contains($0.address) }
                unmanageableNotes = Dictionary(grouping: unmanageable.values, by: { $0 })
                    .sorted { $0.key < $1.key }
                    .map { "\($0.value.count) object\($0.value.count == 1 ? "" : "s"): \($0.key)" }

                // jamformer's findings plus the app's own scan, which the
                // store check before every commit also runs.
                let own = SecretScan.objectFindings(SecretScan.scanExport(result.outputURL), in: result.outputURL)
                var seen: Set<String> = []
                secretObjects = (result.secretObjects + own).filter { seen.insert($0.id).inserted }
                secretAddresses = Set(secretObjects.compactMap(\.address))

                selectedObjects = Set(objects.filter { !$0.hasProvenanceTag && !secretAddresses.contains($0.address) }.map(\.address))
                step = objects.isEmpty
                    ? .failed(alreadyAdopted.isEmpty
                        ? "No objects of the chosen types were found."
                        : "Every object of the chosen types is already adopted.")
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
            // Objects a block already manages, and those the app cannot
            // manage, cannot be pulled in for an object that needs them.
            let blockManaged = Set(objects.filter(\.hasProvenanceTag).map(\.address)).subtracting(selectedObjects)
            // Objects holding a possible secret never reach the store, and
            // neither does anything that needs them.
            let selection = ExportedObjectInventory.adoptableSelection(
                directory: exportURL, kept: selectedObjects.subtracting(secretAddresses), alreadyManaged: alreadyAdopted,
                unavailable: unmanageableAddresses.union(blockManaged).union(secretAddresses))
            let kept = selection.kept
            let leftOutNames = objects.filter { selection.leftOut.contains($0.address) }.map(\.displayName).sorted()
            stagingNote = leftOutNames.isEmpty ? nil
                : "Not staged — they depend on objects the app cannot adopt: \(leftOutNames.joined(separator: ", "))."
            guard !kept.isEmpty else {
                step = .failed(stagingNote ?? "Nothing was selected to adopt.")
                return
            }
            try ExportedObjectInventory.pinReferences(directory: exportURL, keeping: kept.union(alreadyAdopted))
            try ExportedObjectInventory.prune(directory: exportURL, keeping: kept)
            try ExportedObjectInventory.normalizeImportBlocks(directory: exportURL)
            try ExportedObjectInventory.inlineVariables(directory: exportURL)
            try ExportedObjectInventory.protectOmittedSections(directory: exportURL)

            // Sensitive values are never written into the configuration:
            // they stay variables, with their values in this Mac's Keychain.
            let sensitive = ExportedObjectInventory.sensitiveVariables(directory: exportURL)
            let secrets = TenantSecrets(tenantID: tenant.id)
            for variable in sensitive {
                guard let value = variable.value else {
                    step = .failed("Jamf did not export the sensitive value “\(variable.name)”, so nothing was staged.")
                    return
                }
                guard secrets.adoptedVariable(variable.name).save(value) else {
                    step = .failed("The sensitive value “\(variable.name)” could not be stored in the Keychain, so nothing was staged.")
                    return
                }
            }

            // Strip provider wiring; the workspace supplies its own.
            let fileManager = FileManager.default
            for name in ["provider.tf", "versions.tf", "variables.tf", "terraform.tfvars", ".terraform.lock.hcl", ".gitignore", ".terraform"] {
                try? fileManager.removeItem(at: exportURL.appending(path: name))
            }

            let destination = deployService.adoptedURL(for: tenant)
            if alreadyAdopted.isEmpty {
                try? fileManager.removeItem(at: destination)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: exportURL, to: destination)
            } else {
                try Self.merge(exportURL, into: destination)
            }
            try ExportedObjectInventory.mergeSensitiveDeclarations(
                sensitive, into: destination.appending(path: TenantDeployService.adoptedSensitiveVariablesFile))
            step = .ready(count: kept.count)
            activityLog.append(ActivityLogEntry(
                category: "Adopt", operation: "stage", detail: tenant.name,
                status: 200, duration: nil, note: "\(kept.count) objects"
            ))
        } catch {
            step = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Adds a staged export to existing adopted configuration. Files get a
    /// unique prefix (keeping the `_import.tf` suffix the deploy cleanup
    /// looks for); support files already present are kept.
    private static func merge(_ source: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        let stamp = DeployHistoryEntry.makeID()
        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            if item.pathExtension == "tf" {
                try fileManager.moveItem(at: item, to: destination.appending(path: "adopt-\(stamp)-\(item.lastPathComponent)"))
            } else if item.lastPathComponent == "support_files" {
                let base = item.resolvingSymlinksInPath().path
                let enumerator = fileManager.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey])
                while let file = enumerator?.nextObject() as? URL {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let relative = String(file.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
                    let target = destination.appending(path: "support_files/\(relative)")
                    guard !fileManager.fileExists(atPath: target.path) else { continue }
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: file, to: target)
                }
            }
        }
        try? fileManager.removeItem(at: source)
    }
}
