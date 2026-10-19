import SwiftUI
import DeployerKit
import JamfDeployerCore

/// The connect-a-tenant flow: identity and connection type → integration
/// instructions → credentials → optional Jamf Protect (Platform only) →
/// preflight → save.
struct ConnectTenantWizard: View {
    enum Step: Int, CaseIterable {
        case identity
        case integration
        case credentials
        case protect
        case preflight

        var title: String {
            switch self {
            case .identity: "Tenant"
            case .integration: "API integration"
            case .credentials: "Credentials"
            case .protect: "Jamf Protect"
            case .preflight: "Preflight"
            }
        }
    }

    @Environment(TenantStore.self) private var tenantStore
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .identity

    // Step 1
    @State private var name = ""
    @State private var connection: ConnectionKind = .platform
    @State private var region: Tenant.Region = .eu
    @State private var isTestTenant = true

    // Jamf Pro API connections
    @State private var jamfProURL = ""
    @State private var jamfProAuth: Tenant.JamfProAuth = .apiClient
    private var normalizedJamfProURL: URL? { JamfAPIConfiguration.instanceURL(jamfProURL) }
    private var isJamfPro: Bool { connection == .jamfPro }

    // Step 3
    @State private var clientID = ""
    @State private var clientSecret = ""
    /// Pasted credentials often carry a stray space or line break.
    private var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSecret: String { clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedScopeID: String { scopeID.trimmingCharacters(in: .whitespacesAndNewlines) }
    @State private var usesLegacyTenantScope = false
    @State private var scopeID = ""
    @State private var fetchedEnvironments: [OrganizationService.Environment] = []
    @State private var environmentFetchMessage: String?
    @State private var isFetchingEnvironments = false

    // Step 4
    @State private var protectURL = ""
    @State private var protectClientID = ""
    @State private var protectClientSecret = ""

    // Step 5
    @State private var checks: [PreflightCheck] = []
    @State private var report: PreflightReport?
    @State private var isRunningPreflight = false
    /// The latest preflight; results of an earlier one (before Back) are dropped.
    @State private var preflightRun = UUID()
    @State private var saveError: String?

    var body: some View {
        SheetFrame(
            title: name.isEmpty ? "Connect a Tenant" : "Connect a Tenant — \(name)",
            systemImage: "building.2.crop.circle.badge.plus",
            isBusy: isRunningPreflight || isFetchingEnvironments
        ) {
            VStack(spacing: 0) {
                stepPicker
                Divider()
                ScrollView {
                    stepContent
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            footer
        }
        .frame(width: 640, height: 560)
    }

    private var stepPicker: some View {
        HStack(spacing: 16) {
            ForEach(visibleSteps, id: \.rawValue) { candidate in
                HStack(spacing: 5) {
                    Image(systemName: candidate.rawValue < step.rawValue
                        ? "checkmark.circle.fill"
                        : (candidate == step ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(candidate.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(candidate.title)
                        .font(.caption)
                        .foregroundStyle(candidate == step ? .primary : .secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    /// Jamf Pro API connections skip the Protect step.
    private var visibleSteps: [Step] {
        isJamfPro ? Step.allCases.filter { $0 != .protect } : Step.allCases
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .identity: identityStep
        case .integration: integrationStep
        case .credentials: credentialsStep
        case .protect: protectStep
        case .preflight: preflightStep
        }
    }

    // MARK: Step 1 — identity

    private var identityStep: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Contoso Production"))
                Picker("Connect through", selection: $connection) {
                    Text("Jamf Platform API").tag(ConnectionKind.platform)
                    Text("Jamf Pro API").tag(ConnectionKind.jamfPro)
                }
                .help("Which Jamf API the app uses for this tenant; it cannot be changed later")
                if !isJamfPro {
                    Picker("Region", selection: $region) {
                        ForEach(Tenant.Region.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .help("The regional gateway shown next to the API integration in Jamf Account")
                }
                Toggle("This is a test tenant", isOn: $isTestTenant)
                    .help("Production tenants ask for extra confirmation before risky changes")
            } footer: {
                Text(isJamfPro
                    ? "The name is only used inside this app. Most building blocks deploy through the Jamf Pro API too; Blueprints, compliance benchmarks, Security Cloud and App Store apps need the Jamf Platform API."
                    : "The name is only used inside this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Step 2 — integration instructions

    private static let requiredPermissions = [
        "categories:read",
        "scripts:read",
        "device-enrollment-program-instances:read",
        "volume-purchasing-locations:read",
        "applications:read",
    ]

    private static let jamfProPrivileges = [
        "Read Categories",
        "Read Scripts",
        "Read Device Enrollment Program Instances",
        "Read Volume Purchasing Locations",
    ]

    @ViewBuilder
    private var integrationStep: some View {
        if isJamfPro { jamfProIntegrationStep } else { platformIntegrationStep }
    }

    private var jamfProIntegrationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prepare Jamf Pro API access")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                instruction(1, "In Jamf Pro, open **Settings → System → API roles and clients**.")
                instruction(2, "Create an API role with the privileges below, plus create, read, update and delete for the object types you want to manage.")
                instruction(3, "Create an API client with that role, enable it and generate a client secret. A Jamf Pro user account with the same privileges works too.")
            }
            GroupBox("Privileges for connecting") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.jamfProPrivileges, id: \.self) { privilege in
                        Text(privilege)
                            .font(.callout.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Text("Changes run one at a time over the Jamf Pro API, so large deploys take longer than over the Jamf Platform API.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var platformIntegrationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create an API integration in Jamf Account")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                instruction(1, "Sign in to Jamf Account and open **API integrations**.")
                instruction(2, "Create a new integration scoped to the **Platform environment** that holds this tenant.")
                instruction(3, "Grant it the permissions below. When you pick building blocks later, the app shows any extra permissions each block needs.")
                instruction(4, "Copy the client ID and client secret — the secret is shown only once.")
            }
            GroupBox("Permissions for connecting") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.requiredPermissions, id: \.self) { permission in
                        Text(permission)
                            .font(.callout.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Button("Copy Permissions List", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.requiredPermissions.joined(separator: "\n"), forType: .string)
            }
            .help("Copies the permission names so you can tick them off in Jamf Account")
            Link(
                "Open Jamf Account",
                destination: URL(string: "https://account.jamf.com")!
            )
            .font(.callout)
        }
    }

    private func instruction(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.bold())
                .foregroundStyle(.tint)
            Text(.init(markdown))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 3 — credentials

    @ViewBuilder
    private var credentialsStep: some View {
        if isJamfPro { jamfProCredentialsStep } else { platformCredentialsStep }
    }

    private var jamfProCredentialsStep: some View {
        Form {
            Section {
                TextField("Jamf Pro URL", text: $jamfProURL, prompt: Text("https://yourorg.jamfcloud.com"))
                    .font(.body.monospaced())
                Picker("Sign in with", selection: $jamfProAuth) {
                    Text("API client").tag(Tenant.JamfProAuth.apiClient)
                    Text("User account").tag(Tenant.JamfProAuth.userAccount)
                }
                if jamfProAuth == .apiClient {
                    TextField("Client ID", text: $clientID, prompt: Text("d5e385c3-738f-4169-ad07-…"))
                        .font(.body.monospaced())
                    SecureField("Client secret", text: $clientSecret)
                } else {
                    TextField("Username", text: $clientID, prompt: Text("Jamf Pro username"))
                    SecureField("Password", text: $clientSecret)
                }
            } header: {
                Text("Jamf Pro API")
            } footer: {
                Text(jamfProURL.isEmpty || normalizedJamfProURL != nil
                    ? "Credentials are stored in your Keychain only. API clients are recommended over user accounts."
                    : "Enter the instance address, for example https://yourorg.jamfcloud.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var platformCredentialsStep: some View {
        Form {
            Section("Platform API integration") {
                TextField("Client ID", text: $clientID, prompt: Text("d5e385c3-738f-4169-ad07-…"))
                    .font(.body.monospaced())
                SecureField("Client secret", text: $clientSecret)
                Toggle("Integration uses legacy tenant scope", isOn: $usesLegacyTenantScope)
                    .help("Only for an older integration created against a single tenant")
                TextField(
                    usesLegacyTenantScope ? "Tenant ID" : "Environment ID",
                    text: $scopeID,
                    prompt: Text("e77c1408-10c8-4007-b177-…")
                )
                .font(.body.monospaced())
            }
            if !usesLegacyTenantScope {
                Section {
                    if !fetchedEnvironments.isEmpty {
                        Picker("Pick an environment", selection: $scopeID) {
                            Text("Choose…").tag("")
                            ForEach(fetchedEnvironments) { environment in
                                Text(environment.name).tag(environment.id)
                            }
                        }
                    }
                    Button("Fetch Environments from Jamf Account", systemImage: "arrow.down.circle") {
                        fetchEnvironments()
                    }
                    .disabled(clientID.isEmpty || clientSecret.isEmpty || isFetchingEnvironments)
                } footer: {
                    if let environmentFetchMessage {
                        Text(environmentFetchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Works with organization-scope integrations; otherwise paste the ID from Jamf Account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func fetchEnvironments() {
        isFetchingEnvironments = true
        environmentFetchMessage = nil
        Task {
            defer { isFetchingEnvironments = false }
            do {
                fetchedEnvironments = try await OrganizationService.environments(
                    gatewayURL: region.gatewayURL,
                    clientID: trimmedClientID,
                    clientSecret: trimmedSecret,
                    activityLog: activityLog
                )
                if fetchedEnvironments.isEmpty {
                    environmentFetchMessage = "No environments visible to this integration."
                }
            } catch {
                fetchedEnvironments = []
                environmentFetchMessage = error.localizedDescription
            }
        }
    }

    // MARK: Step 4 — Protect (optional)

    private var protectStep: some View {
        Form {
            Section {
                TextField("Protect console URL", text: $protectURL, prompt: Text("https://yourorg.protect.jamfcloud.com"))
                TextField("API client ID", text: $protectClientID)
                    .font(.body.monospaced())
                SecureField("API client secret", text: $protectClientSecret)
            } header: {
                Text("Jamf Protect (optional)")
            } footer: {
                Text("Create the API client in the Protect console under Administration → API Clients. You can also add this later in the tenant's Day 0 Setup tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Step 5 — preflight

    private var preflightStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if checks.isEmpty && !isRunningPreflight {
                ContentUnavailableView(
                    "Ready to Check",
                    systemImage: "checklist",
                    description: Text("The app signs in to Jamf and verifies version, permissions and connections. Nothing is changed.")
                )
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Passwords are kept exactly as typed; secrets are trimmed (pasted).
    private var storedSecret: String {
        isJamfPro && jamfProAuth == .userAccount ? clientSecret : trimmedSecret
    }

    private func runPreflight() {
        isRunningPreflight = true
        checks = []
        report = nil
        let configuration: JamfAPIConfiguration
        if isJamfPro, let url = normalizedJamfProURL {
            configuration = JamfAPIConfiguration(
                jamfProURL: url, auth: jamfProAuth, clientID: trimmedClientID, clientSecret: storedSecret
            )
        } else {
            configuration = JamfAPIConfiguration(
                gatewayURL: region.gatewayURL,
                clientID: trimmedClientID,
                clientSecret: trimmedSecret,
                environmentID: usesLegacyTenantScope ? nil : trimmedScopeID
            )
        }
        let client = JamfPlatformClient(configuration: configuration, activityLog: activityLog)
        let connection = connection
        let run = UUID()
        preflightRun = run
        Task {
            let result = await PreflightService.run(client: client, connection: connection) { progress in
                if preflightRun == run { checks = progress }
            }
            guard preflightRun == run else { return }
            checks = result.checks
            report = result
            isRunningPreflight = false
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if step == .preflight, let report {
            Text(report.snapshot.allGreen
                ? "All checks passed."
                : credentialsFailed
                    ? "Fix the credentials, then run the checks again."
                    : "Review the items above — you can still add the tenant.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let saveError {
            Text(saveError)
                .font(.callout)
                .foregroundStyle(.red)
        }
        Spacer()
        Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        if step != .identity {
            Button("Back") {
                step = previousStep
            }
        }
        switch step {
        case .identity, .integration:
            Button("Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .identity && name.trimmingCharacters(in: .whitespaces).isEmpty)
        case .credentials:
            Button("Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(clientID.isEmpty || clientSecret.isEmpty || (isJamfPro ? normalizedJamfProURL == nil : scopeID.isEmpty))
        case .protect:
            Button("Run Preflight") { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .preflight:
            if isRunningPreflight {
                Button("Add Tenant") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            } else if report == nil {
                Button("Run Preflight") { runPreflight() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Run Again") { runPreflight() }
                Button("Add Tenant") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(credentialsFailed)
                    .help(credentialsFailed
                        ? "Fix the credentials before adding the tenant"
                        : "Save this tenant and its preflight results")
            }
        }
    }

    private var credentialsFailed: Bool {
        checks.contains { $0.id == "auth" && $0.outcome == .fail }
    }

    private func advance() {
        if step == .protect || (step == .credentials && isJamfPro) {
            step = .preflight
            runPreflight()
        } else {
            step = Step(rawValue: step.rawValue + 1) ?? .preflight
        }
    }

    private var previousStep: Step {
        if step == .preflight && isJamfPro { return .credentials }
        return Step(rawValue: step.rawValue - 1) ?? .identity
    }

    private func save() {
        var tenant = Tenant(
            name: name.trimmingCharacters(in: .whitespaces),
            region: region,
            clientID: trimmedClientID,
            environmentID: isJamfPro || usesLegacyTenantScope ? nil : trimmedScopeID,
            tenantID: !isJamfPro && usesLegacyTenantScope ? trimmedScopeID : nil,
            isProduction: !isTestTenant,
            connection: connection,
            jamfProURL: isJamfPro ? normalizedJamfProURL?.absoluteString : nil,
            jamfProAuth: isJamfPro ? jamfProAuth : nil
        )
        tenant.preflight = report?.snapshot
        let protectURL = protectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isJamfPro && !protectURL.isEmpty {
            tenant.protectURL = protectURL
            tenant.protectClientID = protectClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let secrets = TenantSecrets(tenantID: tenant.id)
        let protectSecret = isJamfPro ? "" : protectClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secrets.platformClientSecret.save(storedSecret),
              protectSecret.isEmpty || secrets.protectClientSecret.save(protectSecret) else {
            secrets.deleteAll()
            saveError = "The Keychain did not accept the credentials, so the tenant was not added."
            return
        }

        tenantStore.add(tenant)
        dismiss()
    }
}
