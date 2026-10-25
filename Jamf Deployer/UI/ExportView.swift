import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeployerKit
import JTKit
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

    @Environment(ExportSessionStore.self) private var exportSessions

    // The run's state lives in the session store, so a running export keeps
    // reporting progress after navigating away from this tab and back.
    private var session: ExportSessionStore.Session { exportSessions.session(for: tenant.id) }
    private var isRunning: Bool {
        get { session.isRunning }
        nonmutating set { session.isRunning = newValue }
    }
    private var logTail: [String] {
        get { session.logTail }
        nonmutating set { session.logTail = newValue }
    }
    private var exportResult: JamformerRunner.ExportResult? {
        get { session.result }
        nonmutating set { session.result = newValue }
    }
    private var errorMessage: String? {
        get { session.errorMessage }
        nonmutating set { session.errorMessage = newValue }
    }

    // Capture step
    @State private var blockID = ""
    @State private var blockName = ""
    @State private var blockSummary = ""

    // Splitting one export into several blocks.
    enum CaptureMode: String, CaseIterable {
        case single = "One block"
        case split = "Separate blocks"
    }
    struct SplitGroup: Identifiable {
        let id = UUID()
        var blockID: String
        var name: String
    }
    @State private var captureMode: CaptureMode = .single
    @State private var prefixAllNames = false
    @State private var choosesScopePerTenant = false
    @State private var splitGroups: [SplitGroup] = []
    @State private var groupAssignment: [String: UUID] = [:]
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

    /// Building blocks and clones are written for the Platform API.
    private var availableKinds: [ExportKind] {
        tenant.isJamfPro ? [.snapshot, .documentation] : ExportKind.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exports read the tenant and never change it. Discovery runs on Terraform, which is downloaded from HashiCorp on first use — deploys always use the built-in engine.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Export type", selection: $kind) {
                    ForEach(availableKinds, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Natural width: constraining a segmented control below its
                // intrinsic size makes it overdraw its layout frame.
                .fixedSize()

                if !tenant.isJamfPro {
                    Picker("From", selection: $exportProvider) {
                        Text("Jamf Pro and Platform").tag("jamfplatform")
                        // Offered only with a Protect connection; a disabled
                        // option inside a menu picker stays clickable.
                        if tenant.protectURL != nil {
                            Text("Jamf Protect").tag("jamfprotect")
                        }
                    }
                    .fixedSize()
                    .disabled(kind == .clone)
                    .help(tenant.protectURL == nil
                        ? "Connect Jamf Protect in the Day 0 Setup tab to export from it"
                        : "Which product to read from")
                }
            }
            .onChange(of: kind) {
                // Clones come from Jamf Pro and Platform only.
                if kind == .clone { exportProvider = "jamfplatform" }
            }
            .onChange(of: exportProvider) {
                Task {
                    resourceTypes = (try? await runner.listResourceTypes(provider: exportProvider)) ?? []
                    selectedTypes = []
                }
            }
            if tenant.isJamfPro {
                Text("Capturing building blocks and cloning need a Jamf Platform API connection; this tenant is connected through the Jamf Pro API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        .frame(minHeight: 120, maxHeight: .infinity)
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
            if tenant.isJamfPro {
                exportProvider = tenant.connection.exporterProvider
                if !availableKinds.contains(kind) { kind = .snapshot }
            }
            resourceTypes = (try? await runner.listResourceTypes(provider: exportProvider)) ?? []
            // Returning to a finished export: restore the derived object list
            // with the types the run actually exported.
            if let result = session.result, exportedObjects.isEmpty {
                adoptResult(result, types: session.exportedTypes)
            }
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
        let session = session
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
                    terraformPath: terraformURL.path,
                    onLine: { line in
                        Task { @MainActor in session.appendLog(line) }
                    }
                )
                guard result.exitCode == 0 else {
                    if let known = ErrorTranslation.translateIfKnown(result.logLines.suffix(25).joined(separator: "\n")) {
                        errorMessage = known.message + (known.hint.map { " \($0)" } ?? "")
                    } else {
                        errorMessage = "The exporter stopped with an error — see the log below."
                    }
                    return
                }
                // Captured blocks carry their own copy of enrollment icons.
                await EnrollmentIcons.localize(directory: result.outputURL)
                exportResult = result
                session.exportedTypes = types
                adoptResult(result, types: types)
                activityLog.append(ActivityLogEntry(
                    category: "Export", operation: "export", detail: tenant.name,
                    status: 200, duration: nil, note: "\(types.count) object types"
                ))
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Derives the capture-form state from a finished export — called both
    /// when the run completes and when the view reappears mid-session.
    private func adoptResult(_ result: JamformerRunner.ExportResult, types: [String]) {
        exportedObjects = (try? ExportedObjectInventory.scan(directory: result.outputURL)) ?? []
        selectedObjects = Set(exportedObjects.map(\.address))
        if blockName.isEmpty { blockName = "Captured from \(tenant.name)" }
        if blockID.isEmpty {
            blockID = "captured-\(types.sorted().first ?? "objects")"
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
                        do {
                            documentationText = try AsBuiltReport.markdown(AsBuiltReport.Input(
                                tenantName: tenant.name,
                                exportDirectory: result.outputURL,
                                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                            ))
                            isExportingDocumentation = true
                        } catch {
                            errorMessage = "The documentation could not be generated: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                        }
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
            // Clones are written for the Platform API.
            let targets = tenantStore.tenants.filter { $0.id != tenant.id && !$0.isHandedOver && !$0.isJamfPro }
            if targets.isEmpty {
                Text("Connect the destination tenant through the Jamf Platform API first — cloning previews and deploys there like any other change.")
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
            let staging = try prunedCopy(of: result, keeping: selectedObjects)
            defer { try? FileManager.default.removeItem(at: staging) }
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
                sourceDirectory: staging,
                catalogRootDirectory: URL(filePath: source.path),
                secretFindings: result.secretFindings,
                originTenantScopeID: tenant.scopeID,
                resolutionDirectory: result.outputURL
            ))
            // Clones keep their own groups and categories; a capture that
            // collapsed scope onto a variable leaves the group to be chosen
            // on the destination tenant.
            var selection = BlockSelection(blockID: blockID, sourceID: source.id.uuidString)
            if captured.usesCategory { selection.existingCategory = .noCategory }
            target.blockSelections.append(selection)
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
            Picker("Capture as", selection: $captureMode) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: captureMode) {
                if captureMode == .split, splitGroups.isEmpty {
                    splitGroups = [SplitGroup(blockID: "captured-1", name: "")]
                }
            }

            if captureMode == .split {
                splitForm(result)
            } else {
                singleCaptureFields(result)
            }
        }
    }

    @ViewBuilder
    private func singleCaptureFields(_ result: JamformerRunner.ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Block ID (lowercase-with-dashes)", text: $blockID)
                .font(.callout.monospaced())
                .frame(maxWidth: 320)
            TextField("Block name", text: $blockName)
                .frame(maxWidth: 320)
            TextField("Summary", text: $blockSummary, prompt: Text("What this block sets up"))
                .frame(maxWidth: 480)
            captureOptionToggles
            sourcePickerRow
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

    /// Capture behavior shared by both modes.
    @ViewBuilder
    private var captureOptionToggles: some View {
        Toggle("Apply the tenant prefix to all object names", isOn: $prefixAllNames)
            .toggleStyle(.checkbox)
            .font(.callout)
            .help("Prefixes every captured name; otherwise only names that already carry this tenant's prefix are parameterized")
        Toggle("Choose scope and category per tenant (portable block)", isOn: $choosesScopePerTenant)
            .toggleStyle(.checkbox)
            .font(.callout)
            .help("Replace captured group and category references with choices made per tenant; when off, they stay wired between captured blocks")
    }

    /// Where captured blocks are saved — shared by both capture modes.
    @ViewBuilder
    private var sourcePickerRow: some View {
        HStack {
            // Folder sources only: git catalogs are read-only checkouts.
            let folders = catalogSources.customSources.filter { $0.kind == .localFolder }
            if folders.isEmpty {
                Button("Choose a Folder for Your Blocks…") { addSource() }
                    .help("Captured blocks are saved into a catalog folder you own")
            } else {
                Picker("Save into", selection: $selectedSourceID) {
                    ForEach(folders) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                }
                .frame(maxWidth: 300)
                Button("Add Folder…") { addSource() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Split capture

    @ViewBuilder
    private func splitForm(_ result: JamformerRunner.ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Define the blocks, then assign each selected object to one. Unassigned objects are left out.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($splitGroups) { $group in
                HStack(spacing: 6) {
                    TextField("block-id", text: $group.blockID)
                        .font(.callout.monospaced())
                        .frame(width: 180)
                    TextField("Block name", text: $group.name)
                        .frame(width: 220)
                    Text("\(assignedCount(group.id)) object\(assignedCount(group.id) == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        removeGroup(group.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove Block")
                    .help("Remove this block")
                    .disabled(splitGroups.count == 1)
                }
            }
            Button("Add Block", systemImage: "plus") {
                splitGroups.append(SplitGroup(blockID: "captured-\(splitGroups.count + 1)", name: ""))
            }
            .controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(exportedObjects.filter { selectedObjects.contains($0.address) }) { object in
                        HStack {
                            Text(object.displayName).font(.callout)
                            Text(object.resourceType)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Block for \(object.displayName)", selection: Binding(
                                get: { groupAssignment[object.address] },
                                set: { groupAssignment[object.address] = $0 }
                            )) {
                                Text("Leave out").tag(UUID?.none)
                                ForEach(splitGroups) { group in
                                    Text(group.name.isEmpty ? group.blockID : group.name)
                                        .tag(Optional(group.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)

            captureOptionToggles
            sourcePickerRow

            Button("Capture \(populatedGroupCount) Building Block\(populatedGroupCount == 1 ? "" : "s")", systemImage: "shippingbox") {
                captureSplit(result)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!splitIsValid)
            Text("Each captured block is marked “Review before use” until you mark it reviewed in the Building Blocks library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func assignedCount(_ groupID: UUID) -> Int {
        groupAssignment.values.filter { $0 == groupID }.count
    }

    private var populatedGroupCount: Int {
        splitGroups.filter { assignedCount($0.id) > 0 }.count
    }

    private var splitIsValid: Bool {
        populatedGroupCount > 0 && effectiveSourceID != nil
            && splitGroups.allSatisfy { assignedCount($0.id) == 0 || (!$0.blockID.isEmpty && !$0.name.isEmpty) }
    }

    private func removeGroup(_ id: UUID) {
        splitGroups.removeAll { $0.id == id }
        for (address, group) in groupAssignment where group == id {
            groupAssignment[address] = nil
        }
    }

    /// A pruned copy of the export, so the export itself stays complete for
    /// further captures, clones, snapshots and documentation.
    private func prunedCopy(of result: JamformerRunner.ExportResult, keeping objects: Set<String>) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: result.outputURL, to: staging)
        try ExportedObjectInventory.prune(directory: staging, keeping: objects)
        return staging
    }

    /// Captures each populated group as its own block from the one export:
    /// copy, prune to the group's objects, capture.
    private func captureSplit(_ result: JamformerRunner.ExportResult) {
        guard let sourceID = effectiveSourceID,
              let source = catalogSources.customSources.first(where: { $0.id == sourceID }) else { return }
        var captured: [String] = []
        do {
            for group in splitGroups where assignedCount(group.id) > 0 {
                let members = Set(groupAssignment.filter { $0.value == group.id }.keys)
                let staging = FileManager.default.temporaryDirectory
                    .appending(path: "capture-split-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: result.outputURL, to: staging)
                try ExportedObjectInventory.prune(directory: staging, keeping: members)
                let outcome = try BlockCapture.capture(BlockCapture.Request(
                    blockID: group.blockID.trimmingCharacters(in: .whitespaces),
                    name: group.name,
                    summary: "Captured from \(tenant.name).",
                    namePrefix: tenant.namePrefix,
                    sourceDirectory: staging,
                    catalogRootDirectory: URL(filePath: source.path),
                    secretFindings: result.secretFindings,
                    originTenantScopeID: tenant.scopeID,
                    rebind: choosesScopePerTenant ? .perTenant : .fidelity,
                    prefixAllNames: prefixAllNames,
                    resolutionDirectory: result.outputURL
                ))
                captured.append("\(group.name) (\(outcome.objectCount))")
            }
            captureOutcome = "Captured \(captured.count) block\(captured.count == 1 ? "" : "s") into “\(source.name)”: \(captured.joined(separator: ", ")). Find them in the Building Blocks library."
            activityLog.append(ActivityLogEntry(
                category: "Export", operation: "capture-split", detail: tenant.name,
                status: 200, duration: nil, note: "\(captured.count) blocks → \(source.name)"
            ))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var effectiveSourceID: UUID? {
        let folders = catalogSources.customSources.filter { $0.kind == .localFolder }
        // Never resolve to a git source, even if one was somehow selected.
        if let id = selectedSourceID, folders.contains(where: { $0.id == id }) { return id }
        return folders.first?.id
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
            let staging = try prunedCopy(of: result, keeping: selectedObjects)
            defer { try? FileManager.default.removeItem(at: staging) }
            let captured = try BlockCapture.capture(BlockCapture.Request(
                blockID: blockID.trimmingCharacters(in: .whitespaces),
                name: blockName,
                summary: blockSummary.isEmpty ? "Captured from \(tenant.name)." : blockSummary,
                namePrefix: tenant.namePrefix,
                sourceDirectory: staging,
                catalogRootDirectory: URL(filePath: source.path),
                secretFindings: result.secretFindings,
                originTenantScopeID: tenant.scopeID,
                rebind: choosesScopePerTenant ? .perTenant : .fidelity,
                prefixAllNames: prefixAllNames,
                resolutionDirectory: result.outputURL
            ))
            var outcome = "Captured \(captured.objectCount) object\(captured.objectCount == 1 ? "" : "s") into “\(source.name)” — find it in the Building Blocks library."
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
        // Write the manifest, then zip the export.
        let manifest: [String: Any] = [
            "tenant": tenant.name,
            "scopeID": tenant.connectionLabel,
            "date": Date.now.formatted(.iso8601),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "jamformerVersion": EngineInfo.jamformerVersion,
            "providerVersion": tenant.isJamfPro ? EngineInfo.jamfProProviderVersion : EngineInfo.jamfPlatformProviderVersion,
        ]
        try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: result.outputURL.appending(path: "manifest.json"))

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Snapshot-\(tenant.name)-\(Date.now.formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // zip adds to an existing archive, so a replaced file starts empty.
        try? FileManager.default.removeItem(at: destination)
        let source = result.outputURL
        Task {
            // Off the main actor: a full snapshot can be hundreds of megabytes.
            let status: Int32? = await Task.detached {
                let zip = Process()
                zip.standardInput = FileHandle.nullDevice
                zip.executableURL = URL(filePath: "/usr/bin/zip")
                zip.currentDirectoryURL = source
                // The provider download under .terraform is tens of megabytes
                // and is fetched again by `terraform init`.
                zip.arguments = ["-r", "-q", "-y", destination.path, ".", "-x", ".terraform/*"]
                guard (try? zip.run()) != nil else { return nil }
                zip.waitUntilExit()
                return zip.terminationStatus
            }.value
            guard status == 0 else {
                errorMessage = "The snapshot could not be written."
                return
            }
            captureOutcome = "Snapshot saved to \(destination.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
}
