import SwiftUI
import DeployerKit

/// The connect-a-tenant flow: identity → integration instructions →
/// credentials → optional Jamf Protect → preflight → save.
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
    @State private var region: Tenant.Region = .eu
    @State private var isTestTenant = true

    // Step 3
    @State private var clientID = ""
    @State private var clientSecret = ""
    /// Pasted secrets often carry a trailing space or line break.
    private var trimmedSecret: String { clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }
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
            ForEach(Step.allCases, id: \.rawValue) { candidate in
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
                Picker("Region", selection: $region) {
                    ForEach(Tenant.Region.allCases, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                .help("The regional gateway the tenant lives on. It's shown in Jamf Account next to the API integration.")
                Toggle("This is a test tenant", isOn: $isTestTenant)
                    .help("Test tenants get a grey tag and relaxed guardrails. Production tenants require extra confirmation for risky changes.")
            } footer: {
                Text("The name is only used inside this app.")
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

    private var integrationStep: some View {
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

    private var credentialsStep: some View {
        Form {
            Section("Platform API integration") {
                TextField("Client ID", text: $clientID, prompt: Text("d5e385c3-738f-4169-ad07-…"))
                    .font(.body.monospaced())
                SecureField("Client secret", text: $clientSecret)
                Toggle("Integration uses legacy tenant scope", isOn: $usesLegacyTenantScope)
                    .help("Most integrations target a Platform environment. Only turn this on for an older integration created against a single tenant.")
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
                    clientID: clientID,
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

    private func runPreflight() {
        isRunningPreflight = true
        checks = []
        report = nil
        let client = JamfPlatformClient(
            configuration: JamfAPIConfiguration(
                gatewayURL: region.gatewayURL,
                clientID: clientID,
                clientSecret: trimmedSecret,
                environmentID: usesLegacyTenantScope ? nil : scopeID
            ),
            activityLog: activityLog
        )
        Task {
            let result = await PreflightService.run(client: client) { progress in
                checks = progress
            }
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
                : "Review the items above — you can still add the tenant.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        if step != .identity {
            Button("Back") {
                step = Step(rawValue: step.rawValue - 1) ?? .identity
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
                .disabled(clientID.isEmpty || clientSecret.isEmpty || scopeID.isEmpty)
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
        if step == .protect {
            step = .preflight
            runPreflight()
        } else {
            step = Step(rawValue: step.rawValue + 1) ?? .preflight
        }
    }

    private func save() {
        var tenant = Tenant(
            name: name.trimmingCharacters(in: .whitespaces),
            region: region,
            clientID: clientID.trimmingCharacters(in: .whitespaces),
            environmentID: usesLegacyTenantScope ? nil : scopeID.trimmingCharacters(in: .whitespaces),
            tenantID: usesLegacyTenantScope ? scopeID.trimmingCharacters(in: .whitespaces) : nil,
            isProduction: !isTestTenant
        )
        tenant.preflight = report?.snapshot
        if !protectURL.isEmpty {
            tenant.protectURL = protectURL
            tenant.protectClientID = protectClientID
        }

        let secrets = TenantSecrets(tenantID: tenant.id)
        secrets.platformClientSecret.save(trimmedSecret)
        if !protectClientSecret.isEmpty {
            secrets.protectClientSecret.save(protectClientSecret)
        }

        tenantStore.add(tenant)
        dismiss()
    }
}
