import Foundation
import JTKit
import JamfDeployerCore

/// The app under JTKit's live-check switch (a release check's live UI test).
///
/// JTKit sends the app's own requests to the release check's gateway, which
/// decides each one. OpenTofu and jamformer talk to Jamf themselves, so the
/// gateway never sees them; these rules stand in for it:
/// - an engine or jamformer run reaches only a tenant of this run;
/// - an apply, destroy or import goes only to the disposable test tenants;
/// - a deploy touches only objects named with the run's prefix;
/// - the state backend (Team Mode) and Jamf Protect never run.
///
/// The UI test may ask the app to start with the run's tenants already
/// connected (`-JDLiveSeedTenants YES`) and passes the run's prefix
/// (`-JDLivePrefix <prefix>`).
nonisolated enum LiveRun {
    /// The roles an engine may write to: the release check's disposable tenants.
    static let writableRoles: Set<String> = ["jamf-test-a", "jamf-test-b"]

    static let seedTenantsKey = "JDLiveSeedTenants"
    static let prefixKey = "JDLivePrefix"

    struct Refused: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "The release check’s live run refused this: \(reason)." }
    }

    /// Every object a live run makes starts with this.
    static var prefix: String {
        let given = UserDefaults.standard.string(forKey: prefixKey) ?? ""
        return given.hasPrefix("JTKTEST") ? given : "JTKTEST"
    }

    private static var entries: [LiveLaunch.LaunchFile.Entry]? {
        guard case .active(let active) = LiveLaunch.state else { return nil }
        return active.connections
    }

    // MARK: Engine and jamformer runs

    /// Called by the app's doorway for every launch while the switch is on.
    static func check(_ tool: ExternalTool, arguments: [String], environment: [String: String]?) throws {
        guard let entries else { throw Refused(reason: "the live-check switch couldn’t be used") }
        try check(tool, arguments: arguments, environment: environment, entries: entries)
    }

    /// The same, for the run's connections `entries`.
    static func check(_ tool: ExternalTool, arguments: [String], environment: [String: String]?,
                      entries: [LiveLaunch.LaunchFile.Entry]) throws {
        switch tool {
        case .stateBackend:
            throw Refused(reason: "Team Mode isn’t part of live runs")
        case .git:
            // The store and catalog caches are local; nothing is pushed.
            if arguments.contains("push") { throw Refused(reason: "nothing is pushed in a live run") }
        case .openTofu, .jamformer:
            guard let environment, let target = target(environment) else { return }
            guard let entry = entries.first(where: { matches($0, target) }) else {
                throw Refused(reason: "\(tool.rawValue) would reach a tenant that isn’t part of this run")
            }
            if tool == .openTofu, let command = arguments.first, ["apply", "destroy", "import"].contains(command),
               !writableRoles.contains(entry.role) {
                throw Refused(reason: "\(entry.role) is read only")
            }
        }
    }

    /// The tenant a launch's environment points at; nil when it reaches none.
    enum Target: Equatable {
        case platform(environmentID: String)
        case jamfPro(host: String)
        case other
    }

    static func target(_ environment: [String: String]) -> Target? {
        if let id = environment["JAMFPLATFORM_ENVIRONMENT_ID"] ?? environment["JAMF_ENVIRONMENT_ID"] {
            return .platform(environmentID: id.lowercased())
        }
        if let url = environment["JAMFPRO_INSTANCE_FQDN"] ?? environment["JAMF_URL"] {
            guard let host = URL(string: url)?.host()?.lowercased() ?? Optional(url.lowercased()), !host.isEmpty else { return .other }
            return .jamfPro(host: host)
        }
        // Any other Jamf address (Jamf Protect, a tenant-scoped Platform run)
        // isn't part of live runs.
        let reachesJamf = environment.keys.contains { $0.hasPrefix("JAMFPLATFORM_") || $0.hasPrefix("JAMFPROTECT_") || $0.hasPrefix("JAMF_") }
        return reachesJamf ? .other : nil
    }

    static func matches(_ entry: LiveLaunch.LaunchFile.Entry, _ target: Target) -> Bool {
        let connection = entry.connection
        switch target {
        case .platform(let id):
            return connection.service == .jamfPlatform && connection.environmentID.lowercased() == id
        case .jamfPro(let host):
            return connection.service == .jamfPro
                && (URL(string: connection.serverURL)?.host()?.lowercased() ?? connection.serverURL.lowercased()) == host
        case .other:
            return false
        }
    }

    // MARK: Deploys

    /// Before an apply: every object the approved plan touches carries the
    /// run's prefix.
    static func requireOnlyTestObjects(_ names: [String]) throws {
        let prefix = prefix
        if let other = names.first(where: { !$0.hasPrefix(prefix) }) {
            throw Refused(reason: "the plan touches “\(other)”, which isn’t named with \(prefix)")
        }
    }

    // MARK: The run's tenants

    /// With `-JDLiveSeedTenants YES`: the run's Jamf Platform API and Jamf
    /// Pro connections as tenants, their secrets in memory only.
    @MainActor
    static func seedTenants(into store: TenantStore) {
        guard let entries, UserDefaults.standard.bool(forKey: seedTenantsKey) else { return }
        for entry in entries {
            guard let tenant = tenant(for: entry),
                  let secret = LiveLaunch.secrets.secret(for: entry.connection.id.uuidString), !secret.isEmpty
            else { continue }
            // secrets live in memory per launch: one seeded earlier in the run gets its secret again
            if store.tenant(id: tenant.id) == nil { store.add(tenant) }
            TenantSecrets(tenantID: tenant.id).platformClientSecret.save(secret)
        }
    }

    static func tenant(for entry: LiveLaunch.LaunchFile.Entry) -> Tenant? {
        let connection = entry.connection
        switch connection.service {
        case .jamfPlatform:
            var tenant = Tenant(id: connection.id, name: connection.name, region: connection.region,
                                clientID: connection.clientID, environmentID: connection.environmentID.lowercased(),
                                isProduction: !writableRoles.contains(entry.role))
            tenant.namePrefix = prefix + " – "
            return tenant
        case .jamfPro:
            let usesPassword = connection.signIn == .usernamePassword
            var tenant = Tenant(id: connection.id, name: connection.name, region: connection.region,
                                clientID: usesPassword ? connection.username : connection.clientID,
                                environmentID: nil, isProduction: !writableRoles.contains(entry.role),
                                connection: .jamfPro, jamfProURL: connection.serverURL,
                                jamfProAuth: usesPassword ? .userAccount : .apiClient)
            tenant.namePrefix = prefix + " – "
            return tenant
        default:
            return nil
        }
    }
}
