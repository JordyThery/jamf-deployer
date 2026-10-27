import SwiftUI
import JTKit
import JamfDeployerCore

/// Per-tenant page: drift, connection, preflight, managed objects, the
/// baseline and hand-over, plus the Day 0 Setup and Export tabs.
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
    @State private var isUpdatingSecret = false
    @State private var isConfirmingForceUnlock = false
    @State private var unlockError: String?
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
                            subtitle: tenant.connectionLabel
                        )
                        StatusBadge(
                            tenant.isProduction ? "Production" : "Test",
                            style: tenant.isProduction ? .tinted : .neutral
                        )
                        Spacer()
                        Picker("Section", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }

                    if tab == .setup {
                        Day0SetupView(tenant: tenant)
                    } else if tab == .export {
                        if deployService.isDemo {
                            DemoModeUnavailableView(title: "Export and Capture")
                        } else {
                            ExportView(tenant: tenant)
                        }
                    } else {
                    if let lock = deployService.lock(for: tenant.id) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(
                                    "Being \(lock.activity) by \(lock.engineer)\(lock.host.isEmpty ? "" : " on \(lock.host)")\(lock.created.map { " since \($0.formatted(.relative(presentation: .named)))" } ?? "").",
                                    systemImage: "lock.fill"
                                )
                                .font(.callout)
                                Spacer()
                                Button("Force Unlock…", role: .destructive) {
                                    isConfirmingForceUnlock = true
                                }
                                .controlSize(.small)
                                .help("Only for a lock left behind by an interrupted run")
                                .confirmationDialog("Force unlock “\(tenant.name)”?", isPresented: $isConfirmingForceUnlock, titleVisibility: .visible) {
                                    Button("Force Unlock", role: .destructive) {
                                        unlockError = nil
                                        Task {
                                            do {
                                                try await deployService.forceUnlock(tenant: tenant, lock: lock)
                                            } catch {
                                                unlockError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                                            }
                                        }
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Only force-unlock when \(lock.engineer)'s run was interrupted. Unlocking a live run lets two engineers change this tenant at once.")
                                }
                            }
                            if let unlockError {
                                Label(unlockError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }

                    if tenant.isHandedOver {
                        GroupBox {
                            Label(
                                tenant.exportedTo.map { "This tenant moved to the Terraform repository \($0): change it there with pull requests. This app no longer tracks or changes it, and the record is archived." }
                                    ?? "This tenant was handed over: everything it managed stays in Jamf, but this app no longer tracks or changes it. The record is archived.",
                                systemImage: "archivebox"
                            )
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            if let url = tenant.exportedTo.flatMap(Self.repositoryPage) {
                                Link("Open Repository", destination: url)
                                    .padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    if let failure = deployService.fleetCheckFailure(for: tenant.id) {
                        Label("The last check for changes failed: \(failure)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    driftSection(tenant)

                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 6) {
                            TerraformTerm(tenant.isJamfPro
                                ? "the deploymenttheory/jamfpro provider, credentials from environment variables"
                                : "the jamf/jamfplatform provider, credentials from environment variables")
                            if tenant.isJamfPro {
                                LabeledContent("Connected through", value: "Jamf Pro API")
                                LabeledContent("Jamf Pro URL", value: tenant.jamfProURL ?? "")
                                LabeledContent(tenant.jamfProAuth == .userAccount ? "Username" : "Client ID") {
                                    Text(tenant.engineerClientID)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                }
                            } else {
                                LabeledContent("Region", value: tenant.region.displayName)
                                LabeledContent("Scope") {
                                    Text(tenant.apiScope == .environment ? "Platform environment" : "Tenant (legacy)")
                                }
                                LabeledContent("Client ID") {
                                    Text(tenant.engineerClientID)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                            LabeledContent("Name prefix") {
                                TextField("Name prefix", text: Binding(
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
                                .labelsHidden()
                                .help("Prefix for managed object names; changing it renames objects on the next deploy")
                            }
                            if let version = tenant.preflight?.jamfProVersion {
                                LabeledContent("Jamf Pro", value: PreflightService.displayVersion(version))
                            }
                            if let protectURL = tenant.protectURL {
                                LabeledContent("Jamf Protect", value: protectURL)
                            }
                            Button(tenant.jamfProAuth == .userAccount ? "Update Password…" : "Update Client Secret…") { isUpdatingSecret = true }
                                .controlSize(.small)
                                .help("Store new credentials for this tenant in the Keychain")
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
                            .help("Checks credentials, version, permissions and connections without changing anything in Jamf")
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
                                .disabled(tenant.handOverPending)
                            } else {
                                Text("Loading building blocks…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        TermLabel(title: "Add from the catalog", term: "one module block per building block in main.tf")
                    }

                    if let deploy = tenant.lastDeploy {
                        GroupBox("Last deploy") {
                            TerraformTerm("the last apply")
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    if tenant.handOverPending && !tenant.isHandedOver {
                        GroupBox("Hand over") {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Hand-over prepared: the next deploy stops managing everything in this tenant and archives its record. Every object stays in Jamf.", systemImage: "hand.raised")
                                    .font(.callout)
                                HStack {
                                    Button("Preview Hand-Over…") { isPreviewing = true }
                                        .buttonStyle(.borderedProminent)
                                    Button("Cancel Hand-Over") { deployService.cancelHandOver(tenant: tenant) }
                                        .help("Restores the baseline as it was; nothing has changed in Jamf")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    } else if deployService.isManaged(tenant) && !tenant.isHandedOver {
                        GroupBox("Hand over") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Stops managing everything: every object stays exactly as it is in Jamf, and this app archives its record. For when another team or tool takes over.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Hand Over Tenant…", role: .destructive) {
                                    isConfirmingHandOver = true
                                }
                                .unavailableInDemoMode(deployService.isDemo)
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
                    ? "Deploy first, then check for changes made in Jamf"
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
            .sheet(isPresented: $isUpdatingSecret) {
                UpdateClientSecretSheet(tenant: tenant)
            }
            .onChange(of: appState.previewRequestCount) {
                if !tenant.isHandedOver, hasAnythingToPreview(tenant) {
                    isPreviewing = true
                }
            }
            .alert("Hand over “\(tenant.name)”?", isPresented: $isConfirmingHandOver) {
                TextField("Type the tenant name to confirm", text: $handOverTypedName)
                Button("Cancel", role: .cancel) { handOverTypedName = "" }
                Button("Prepare Hand-Over", role: .destructive) {
                    handOverTypedName = ""
                    deployService.prepareHandOver(tenant: tenant)
                    isPreviewing = true
                }
                .disabled(handOverTypedName != tenant.name)
            } message: {
                Text(handOverMessage(tenant))
            }
            .task {
                catalog = try? deployService.loadCatalog()
            }
            // Kept-change notes belong to one check of one tenant.
            .onChange(of: "\(tenant.id)|\(tenant.lastDriftCheck?.timeIntervalSince1970 ?? 0)") {
                keepOutcomes = [:]
            }
            .task(id: "\(tenant.id)|\(tenant.lastDeploy?.date.timeIntervalSince1970 ?? 0)|\(isAdopting)|\(isPreviewing)|\(isAddingCustomObject)") {
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
                    .help("Create an object the catalog doesn't cover, using a form built from the engine plugin's schema")
                }
                .unavailableInDemoMode(deployService.isDemo)
                .disabled(tenant.handOverPending)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            TermLabel(title: "Managed in this tenant", term: "resources in the state; adopted objects arrive through import blocks")
        }
    }

    /// The web page of the repository a tenant moved to: its GitHub page for
    /// any GitHub remote form, otherwise the remote itself when it is a web URL.
    private static func repositoryPage(_ remote: String) -> URL? {
        if let github = GitHubRepository(remote: remote) {
            return github.webURL
        }
        guard let url = URL(string: remote), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func handOverMessage(_ tenant: Tenant) -> String {
        let blockCount = tenant.deployedBlockVersions.count
        let adoptedCount = adoptedSummary.reduce(0) { $0 + $1.count }
        var parts: [String] = []
        if blockCount > 0 { parts.append("\(blockCount) building block\(blockCount == 1 ? "" : "s")") }
        if adoptedCount > 0 { parts.append("\(adoptedCount) adopted object\(adoptedCount == 1 ? "" : "s")") }
        let subject = parts.isEmpty ? "everything" : parts.joined(separator: " and ")
        return "Every object stays in Jamf exactly as it is. The app stops managing \(subject) and archives the record. You review the change before anything happens, and can cancel until you deploy."
    }

    private func managedSummaryText(_ tenant: Tenant, adoptedCount: Int, blockCount: Int) -> String {
        var parts: [String] = []
        if adoptedCount > 0 { parts.append("\(adoptedCount) adopted object\(adoptedCount == 1 ? "" : "s")") }
        if blockCount > 0 { parts.append("\(blockCount) building block\(blockCount == 1 ? "" : "s")") }
        let subject = parts.joined(separator: " and ")
        if tenant.lastDeploy == nil {
            return "\(subject) staged. Preview Changes brings \(adoptedCount + blockCount == 1 ? "it" : "them") under management; nothing is recreated."
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
        if tenant.driftReport != nil, !outstanding.isEmpty || !informational.isEmpty || !keepOutcomes.isEmpty {
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
                                            let note = switch outcome {
                                            case .adoptedIntoSetting:
                                                "kept — the baseline setting now uses this value."
                                            case .acknowledged:
                                                "noted — a future deploy would still restore the baseline value."
                                            }
                                            keepOutcomes["\(object.address)|\(field.path)"] = "\(object.displayName) · \(field.path): \(note)"
                                        }
                                        .help("Accept the value in Jamf; the baseline adopts it where a block setting controls the field")
                                    }
                                    .controlSize(.small)
                                    .padding(.top, 2)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    // A kept field leaves the list at once, so its outcome is shown here.
                    ForEach(keepOutcomes.keys.sorted(), id: \.self) { key in
                        Label(keepOutcomes[key] ?? "", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                HStack(alignment: .firstTextBaseline) {
                    TermLabel(title: "Changes made in Jamf", term: "a refresh-only plan against what is in Jamf")
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
            await deployService.checkDriftRecordingFailure(tenant: tenant)
        }
    }

    private func runPreflight(tenant: Tenant) {
        guard TenantSecrets(tenantID: tenant.id).platformClientSecret.load() != nil else {
            checks = [PreflightCheck(
                id: "secret", title: "Stored credentials",
                outcome: .fail,
                detail: tenant.isJamfPro && tenant.jamfProAuth == .userAccount
                    ? "The password is missing from the Keychain. Enter it with Update Password… in the Connection section."
                    : "The client secret is missing from the Keychain. Enter it with Update Client Secret… in the Connection section."
            )]
            return
        }
        isRunningPreflight = true
        checks = []
        let client = TenantClients.shared.client(for: tenant, activityLog: activityLog)
        Task {
            let report = await PreflightService.run(client: client, connection: tenant.connection) { progress in
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

/// Replaces the tenant's client secret in the Keychain, for a rotated
/// secret or a Mac that does not have it yet. In Team Mode each engineer
/// signs in with their own API client or account, so the client ID or
/// username can be changed for this Mac too. Outside Team Mode, a missing
/// record passphrase can be entered from the recovery sheet. The workspace
/// and its encrypted record are untouched.
struct UpdateClientSecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TenantDeployService.self) private var deployService
    let tenant: Tenant
    @State private var clientID = ""
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var message: String?

    private var secrets: TenantSecrets { TenantSecrets(tenantID: tenant.id) }
    private var needsPassphrase: Bool { !deployService.isTeamMode && secrets.statePassphrase.load() == nil }
    private var usesPassword: Bool { tenant.isJamfPro && tenant.jamfProAuth == .userAccount }

    var body: some View {
        SheetFrame(title: usesPassword ? "Update Password" : "Update Client Secret", systemImage: "key") {
            Form {
                if deployService.isTeamMode {
                    TextField(usesPassword ? "Username" : "Client ID", text: $clientID)
                    Text(usesPassword
                        ? "Sign in with your own Jamf Pro account; it is kept in this Mac's Keychain."
                        : "Use your own API client for this tenant; it is kept in this Mac's Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent(usesPassword ? "Username" : "Client ID", value: tenant.clientID)
                }
                SecureField(usesPassword ? "Password" : "Client secret", text: $secret)
                if needsPassphrase {
                    SecureField("Recovery passphrase", text: $passphrase)
                    Text("This Mac has no passphrase for the tenant's deployment state. Enter the one from its recovery sheet, or leave it empty for a tenant that was never deployed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(secret.isEmpty && passphrase.isEmpty
                    && (clientID == tenant.engineerClientID || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
        .frame(width: 480, height: needsPassphrase || deployService.isTeamMode ? 340 : 260)
        .onAppear { clientID = tenant.engineerClientID }
    }

    private func save() {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var savedID = true
        if deployService.isTeamMode, !trimmedID.isEmpty {
            // The record's own ID needs no copy on this Mac.
            if trimmedID == tenant.clientID {
                secrets.engineerClientID.delete()
            } else {
                savedID = secrets.engineerClientID.save(trimmedID)
            }
        }
        // Passwords are kept exactly as typed; secrets are trimmed (pasted).
        let value = usesPassword ? secret : secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedSecret = value.isEmpty || secrets.platformClientSecret.save(value)
        let savedPassphrase = trimmed.isEmpty || secrets.statePassphrase.save(trimmed)
        if savedID && savedSecret && savedPassphrase {
            dismiss()
        } else {
            message = "The Keychain did not accept the change."
        }
    }
}
