import SwiftUI
import JTKit

/// Settings › Connections: the tenants, for editing, testing and removing.
/// + opens the Connect a Tenant wizard; the sidebar stays for deployments.
/// There is no connection picker or Connection menu: the app manages a
/// fleet, not one connection in use.
struct TenantConnectionsTab: View {
    let store: ConnectionStore<TenantConnection>
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(ActivityLog.self) private var activityLog
    @State private var isConnectingTenant = false

    var body: some View {
        ConnectionsSettingsTab(
            store: store,
            services: [.jamfPlatform, .jamfPro],
            optionalFields: [.jamfProtect],
            allowsChangingService: false,
            footer: unreadableNote,
            readOnlyFields: { $0.readOnlyFields },
            protectServices: [.jamfPlatform],
            newRecord: { _ in
                // not used: + opens the wizard
                TenantConnection(tenant: Tenant(name: "", region: .us, clientID: "", environmentID: nil, isProduction: false))
            },
            add: { isConnectingTenant = true },
            delete: { record in try await remove(record) },
            // managed tenants are refused here (`remove`), so this is the unmanaged text
            deleteMessage: TenantRemoval.message(isTeamMode: deployService.isTeamMode, isManaged: false),
            test: { record, typed in try await test(record, typed: typed) }
        ) { $record in
            scopeSection(record)
        }
        .sheet(isPresented: $isConnectingTenant) {
            ConnectTenantWizard()
        }
        .onAppear { store.reload() }
        // the wizard, a team sync, a removal or a deploy changed the tenants
        .onChange(of: tenantStore.tenants) { store.reload() }
        .onChange(of: deployService.isTeamMode) { store.reload() }
    }

    @ViewBuilder
    private func scopeSection(_ record: TenantConnection) -> some View {
        let tenant = record.tenant
        Section {
            LabeledContent("Connected through", value: tenant.isJamfPro ? "Jamf Pro API" : "Jamf Platform API")
            if !tenant.isJamfPro {
                LabeledContent("Scope", value: tenant.apiScope == .environment ? "Platform environment" : "Tenant (legacy)")
                if tenant.apiScope == .tenant {
                    LabeledContent("Tenant ID") {
                        Text(tenant.tenantID ?? "")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } footer: {
            Text(record.usesOwnSignIn
                ? "The connection is fixed when the tenant is connected. In Team Mode you sign in with your own API client or account, kept in this Mac’s Keychain: change it with Update Client Secret… in the tenant’s Connection section."
                : "The connection is fixed when the tenant is connected; the name, client ID and secrets can be changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Names tenant records that couldn't be read. They are left as they are.
    private var unreadableNote: String? {
        let folders = tenantStore.unreadableFiles.map { $0.deletingLastPathComponent().lastPathComponent }
        guard !folders.isEmpty else { return nil }
        let list = folders.joined(separator: ", ")
        return folders.count == 1
            ? "One tenant record couldn’t be read and isn’t listed (tenants/\(list)/tenant.json). It is left as it is."
            : "\(folders.count) tenant records couldn’t be read and aren’t listed (in tenants/: \(list)). They are left as they are."
    }

    // MARK: Actions

    /// The same removal as the sidebar's Remove Tenant…, for tenants with
    /// nothing managed: JTKit's delete confirmation can't ask for the
    /// tenant's name, so a managed tenant is removed from the sidebar. The
    /// minus button can't be disabled from here, so running engine work is
    /// refused with a message below the list.
    private func remove(_ record: TenantConnection) async throws {
        guard let tenant = tenantStore.tenant(id: record.id) else { return }
        if let refusal = TenantRemoval.refusal(isEngineBusy: deployService.isEngineWorkRunning) {
            throw RefusedRemoval(text: refusal)
        }
        guard !TenantRemoval.needsTypedName(isManaged: deployService.isManaged(tenant)) else {
            throw RefusedRemoval(text: TenantRemoval.managedFromSettingsText)
        }
        do {
            try await deployService.removeTenant(tenant)
        } catch {
            throw RefusedRemoval(text: SidebarView.removalErrorText(error))
        }
    }

    /// Signs in with the values on screen (this Mac's own client ID in Team
    /// Mode) and reads the Jamf Pro version, as the preflight does.
    private func test(_ record: TenantConnection, typed: [ConnectionSecretKind: String]) async throws -> String {
        let tenant = record.tenant
        let connection = record.connection
        let usesPassword = connection.signIn == .usernamePassword
        guard let secret = try typed[.main] ?? store.readSecret(.main, for: connection), !secret.isEmpty else {
            throw TestError.noSecret(usesPassword: usesPassword)
        }
        let signInName = (usesPassword ? connection.username : connection.clientID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // passwords are kept exactly as typed; secrets are trimmed (pasted)
        let password = usesPassword ? secret : secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = JamfPlatformClient(
            configuration: try Self.testConfiguration(for: tenant, signInName: signInName, password: password),
            activityLog: activityLog)
        let version = try await client.jamfProVersion()
        return "Connected · Jamf Pro \(PreflightService.displayVersion(version))"
    }

    /// Test Connection's sign-in: always the tenant's real address and the
    /// real network, demo mode or not (Settings › Connections lists only
    /// real tenants).
    nonisolated static func testConfiguration(for tenant: Tenant, signInName: String,
                                              password: String) throws -> JamfAPIConfiguration {
        if tenant.isJamfPro {
            guard let url = JamfAPIConfiguration.instanceURL(tenant.jamfProURL ?? "") else { throw TestError.invalidURL }
            return JamfAPIConfiguration(jamfProURL: url, auth: tenant.jamfProAuth ?? .apiClient,
                                        clientID: signInName, clientSecret: password)
        }
        return JamfAPIConfiguration(gatewayURL: tenant.region.gatewayURL, clientID: signInName,
                                    clientSecret: password, environmentID: tenant.environmentID,
                                    tenantID: tenant.tenantID)
    }

    private nonisolated struct RefusedRemoval: LocalizedError {
        let text: String
        var errorDescription: String? { "The tenant wasn’t removed. \(text)" }
    }

    private nonisolated enum TestError: LocalizedError {
        case noSecret(usesPassword: Bool)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .noSecret(let usesPassword):
                usesPassword
                    ? "The password is missing from the Keychain. Type it in the Password field."
                    : "The client secret is missing from the Keychain. Type it in the Client secret field."
            case .invalidURL:
                "The saved Jamf Pro URL isn’t valid."
            }
        }
    }
}
