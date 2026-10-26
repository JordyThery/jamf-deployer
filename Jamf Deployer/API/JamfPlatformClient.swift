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
                throw JamfAPIError.notAuthenticated(usesPassword ? "no password saved" : "no client secret saved")
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
/// JTKit's `JamfPlatformError`.
nonisolated enum JamfAPIError: LocalizedError {
    case notAuthenticated(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let detail):
            "Jamf did not accept the credentials. Check them and the region or Jamf Pro URL. (\(detail))"
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
    private let tokens: JamfTokenProvider
    /// Hands an error status back, for callers that read it themselves
    /// (`get`: the preflight's checks, Day 0's status reads).
    private let statusReturning: Result<JamfPlatform.Client, JamfPlatformError>
    /// Throws an error status as a `JamfPlatformError`. Shares the sign-in
    /// and token with `statusReturning`.
    private let statusThrowing: Result<JamfPlatform.Client, JamfPlatformError>
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
        let method: JamfTokenProvider.Method
        switch configuration.flavor {
        case .platform: (tokenPath, method) = ("auth/token", .apiClient(clientID: configuration.clientID))
        case .jamfProAPIClient: (tokenPath, method) = ("api/oauth/token", .apiClient(clientID: configuration.clientID))
        case .jamfProUser: (tokenPath, method) = ("api/v1/auth/token", .usernamePassword(username: configuration.clientID))
        }
        let tokens = JamfTokenProvider(tokenURL: configuration.gatewayURL.appending(path: tokenPath), method: method,
                                       secret: configuration.secret, recorder: recorder)
        self.tokens = tokens
        // JTKit refuses an Environment ID that isn't a UUID; the error is
        // kept and thrown at the first request, so nothing is sent.
        func client(_ errorStatus: JamfPlatform.Client.ErrorStatus) -> Result<JamfPlatform.Client, JamfPlatformError> {
            Result {
                try JamfPlatform.Client(baseURL: configuration.gatewayURL, scope: configuration.scope, server: server,
                                        tokens: tokens, recorder: recorder, errorStatus: errorStatus)
            }
            .mapError { $0 as? JamfPlatformError ?? JamfPlatformError(.invalidResponse($0.localizedDescription)) }
        }
        statusReturning = client(.returned)
        statusThrowing = client(.thrown)
    }

    // MARK: Requests

    /// GET a path relative to the gateway root (e.g. "/pro/v1/categories").
    /// An error status comes back as the status; a refused sign-in is thrown.
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, Int) {
        let response = try await send(HTTPRequest(method: "GET", path: path, query: query), on: statusReturning)
        return (response.data, response.status)
    }

    /// GET with a non-JSON Accept header (file downloads like the ADE
    /// public key).
    func getRaw(_ path: String, accept: String) async throws -> Data {
        try await send(HTTPRequest(method: "GET", path: path, accept: accept), on: statusThrowing).data
    }

    /// POST a JSON body. Never recorded in the log: Day 0 bodies carry
    /// tokens (ADE, volume purchasing).
    func post(_ path: String, json: [String: any Sendable]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(HTTPRequest(method: "POST", path: path, body: body, contentType: "application/json"),
                              on: statusThrowing).data
    }

    func getDecoded<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let response = try await send(HTTPRequest(method: "GET", path: path, query: query), on: statusThrowing)
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw try statusThrowing.get().failure(
                JamfPlatformError(.invalidResponse("\(path) could not be read: \(error.localizedDescription)")))
        }
    }

    /// JTKit's read-only permission check: only a 403 is a missing permission.
    func checkPermissions(
        _ checks: [JamfPlatform.PermissionCheck]
    ) async throws -> [(check: JamfPlatform.PermissionCheck, result: JamfPlatform.PermissionResult)] {
        guard !configuration.hasInvalidInstanceURL else {
            throw JamfAPIError.notAuthenticated("the saved Jamf Pro URL is not valid")
        }
        let encoded = checks.map { check in
            var check = check
            check.path = Self.encodedPath(check.path)
            return check
        }
        let results = try await statusThrowing.get().checkPermissions(encoded)
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

    private func send(_ request: HTTPRequest, on client: Result<JamfPlatform.Client, JamfPlatformError>) async throws -> HTTPResponse {
        guard !configuration.hasInvalidInstanceURL else {
            throw JamfAPIError.notAuthenticated("the saved Jamf Pro URL is not valid")
        }
        var request = request
        request.path = Self.encodedPath(request.path)
        return try await client.get().send(request)
    }

    /// The environments an organization-scope integration sees, for the
    /// wizard's picker. JTKit's call, with no scope header.
    ///
    /// - Throws: `JamfPlatformError` `.cannotListEnvironments` for an
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
