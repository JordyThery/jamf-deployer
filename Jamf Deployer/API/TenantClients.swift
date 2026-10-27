import Foundation
import JamfDeployerCore
import JTKit
import os

/// One API client per saved tenant, so every screen and service shares one
/// sign-in and one token instead of signing in each time.
///
/// A client is dropped, and its token forgotten, when:
/// - the tenant's connection changes: its name, address, region, scope,
///   sign-in type, or the client ID or username this Mac signs in with
///   (noticed at the next request, so an edit in Settings, a team sync and
///   the wizard are all covered);
/// - one of the tenant's secrets is saved or deleted, also a secret alone;
/// - the tenant is removed.
///
/// Deploy bookkeeping (last deploy, deployed versions, token expiry dates)
/// changes none of these, so it keeps the client (decided by Jordy).
///
/// The wizard and Test Connection check credentials that aren't saved yet,
/// so they make a one-off `JamfPlatformClient` instead.
nonisolated final class TenantClients: Sendable {
    static let shared = TenantClients()

    /// What a client was made from; a different one means a new client.
    struct Fingerprint: Hashable, Sendable {
        var name: String
        var connection: ConnectionKind
        var jamfProURL: String?
        var jamfProAuth: Tenant.JamfProAuth?
        var region: Tenant.Region
        var apiScope: Tenant.APIScope
        var environmentID: String?
        var tenantID: String?
        var signInID: String

        init(_ tenant: Tenant, signInID: String) {
            name = tenant.name
            connection = tenant.connection
            jamfProURL = tenant.jamfProURL
            jamfProAuth = tenant.jamfProAuth
            region = tenant.region
            apiScope = tenant.apiScope
            environmentID = tenant.environmentID
            tenantID = tenant.tenantID
            self.signInID = signInID
        }
    }

    private struct Entry {
        let fingerprint: Fingerprint
        let client: JamfPlatformClient
    }

    private let entries = OSAllocatedUnfairLock<[UUID: Entry]>(initialState: [:])
    private let session: URLSession
    private let signInID: @Sendable (Tenant) -> String
    private let configure: @Sendable (Tenant, String) -> JamfAPIConfiguration

    /// - Parameters:
    ///   - session, signInID, configure: injectable for tests.
    init(
        session: URLSession = .shared,
        signInID: @escaping @Sendable (Tenant) -> String = { $0.engineerClientID },
        configure: @escaping @Sendable (Tenant, String) -> JamfAPIConfiguration = {
            JamfAPIConfiguration(tenant: $0, signInID: $1)
        }
    ) {
        self.session = session
        self.signInID = signInID
        self.configure = configure
    }

    /// The tenant's client: the one already made, unless its connection
    /// changed since.
    func client(for tenant: Tenant, activityLog: ActivityLog?) -> JamfPlatformClient {
        let id = signInID(tenant)
        let fingerprint = Fingerprint(tenant, signInID: id)
        let (client, replaced) = entries.withLock { entries -> (JamfPlatformClient, JamfPlatformClient?) in
            if let entry = entries[tenant.id], entry.fingerprint == fingerprint {
                return (entry.client, nil)
            }
            // a demo tenant only ever reaches JTKit's demo servers
            let client = DemoTenants.isDemo(tenant)
                ? DemoTenants.client(for: tenant, activityLog: activityLog)
                : JamfPlatformClient(configuration: configure(tenant, id), activityLog: activityLog, session: session)
            let old = entries.updateValue(Entry(fingerprint: fingerprint, client: client), forKey: tenant.id)
            return (client, old?.client)
        }
        if let replaced { Task { await replaced.forgetToken() } }
        return client
    }

    /// Drops the tenant's client and forgets its token: removed, or its
    /// sign-in changed.
    func drop(_ tenantID: UUID) {
        let old = entries.withLock { $0.removeValue(forKey: tenantID) }
        if let old { Task { await old.client.forgetToken() } }
    }

    /// A Keychain item was saved or deleted. Tenant items use the tenant's
    /// UUID as account; block settings (`<UUID>.<block>.<key>`) and the team
    /// passphrase don't sign in, so they keep the client.
    func secretChanged(account: String) {
        guard let id = UUID(uuidString: account) else { return }
        drop(id)
    }
}
