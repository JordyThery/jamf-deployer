import Foundation
import JTKit

/// Connection details for one tenant's Platform API integration. The secret
/// is read only when the client signs in: for a saved tenant straight from
/// the Keychain, so a changed secret is used at once; for a connection that
/// isn't saved yet (the wizard, Test Connection), as typed.
nonisolated struct JamfAPIConfiguration: Sendable {
    /// How requests authenticate and which path dialect they use.
    enum Flavor: Sendable {
        /// The Platform API gateway (OAuth client credentials).
        case platform
        /// A Jamf Pro instance with an API client (OAuth client credentials).
        case jamfProAPIClient
        /// A Jamf Pro instance with a user account (basic auth for a token).
        case jamfProUser
    }

    /// The gateway, or the Jamf Pro instance URL for Jamf Pro connections.
    var gatewayURL: URL
    var flavor: Flavor = .platform
    /// Client ID, or the username for `.jamfProUser`.
    var clientID: String
    /// Client secret, or the password for `.jamfProUser`.
    var secret: @Sendable () throws -> String
    /// Exactly one scope header per request: X-Environment-Id (preferred,
    /// must be a UUID) or X-Tenant-Id (legacy); none for the organization's
    /// own calls and a Jamf Pro instance.
    var scope: JamfPlatform.Client.Scope = .organization
    /// A Jamf Pro tenant whose saved URL is not a valid instance URL; no
    /// credentials are sent anywhere.
    var hasInvalidInstanceURL = false
    /// Shown as the connection in the activity log.
    var connectionName: String?

    /// A saved tenant, signing in with this Mac's client ID (or username)
    /// and the secret in the Keychain.
    init(tenant: Tenant, signInID: String) {
        clientID = signInID
        connectionName = tenant.name
        let item = TenantSecrets(tenantID: tenant.id).platformClientSecret
        let usesPassword = tenant.isJamfPro && tenant.jamfProAuth == .userAccount
        secret = {
            guard let value = item.load() else {
                throw JamfAPIError.notAuthenticated(usesPassword ? "no password saved" : "no client secret saved",
                                                    flavor: usesPassword ? .jamfProUser : tenant.isJamfPro ? .jamfProAPIClient : .platform)
            }
            return value
        }
        if tenant.isJamfPro {
            let instance = Self.instanceURL(tenant.jamfProURL ?? "")
            gatewayURL = instance ?? tenant.region.gatewayURL
            hasInvalidInstanceURL = instance == nil
            flavor = usesPassword ? .jamfProUser : .jamfProAPIClient
            return
        }
        gatewayURL = tenant.region.gatewayURL
        switch tenant.apiScope {
        case .environment:
            scope = .environment(tenant.environmentID ?? "")
        case .tenant:
            scope = tenant.tenantID.map { .legacyTenant($0) } ?? .organization
        }
    }

    init(gatewayURL: URL, clientID: String, clientSecret: String, environmentID: String?, tenantID: String? = nil) {
        self.gatewayURL = gatewayURL
        self.clientID = clientID
        secret = { clientSecret }
        if let environmentID {
            scope = .environment(environmentID)
        } else if let tenantID {
            scope = .legacyTenant(tenantID)
        }
    }

    /// A Jamf Pro connection made before the tenant exists (the wizard).
    init(jamfProURL: URL, auth: Tenant.JamfProAuth, clientID: String, clientSecret: String) {
        gatewayURL = jamfProURL
        flavor = auth == .userAccount ? .jamfProUser : .jamfProAPIClient
        self.clientID = clientID
        secret = { clientSecret }
    }

    /// Normalizes what a user types ("example.jamfcloud.com",
    /// "https://example.jamfcloud.com/") to "https://host[:port]".
    static func instanceURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("https://") && !text.lowercased().hasPrefix("http://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        normalized.port = components.port
        return normalized.url
    }
}

/// The app's own errors, before anything is sent. Jamf's answers come as
/// JTKit's `JamfPlatform.APIError`.
nonisolated enum JamfAPIError: LocalizedError {
    /// No secret saved; worded for the connection, as JTKit's sign-in hints
    /// are: a direct Jamf Pro tenant has no region and no Jamf Account, and
    /// a user account no client secret.
    case notAuthenticated(String, flavor: JamfAPIConfiguration.Flavor)
    /// A Jamf Pro tenant whose saved URL is not a valid instance URL.
    case invalidInstanceURL

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let detail, .platform):
            "Jamf did not accept the credentials. Check the client ID, client secret and region. (\(detail))"
        case .notAuthenticated(let detail, .jamfProAPIClient):
            "Jamf Pro did not accept the credentials. Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients. (\(detail))"
        case .notAuthenticated(let detail, .jamfProUser):
            "Jamf Pro did not accept the credentials. Check the username and password. (\(detail))"
        case .invalidInstanceURL:
            "The saved Jamf Pro URL is not valid. Check the tenant's Jamf Pro URL."
        }
    }
}

/// Direct Jamf API client, for the Platform API gateway or a Jamf Pro
/// instance: everything outside the engine (preflight, Day 0, token expiry,
/// pickers). A thin layer over JTKit's Platform client: one shared sign-in,
/// the token renewed a minute before it expires, JTKit's retry rules, every
/// request in the activity log with secrets hidden (request bodies never,
/// answers only for errors), and errors in JTKit's format. Never follows a
/// redirect to another host or to plain HTTP, the sign-in included.
///
/// Saved tenants share one client each (`TenantClients`).
actor JamfPlatformClient {
    private let configuration: JamfAPIConfiguration
    private let tokens: JamfPlatform.TokenProvider
    /// JTKit's client; throws an error status as a `JamfPlatform.APIError`.
    private let platform: Result<JamfPlatform.Client, JamfPlatform.APIError>
    /// Where the requests go, which decides where a missing permission is fixed.
    nonisolated let server: JamfPlatform.Server

    init(
        configuration: JamfAPIConfiguration,
        activityLog: ActivityLog?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let server: JamfPlatform.Server = configuration.flavor == .platform ? .platformAPI : .jamfPro
        self.server = server
        let recorder = RequestRecorder(
            session: session, log: activityLog, category: "API",
            service: configuration.flavor == .platform ? "Jamf Platform API" : "Jamf Pro",
            connection: configuration.connectionName
        )
        let tokenPath: String
        let method: JamfPlatform.TokenProvider.Method
        switch configuration.flavor {
        case .platform: (tokenPath, method) = ("auth/token", .apiClient(clientID: configuration.clientID))
        case .jamfProAPIClient: (tokenPath, method) = ("api/oauth/token", .apiClient(clientID: configuration.clientID))
        case .jamfProUser: (tokenPath, method) = ("api/v1/auth/token", .usernamePassword(username: configuration.clientID))
        }
        let tokens = JamfPlatform.TokenProvider(tokenURL: configuration.gatewayURL.appending(path: tokenPath), method: method,
                                                secret: configuration.secret, recorder: recorder)
        self.tokens = tokens
        // JTKit refuses an Environment ID that isn't a UUID; the error is
        // kept and thrown at the first request, so nothing is sent.
        platform = Result {
            // the sign-in method decides where a hint points: the API
            // role, or a user account's own privileges and password
            try JamfPlatform.Client(baseURL: configuration.gatewayURL, scope: configuration.scope, server: server,
                                    signIn: configuration.flavor == .jamfProUser ? .usernamePassword : .apiClient,
                                    tokens: tokens, recorder: recorder)
        }
        .mapError { $0 as? JamfPlatform.APIError ?? JamfPlatform.APIError(.invalidResponse($0.localizedDescription)) }
    }

    // MARK: Requests

    // Every request names its Jamf Pro privileges from JTKit's table, so a
    // refusal (403) on a Jamf Pro connection names the missing one.

    /// GET a path relative to the gateway root (e.g. "/pro/v1/categories"),
    /// for callers that read the status themselves (the preflight's checks,
    /// Day 0's status reads). An error status comes back as the status, read
    /// from JTKit's thrown error, with no data (no caller reads an error's
    /// body); a refused sign-in and every other error is thrown. `accept`
    /// overrides JTKit's default (XML for Classic API paths).
    func get(_ path: String, query: [URLQueryItem] = [], accept: String? = nil,
             privileges: [JamfPro.Privilege]) async throws -> (Data, Int) {
        do {
            let response = try await send(HTTPRequest(method: "GET", path: path, query: query, accept: accept),
                                          privileges: privileges)
            return (response.data, response.status)
        } catch let error as JamfPlatform.APIError {
            guard case .status(let status, _, _, _, _) = error.kind else { throw error }
            return (Data(), status)
        }
    }

    /// GET with a non-JSON Accept header (file downloads like the ADE
    /// public key).
    func getRaw(_ path: String, accept: String, privileges: [JamfPro.Privilege]) async throws -> Data {
        try await send(HTTPRequest(method: "GET", path: path, accept: accept), privileges: privileges).data
    }

    /// POST a JSON body. Never recorded in the log: Day 0 bodies carry
    /// tokens (ADE, volume purchasing).
    func post(_ path: String, json: [String: any Sendable], privileges: [JamfPro.Privilege]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(HTTPRequest(method: "POST", path: path, body: body, contentType: "application/json"),
                              privileges: privileges).data
    }

    func getDecoded<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = [],
        privileges: [JamfPro.Privilege]
    ) async throws -> T {
        let response = try await send(HTTPRequest(method: "GET", path: path, query: query), privileges: privileges)
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw try platform.get().failure(
                JamfPlatform.APIError(.invalidResponse("\(path) could not be read: \(error.localizedDescription)")))
        }
    }

    /// Every item of a Jamf Pro list, with JTKit's page reader: an answer
    /// without `results` is an error, not an empty list, and a list that
    /// never ends stops after 1,000 pages with an error.
    func allPages<Item: Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        pageSize: Int = 100,
        privileges: [JamfPro.Privilege],
        item: @escaping @Sendable (LosslessJSON) -> Item?
    ) async throws -> [Item] {
        try checkInstanceURL()
        return try await platform.get().allPages(Self.encodedPath(path), query: query, pageSize: pageSize,
                                                       privileges: privileges, item: item)
    }

    /// `allPages`, each result decoded as `Item`; a result that can't be
    /// decoded is left out (it still counts towards the end of the list).
    func allPages<Item: Decodable & Sendable>(
        _ path: String,
        as type: Item.Type,
        query: [URLQueryItem] = [],
        pageSize: Int = 100,
        privileges: [JamfPro.Privilege]
    ) async throws -> [Item] {
        try await allPages(path, query: query, pageSize: pageSize, privileges: privileges) { Self.decoded(type, $0) }
    }

    /// `page`, each result decoded as `Item`.
    func page<Item: Decodable & Sendable>(
        _ path: String,
        as type: Item.Type,
        page: Int = 0,
        pageSize: Int,
        query: [URLQueryItem] = [],
        privileges: [JamfPro.Privilege]
    ) async throws -> JamfPlatform.Page<Item> {
        try await self.page(path, page: page, pageSize: pageSize, query: query, privileges: privileges) {
            Self.decoded(type, $0)
        }
    }

    private static func decoded<Item: Decodable>(_ type: Item.Type, _ json: LosslessJSON) -> Item? {
        try? JSONDecoder().decode(type, from: json.serialized())
    }

    /// One page of a Jamf Pro list (counts, a search's first results), with
    /// JTKit's page reader.
    func page<Item: Sendable>(
        _ path: String,
        page: Int = 0,
        pageSize: Int,
        query: [URLQueryItem] = [],
        privileges: [JamfPro.Privilege],
        item: @escaping @Sendable (LosslessJSON) -> Item?
    ) async throws -> JamfPlatform.Page<Item> {
        try checkInstanceURL()
        return try await platform.get().page(Self.encodedPath(path), page: page, pageSize: pageSize, query: query,
                                                   privileges: privileges, item: item)
    }

    /// The Jamf Pro version, with JTKit's call; also the credentials probe.
    func jamfProVersion() async throws -> String {
        try checkInstanceURL()
        return try await platform.get().jamfProVersion().version
    }

    /// JTKit's read-only permission check: only a 403 is a missing permission.
    func checkPermissions(
        _ checks: [JamfPlatform.PermissionCheck]
    ) async throws -> [(check: JamfPlatform.PermissionCheck, result: JamfPlatform.PermissionResult)] {
        try checkInstanceURL()
        let encoded = checks.map { check in
            var check = check
            check.path = Self.encodedPath(check.path)
            return check
        }
        let results = try await platform.get().checkPermissions(encoded)
        // the callers' own checks, with their unencoded paths
        return zip(checks, results).map { ($0, $1.result) }
    }

    /// Drops the token, so the next request signs in again.
    func forgetToken() async {
        await tokens.forgetToken()
    }

    /// How many times this client signed in; for tests.
    var signInCount: Int {
        get async { await tokens.signInCount }
    }

    /// How this client signs in, for hints that depend on it.
    nonisolated var signIn: SignInMethod {
        configuration.flavor == .jamfProUser ? .usernamePassword : .apiClient
    }

    private func checkInstanceURL() throws {
        guard !configuration.hasInvalidInstanceURL else { throw JamfAPIError.invalidInstanceURL }
    }

    private func send(_ request: HTTPRequest, privileges: [JamfPro.Privilege]) async throws -> HTTPResponse {
        try checkInstanceURL()
        var request = request
        request.path = Self.encodedPath(request.path)
        return try await platform.get().send(request, privileges: privileges)
    }

    /// The environments an organization-scope integration sees, for the
    /// wizard's picker. JTKit's call, with no scope header.
    ///
    /// - Throws: `JamfPlatform.APIError` `.cannotListEnvironments` for an
    ///   integration scoped to one environment.
    static func environments(
        region: JamfRegion,
        clientID: String,
        clientSecret: String,
        activityLog: ActivityLog?,
        session: URLSession = .shared
    ) async throws -> [JamfPlatform.Environment] {
        let connection = Connection(name: "New tenant", service: .jamfPlatform, signIn: .apiClient,
                                    region: region, clientID: clientID)
        let recorder = RequestRecorder(session: session, log: activityLog, category: "API", service: "Jamf Platform API")
        return try await JamfPlatform.environments(for: connection, secret: { clientSecret }, recorder: recorder)
    }

    /// Callers pass unencoded paths (a Classic API lookup by name can hold
    /// spaces, `%` or `?`); each part is percent-encoded, as the old client's
    /// `appending(path:)` did. A name that is `..` or holds a backslash is
    /// then refused by JTKit before anything is sent.
    static func encodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }
}
