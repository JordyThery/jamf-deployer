import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Per-tenant overview: connection details and preflight, with the deploy
/// surface arriving in later phases.
struct TenantDetailView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(ActivityLog.self) private var activityLog
    @Environment(TenantDeployService.self) private var deployService
    @Environment(AppState.self) private var appState

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case setup = "Day 0 Setup"
        case export = "Export"
    }

    let tenantID: UUID
    @State private var tab: Tab = .overview
    @State private var checks: [PreflightCheck] = []
    @State private var isRunningPreflight = false
    @State private var isPreviewing = false
    @State private var isAdopting = false
    @State private var isAddingCustomObject = false
    @State private var isCheckingDrift = false
    @State private var isConfirmingHandOver = false
    @State private var handOverTypedName = ""
    @State private var keepOutcomes: [String: String] = [:]
    @State private var catalog: LoadedCatalog?
    @State private var adoptedSummary: [(label: String, count: Int)] = []

    private var tenant: Tenant? {
        tenantStore.tenant(id: tenantID)
    }

    var body: some View {
        if let tenant {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        DetailHeader(
                            systemImage: "building.2",
                            title: tenant.name,
                            subtitle: tenant.scopeID
                        )
                        StatusBadge(
                            tenant.isProduction ? "Production" : "Test",
                            style: tenant.isProduction ? .tinted : .neutral
                        )
                        Spacer()
                        Picker("", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    if tab == .setup {
                        Day0SetupView(tenant: tenant)
                    } else if tab == .export {
                        ExportView(tenant: tenant)
                    } else {
                    if let lock = deployService.lock(for: tenant.id) {
                        GroupBox {
                            HStack {
                                Label(
                                    "Being \(lock.operation == "check" ? "checked" : "deployed") by \(lock.engineer) on \(lock.host) since \(lock.acquiredAt.formatted(.relative(presentation: .named))).",
                                    systemImage: "lock.fill"
                                )
                                .font(.callout)
                                Spacer()
                                Button("Break Lock…", role: .destructive) {
                                    Task { await deployService.breakLock(tenant: tenant) }
                                }
                                .controlSize(.small)
                                .help("Only for stale locks after a crash — breaking a live lock risks two engineers deploying at once")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }

                    if tenant.isHandedOver {
                        GroupBox {
                            Label(
                                "This tenant was handed over: everything it managed stays in Jamf, but this app no longer tracks or changes it. The record is archived.",
                                systemImage: "archivebox"
                            )
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }

                    driftSection(tenant)

                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Region", value: tenant.region.displayName)
                            LabeledContent("Scope") {
                                Text(tenant.apiScope == .environment ? "Platform environment" : "Tenant (legacy)")
                            }
                            LabeledContent("Client ID") {
                                Text(tenant.clientID)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                            LabeledContent("Name prefix") {
                                TextField("", text: Binding(
                                    get: { tenant.namePrefix },
                                    set: { newValue in
                                        var updated = tenantStore.tenant(id: tenant.id) ?? tenant
                                        updated.namePrefix = newValue
                                        tenantStore.update(updated)
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 160)
                                .multilineTextAlignment(.trailing)
                                .help("Applied to every prefixed object name. Changing it renames managed objects on the next deploy — the preview shows every rename first.")
                            }
                            if let version = tenant.preflight?.jamfProVersion {
                                LabeledContent("Jamf Pro", value: PreflightService.displayVersion(version))
                            }
                            if let protectURL = tenant.protectURL {
                                LabeledContent("Jamf Protect", value: protectURL)
                            }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if checks.isEmpty {
                                if let snapshot = tenant.preflight {
                                    HStack(spacing: 8) {
                                        (snapshot.allGreen ? StatusIndicator.success : .warning).icon
                                        Text("Last preflight \(snapshot.date.formatted(.relative(presentation: .named)))\(snapshot.allGreen ? " — all checks passed." : " — some checks need review.")")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("No preflight has been run yet.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(checks) { check in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        indicator(for: check.outcome).icon
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(check.title)
                                                .font(.body.weight(.medium))
                                            Text(check.detail)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                            Button(isRunningPreflight ? "Checking…" : "Run Preflight", systemImage: "stethoscope") {
                                runPreflight(tenant: tenant)
                            }
                            .disabled(isRunningPreflight)
                            .help("Checks credentials, version, permissions and connections. Nothing is changed in Jamf.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        HStack {
                            Text("Preflight")
                            if isRunningPreflight {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                    if !tenant.isHandedOver {
                        managedSection(tenant)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Building blocks add new objects and settings to this tenant. Objects that already exist don't need a block — adopt them instead.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let catalog {
                                BaselineEditorView(tenant: tenant, catalog: catalog) {
                                    self.catalog = try? deployService.loadCatalog()
                                }
                            } else {
                                Text("Loading building blocks…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        Text("Add from the catalog")
                    }

                    if let deploy = tenant.lastDeploy {
                        GroupBox("Last deploy") {
                            HStack(spacing: 8) {
                                (deploy.failed == 0 ? StatusIndicator.success : .warning).icon
                                Text("\(deploy.date.formatted(.relative(presentation: .named))) by \(deploy.engineerName) — \(deploy.succeeded) succeeded, \(deploy.failed) failed")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }
                    if deployService.isManaged(tenant) && !tenant.isHandedOver {
                        GroupBox("Hand over") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Stops managing everything: every object stays exactly as it is in Jamf, and this app archives its record. For when another team or tool takes over.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Hand Over Tenant…", role: .destructive) {
                                    isConfirmingHandOver = true
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }
                    } // end overview tab
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tourAnchor(TourAnchor.detail)
            .navigationTitle(tenant.name)
            .toolbar {
                Button {
                    checkDrift(tenant)
                } label: {
                    Label("Check for Changes", systemImage: "arrow.clockwise")
                }
                .disabled(!deployService.isManaged(tenant) || isCheckingDrift || deployService.isBusy || tenant.isHandedOver)
                .help(!deployService.isManaged(tenant)
                    ? "Deploy a baseline first, then check for changes made in Jamf"
                    : "Compare the tenant against its record and list changes made in Jamf")

                Button {
                    isPreviewing = true
                } label: {
                    Label("Preview Changes", systemImage: "list.bullet.clipboard")
                }
                .disabled(!hasAnythingToPreview(tenant) || deployService.isBusy || tenant.isHandedOver)
                .help(!hasAnythingToPreview(tenant)
                    ? "Select building blocks or adopt existing configuration first"
                    : "See exactly what would change before anything is deployed")
            }
            .sheet(isPresented: $isPreviewing) {
                PreviewDeploySheet(tenantID: tenant.id)
            }
            .sheet(isPresented: $isAdopting) {
                AdoptView(tenant: tenant, openPreviewAfterAdopt: $isPreviewing)
            }
            .sheet(isPresented: $isAddingCustomObject) {
                OverrideEditorView(tenant: tenant)
            }
            .onChange(of: appState.previewRequestCount) {
                if !tenant.isHandedOver, !(tenant.blockSelections.isEmpty && tenant.pendingRemovals.isEmpty) {
                    isPreviewing = true
                }
            }
            .alert("Hand over “\(tenant.name)”?", isPresented: $isConfirmingHandOver) {
                TextField("Type the tenant name to confirm", text: $handOverTypedName)
                Button("Cancel", role: .cancel) { handOverTypedName = "" }
                Button("Prepare Hand-Over", role: .destructive) {
                    guard handOverTypedName == tenant.name else { return }
                    handOverTypedName = ""
                    deployService.prepareHandOver(tenant: tenant)
                    isPreviewing = true
                }
            } message: {
                Text("Every object stays in Jamf exactly as it is. The app stops managing everything in this tenant — \(tenant.deployedBlockVersions.count) blocks\(deployService.hasAdoptedConfig(for: tenant) ? " and all adopted objects" : "") — and archives the record. You review the change before anything happens.")
            }
            .task {
                catalog = try? deployService.loadCatalog()
            }
            .task(id: "\(tenant.lastDeploy?.date.timeIntervalSince1970 ?? 0)|\(isAdopting)|\(isPreviewing)") {
                adoptedSummary = deployService.adoptedSummary(for: tenant)
            }
        } else {
            ContentUnavailableView(
                "No Tenant Selected",
                systemImage: "building.2",
                description: Text("Choose a tenant in the sidebar.")
            )
        }
    }

    /// What the app manages in this tenant, and how to bring more in.
    @ViewBuilder
    private func managedSection(_ tenant: Tenant) -> some View {
        let adoptedCount = adoptedSummary.reduce(0) { $0 + $1.count }
        let blockCount = tenant.deployedBlockVersions.count
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if adoptedCount == 0 && blockCount == 0 {
                    Text("Nothing in this tenant is managed yet. Already configured by hand? Adopt the existing objects — nothing is recreated. For what isn't there yet, add building blocks below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(managedSummaryText(tenant, adoptedCount: adoptedCount, blockCount: blockCount))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if !adoptedSummary.isEmpty {
                        let shown = adoptedSummary.prefix(8)
                        let more = adoptedSummary.count - shown.count
                        Text(shown.map { "\($0.label) (\($0.count))" }.joined(separator: " · ")
                            + (more > 0 ? " · and \(more) more type\(more == 1 ? "" : "s")" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button(adoptedCount == 0 ? "Adopt Existing Configuration…" : "Adopt More…", systemImage: "square.and.arrow.down.on.square") {
                        isAdopting = true
                    }
                    .help("Bring objects that already exist in Jamf under management, without recreating them")
                    Button("Add a Custom Object…", systemImage: "plus.rectangle.on.rectangle") {
                        isAddingCustomObject = true
                    }
                    .help("Create an object the catalog doesn't cover yet — the form comes from the live provider schema, no configuration language needed")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Managed in this tenant")
        }
    }

    private func managedSummaryText(_ tenant: Tenant, adoptedCount: Int, blockCount: Int) -> String {
        var parts: [String] = []
        if adoptedCount > 0 { parts.append("\(adoptedCount) adopted object\(adoptedCount == 1 ? "" : "s")") }
        if blockCount > 0 { parts.append("\(blockCount) building block\(blockCount == 1 ? "" : "s")") }
        let subject = parts.joined(separator: " and ")
        if tenant.lastDeploy == nil {
            return "\(subject) staged — Preview Changes to bring them under management. Nothing is recreated."
        }
        return "\(subject) managed by this app. Check for Changes compares them with Jamf, and you can keep or undo any change made there. Adopted objects need no building block."
    }

    private func indicator(for outcome: PreflightCheck.Outcome) -> StatusIndicator {
        switch outcome {
        case .pass: .success
        case .warn: .warning
        case .fail: .failure
        case .running: .running
        case .pending: .neutral
        }
    }

    @ViewBuilder
    private func driftSection(_ tenant: Tenant) -> some View {
        let outstanding = tenant.outstandingDrift
        let informational = (tenant.driftReport?.objects ?? []).filter(\.isComputedOnly)
        if tenant.driftReport != nil, !outstanding.isEmpty || !informational.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(outstanding) { object in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                StatusBadge("Changed in Jamf", style: .warning)
                                Text(object.displayName)
                                    .font(.body.weight(.medium))
                                Text(object.blockName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            ForEach(object.fields) { field in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(field.path)
                                        .font(.caption.bold().monospaced())
                                    Text("− \(field.before)  (baseline)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.red)
                                    Text("+ \(field.after)  (now in Jamf)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.green)
                                    HStack(spacing: 8) {
                                        Button("Keep This Change") {
                                            let outcome = deployService.keepDrift(tenant: tenant, object: object, field: field)
                                            keepOutcomes["\(object.address)|\(field.path)"] = switch outcome {
                                            case .adoptedIntoSetting:
                                                "Kept — the baseline setting now uses this value."
                                            case .acknowledged:
                                                "Noted — a future deploy would still restore the baseline value."
                                            }
                                        }
                                        .help("Accept the value as it is in Jamf. Where a block setting controls this field, the baseline adopts the value; otherwise the change is noted and a deploy would still restore it.")
                                        if let outcome = keepOutcomes["\(object.address)|\(field.path)"] {
                                            Text(outcome)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .controlSize(.small)
                                    .padding(.top, 2)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    if !outstanding.isEmpty {
                        HStack {
                            Button("Restore Baseline…") {
                                isPreviewing = true
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Preview and deploy — the deploy puts every changed object back to the baseline")
                            Spacer()
                        }
                    }
                    if !informational.isEmpty {
                        Label(
                            "\(informational.count) object\(informational.count == 1 ? " was" : "s were") updated by Jamf itself (bookkeeping values) — nothing to do.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                HStack {
                    Text("Changes made in Jamf")
                    if let checked = tenant.lastDriftCheck {
                        Text("· checked \(checked.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                    if isCheckingDrift {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } else if let checked = tenant.lastDriftCheck, tenant.driftReport?.objects.isEmpty != false {
            GroupBox {
                HStack(spacing: 8) {
                    StatusIndicator.success.icon
                    Text("In sync with the baseline — last checked \(checked.formatted(.relative(presentation: .named))).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if isCheckingDrift {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func hasAnythingToPreview(_ tenant: Tenant) -> Bool {
        !tenant.blockSelections.isEmpty
            || !tenant.pendingRemovals.isEmpty
            || deployService.hasAdoptedConfig(for: tenant)
    }

    private func checkDrift(_ tenant: Tenant) {
        isCheckingDrift = true
        Task {
            defer { isCheckingDrift = false }
            try? await deployService.checkDrift(tenant: tenant)
        }
    }

    private func runPreflight(tenant: Tenant) {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            checks = [PreflightCheck(
                id: "secret", title: "Stored credentials",
                outcome: .fail,
                detail: "The client secret is missing from the Keychain. Remove and reconnect the tenant."
            )]
            return
        }
        isRunningPreflight = true
        checks = []
        let client = JamfPlatformClient(
            configuration: JamfAPIConfiguration(tenant: tenant, clientSecret: secret),
            activityLog: activityLog
        )
        Task {
            let report = await PreflightService.run(client: client) { progress in
                checks = progress
            }
            checks = report.checks
            // Re-fetch: the tenant may have changed while the checks ran.
            var updated = tenantStore.tenant(id: tenant.id) ?? tenant
            updated.preflight = report.snapshot
            tenantStore.update(updated)
            isRunningPreflight = false
        }
    }
}
