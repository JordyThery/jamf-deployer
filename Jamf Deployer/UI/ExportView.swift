import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeployerKit
import JamfDeployerCore

/// The tenant's Export tab: capture reusable building blocks, take a full
/// snapshot, or generate as-built documentation. Exports only read; nothing
/// in the tenant changes.
struct ExportView: View {
    enum ExportKind: String, CaseIterable {
        case block = "Building block"
        case snapshot = "Full snapshot"
        case documentation = "As-built documentation"
        case clone = "Clone to tenant"
    }

    @Environment(TenantStore.self) private var tenantStore
    @Environment(ActivityLog.self) private var activityLog
    @Environment(TerraformManager.self) private var terraform
    @Environment(CatalogSourceStore.self) private var catalogSources

    let tenant: Tenant

    @State private var kind: ExportKind = .block
    @State private var exportProvider = "jamfplatform"
    @State private var resourceTypes: [JamformerRunner.ResourceType] = []
    @State private var selectedTypes: Set<String> = []
    @State private var typeFilter = ""
    @State private var includePackageFiles = false
    @State private var hasConsentedToTerraform = false

    @State private var isRunning = false
    @State private var logTail: [String] = []
    @State private var exportResult: JamformerRunner.ExportResult?
    @State private var errorMessage: String?

    // Capture step
    @State private var blockID = ""
    @State private var blockName = ""
    @State private var blockSummary = ""
    @State private var selectedSourceID: UUID?
    @State private var captureOutcome: String?

    // Documentation step
    @State private var documentationText: String?
    @State private var isExportingDocumentation = false

    // Object picking (capture + clone)
    @State private var exportedObjects: [ExportedObject] = []
    @State private var selectedObjects: Set<String> = []

    // Clone step
    @State private var cloneTargetID: UUID?

    private let runner = JamformerRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exports read the tenant and never change it. Discovery runs on Terraform, which is downloaded from HashiCorp on first use — deploys always use the built-in engine.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Export type", selection: $kind) {
                    ForEach(ExportKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Natural width: constraining a segmented control below its
                // intrinsic size makes it overdraw its layout frame.
                .fixedSize()

                Picker("From", selection: $exportProvider) {
                    Text("Jamf Pro and Platform").tag("jamfplatform")
                    Text("Jamf Protect").tag("jamfprotect")
                        .disabled(tenant.protectURL == nil)
                }
                .fixedSize()
                .disabled(kind == .clone && exportProvider == "jamfprotect")
                .help(tenant.protectURL == nil
                    ? "Connect Jamf Protect in the Day 0 Setup tab to export from it"
                    : "Which product to read from")
            }
            .onChange(of: exportProvider) {
                Task {
                    resourceTypes = (try? await runner.listResourceTypes(provider: exportProvider)) ?? []
                    selectedTypes = []
                }
            }

            terraformRow

            GroupBox("Objects to export") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Filter types", text: $typeFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Button("All") { selectedTypes = Set(resourceTypes.map(\.filterKey)) }
                        Button("None") { selectedTypes = [] }
                        Spacer()
                        Text("\(selectedTypes.count) of \(resourceTypes.count) types")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                    if resourceTypes.isEmpty {
                        Text("Loading object types…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
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
                                    .help(type.terraformType)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                    Toggle("Include package files (downloads installers from the distribution point)", isOn: $includePackageFiles)
                        .font(.callout)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(isRunning ? "Exporting…" : "Export", systemImage: "square.and.arrow.up") {
                    runExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || selectedTypes.isEmpty || terraform.binaryURL == nil)
                if isRunning {
                    ProgressView().controlSize(.small)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                }
            }

            if !logTail.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(logTail.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            if let exportResult {
                resultSection(exportResult)
            }
        }
        .task {
            resourceTypes = (try? await runner.listResourceTypes(provider: exportProvider)) ?? []
            if case .installed = terraform.status { hasConsentedToTerraform = true }
        }
        .fileExporter(
            isPresented: $isExportingDocumentation,
            document: TextExportDocument(text: documentationText ?? ""),
            contentType: .plainText,
            defaultFilename: "AsBuilt-\(tenant.name)-\(Date.now.formatted(.iso8601.year().month().day())).md"
        ) { _ in }
    }

    private var filteredTypes: [JamformerRunner.ResourceType] {
        let base = resourceTypes.sorted { $0.filterKey < $1.filterKey }
        guard !typeFilter.isEmpty else { return base }
        return base.filter { $0.filterKey.localizedCaseInsensitiveContains(typeFilter) }
    }

    // MARK: Terraform consent

    @ViewBuilder
    private var terraformRow: some View {
        GroupBox {
            HStack(spacing: 8) {
                switch terraform.status {
                case .installed:
                    StatusIndicator.success.icon
                    Text("Discovery engine ready (Terraform \(TerraformManager.pinnedVersion), licensed under the BUSL — used only to read tenants, never shipped inside the app).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .downloading:
                    StatusIndicator.running.icon
                    Text("Downloading Terraform \(TerraformManager.pinnedVersion) from HashiCorp…")
                        .font(.callout)
                case .failed(let message):
                    StatusIndicator.failure.icon
                    Text(message).font(.callout)
                    Button("Try Again") { download() }
                case .notInstalled:
                    StatusIndicator.warning.icon
                    Text("Exports need Terraform \(TerraformManager.pinnedVersion) (HashiCorp, BUSL-licensed). It is downloaded once, checksum-verified, kept outside the app, and only ever reads tenants.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Download Terraform") { download() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(4)
        }
    }

    private func download() {
        Task { await terraform.downloadIfNeeded() }
    }

    // MARK: Run

    private func runExport() {
        let secrets = TenantSecrets(tenantID: tenant.id)
        let credential = exportProvider == "jamfprotect"
            ? secrets.protectClientSecret.load()
            : secrets.platformClientSecret.load()
        guard let secret = credential, let terraformURL = terraform.binaryURL else {
            errorMessage = exportProvider == "jamfprotect"
                ? "The Protect API client secret is missing — reconnect Protect in Day 0 Setup."
                : "The tenant's stored credentials are missing."
            return
        }
        isRunning = true
        errorMessage = nil
        exportResult = nil
        captureOutcome = nil
        logTail = ["Starting export…"]
        let types = Array(selectedTypes)
        Task {
            defer { isRunning = false }
            do {
                let result = try await runner.export(
                    tenant: tenant,
                    clientSecret: secret,
                    provider: exportProvider,
                    includeResources: types,
                    includePackageFiles: includePackageFiles,
                    skipImportBlocks: kind == .clone,
                    terraformPath: terraformURL.path
                )
                logTail = result.logLines
                guard result.exitCode == 0 else {
                    errorMessage = "The exporter stopped with an error — see the log above."
                    return
                }
                exportResult = result
                exportedObjects = (try? ExportedObjectInventory.scan(directory: result.outputURL)) ?? []
                selectedObjects = Set(exportedObjects.map(\.address))
                if blockName.isEmpty { blockName = "Captured from \(tenant.name)" }
                if blockID.isEmpty {
                    blockID = "captured-\(types.sorted().first ?? "objects")"
                }
                activityLog.append(ActivityLogEntry(
                    category: "Export", operation: "export", detail: tenant.name,
                    status: 200, duration: nil, note: "\(types.count) object types"
                ))
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Results per export kind

    @ViewBuilder
    private func resultSection(_ result: JamformerRunner.ExportResult) -> some View {
        GroupBox(kind.rawValue) {
            VStack(alignment: .leading, spacing: 10) {
                if !result.secretFindings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("The secret scan reported findings — review them before this export goes anywhere:", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        ForEach(result.secretFindings, id: \.self) { finding in
                            Text(finding).font(.caption.monospaced())
                        }
                    }
                }

                switch kind {
                case .block:
                    objectPicker
                    captureForm(result)
                case .clone:
                    objectPicker
                    cloneForm(result)
                case .snapshot:
                    Button("Save Snapshot…", systemImage: "doc.zipper") {
                        saveSnapshot(result)
                    }
                case .documentation:
                    Button("Save As-Built Documentation…", systemImage: "doc.text") {
                        documentationText = try? AsBuiltReport.markdown(AsBuiltReport.Input(
                            tenantName: tenant.name,
                            exportDirectory: result.outputURL,
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                        ))
                        isExportingDocumentation = documentationText != nil
                    }
                }

                if let captureOutcome {
                    Label(captureOutcome, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var objectPicker: some View {
        if !exportedObjects.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Objects (\(selectedObjects.count) of \(exportedObjects.count) selected)")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("All") { selectedObjects = Set(exportedObjects.map(\.address)) }
                    Button("None") { selectedObjects = [] }
                }
                .controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(exportedObjects) { object in
                            Toggle(isOn: Binding(
                                get: { selectedObjects.contains(object.address) },
                                set: { on in
                                    if on { selectedObjects.insert(object.address) } else { selectedObjects.remove(object.address) }
                                }
                            )) {
                                HStack {
                                    Text(object.displayName).font(.callout)
                                    Text(object.resourceType)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    @ViewBuilder
    private func cloneForm(_ result: JamformerRunner.ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let targets = tenantStore.tenants.filter { $0.id != tenant.id && !$0.isHandedOver }
            if targets.isEmpty {
                Text("Connect the destination tenant first — cloning previews and deploys there like any other change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Clone to", selection: $cloneTargetID) {
                    Text("Choose a tenant…").tag(Optional<UUID>.none)
                    ForEach(targets) { target in
                        Text(target.name).tag(Optional(target.id))
                    }
                }
                .frame(maxWidth: 320)
                Button("Stage Clone", systemImage: "arrow.triangle.branch") {
                    stageClone(result)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cloneTargetID == nil || selectedObjects.isEmpty)
                Text("Names and tenant-specific IDs are remapped for the destination; tokens, certificates and secrets are never cloned — set those up in the destination's Day 0 steps. Deploying still goes through the destination tenant's own preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stageClone(_ result: JamformerRunner.ExportResult) {
        guard let targetID = cloneTargetID,
              var target = tenantStore.tenant(id: targetID) else { return }
        do {
            try ExportedObjectInventory.prune(directory: result.outputURL, keeping: selectedObjects)
            // Clones live in an app-managed source, one block per clone.
            let cloneRoot = URL.applicationSupportDirectory.appending(path: "Jamf Deployer/cloned-blocks")
            let source: CatalogSourceStore.CustomSource
            if let existing = catalogSources.customSources.first(where: { $0.path == cloneRoot.path }) {
                source = existing
            } else {
                source = try catalogSources.addSource(name: "Cloned", folderURL: cloneRoot)
            }
            let blockID = "clone-\(tenant.name.lowercased().filter { $0.isLetter || $0.isNumber })-\(DeployHistoryEntry.makeID())"
            let captured = try BlockCapture.capture(BlockCapture.Request(
                blockID: blockID,
                name: "Clone of \(tenant.name) (\(Date.now.formatted(date: .abbreviated, time: .omitted)))",
                summary: "Objects cloned from \(tenant.name).",
                namePrefix: tenant.namePrefix,
                sourceDirectory: result.outputURL,
                catalogRootDirectory: URL(filePath: source.path),
                secretFindings: result.secretFindings
            ))
            var selection = BlockSelection(blockID: blockID, scope: "pilot")
            if captured.usesJamfProScope || captured.usesPlatformScope {
                selection.scope = "pilot"
            }
            target.blockSelections.append(selection)
            if !target.blockSelections.contains(where: { $0.blockID == "foundation" }) {
                target.blockSelections.insert(BlockSelection(blockID: "foundation"), at: 0)
            }
            tenantStore.update(target)
            captureOutcome = "Staged \(captured.objectCount) object\(captured.objectCount == 1 ? "" : "s") on “\(target.name)”. Open that tenant and Preview Changes to deploy the clone."
            activityLog.append(ActivityLogEntry(
                category: "Export", operation: "clone", detail: "\(tenant.name) → \(target.name)",
                status: 200, duration: nil, note: "\(captured.objectCount) objects"
            ))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private func captureForm(_ result: JamformerRunner.ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Block ID (lowercase-with-dashes)", text: $blockID)
                .font(.callout.monospaced())
                .frame(maxWidth: 320)
            TextField("Block name", text: $blockName)
                .frame(maxWidth: 320)
            TextField("Summary", text: $blockSummary, prompt: Text("What this block sets up"))
                .frame(maxWidth: 480)
            HStack {
                if catalogSources.customSources.isEmpty {
                    Button("Choose a Folder for Your Blocks…") { addSource() }
                        .help("Captured blocks are saved into a catalog folder you own")
                } else {
                    Picker("Save into", selection: $selectedSourceID) {
                        ForEach(catalogSources.customSources) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }
                    .frame(maxWidth: 300)
                    Button("Add Folder…") { addSource() }
                        .controlSize(.small)
                }
            }
            Button("Capture Building Block", systemImage: "shippingbox") {
                capture(result)
            }
            .buttonStyle(.borderedProminent)
            .disabled(blockID.isEmpty || blockName.isEmpty || effectiveSourceID == nil)
            Text("The captured block is marked “Review before use” until you mark it reviewed in the Building Blocks library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var effectiveSourceID: UUID? {
        selectedSourceID ?? catalogSources.customSources.first?.id
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose (or create) a folder to hold your captured building blocks."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = try catalogSources.addSource(name: url.lastPathComponent, folderURL: url)
            selectedSourceID = source.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func capture(_ result: JamformerRunner.ExportResult) {
        guard let sourceID = effectiveSourceID,
              let source = catalogSources.customSources.first(where: { $0.id == sourceID }) else { return }
        do {
            try ExportedObjectInventory.prune(directory: result.outputURL, keeping: selectedObjects)
            let captured = try BlockCapture.capture(BlockCapture.Request(
                blockID: blockID.trimmingCharacters(in: .whitespaces),
                name: blockName,
                summary: blockSummary.isEmpty ? "Captured from \(tenant.name)." : blockSummary,
                namePrefix: tenant.namePrefix,
                sourceDirectory: result.outputURL,
                catalogRootDirectory: URL(filePath: source.path),
                secretFindings: result.secretFindings
            ))
            var outcome = "Captured \(captured.objectCount) object\(captured.objectCount == 1 ? "" : "s") into “\(source.name)”."
            if !captured.warnings.isEmpty {
                outcome += " " + captured.warnings.joined(separator: " ")
            }
            captureOutcome = outcome
            activityLog.append(ActivityLogEntry(
                category: "Export", operation: "capture", detail: blockID,
                status: 200, duration: nil, note: source.name
            ))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveSnapshot(_ result: JamformerRunner.ExportResult) {
        // Manifest, then zip with ditto.
        let manifest: [String: Any] = [
            "tenant": tenant.name,
            "scopeID": tenant.scopeID,
            "date": Date.now.formatted(.iso8601),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "jamformerVersion": EngineInfo.jamformerVersion,
            "providerVersion": EngineInfo.jamfPlatformProviderVersion,
        ]
        try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: result.outputURL.appending(path: "manifest.json"))

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Snapshot-\(tenant.name)-\(Date.now.formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", result.outputURL.path, destination.path]
        try? ditto.run()
        ditto.waitUntilExit()
        captureOutcome = ditto.terminationStatus == 0
            ? "Snapshot saved to \(destination.lastPathComponent)."
            : "The snapshot could not be written."
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}
