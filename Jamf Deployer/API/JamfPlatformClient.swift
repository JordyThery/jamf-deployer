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
    /// Exactly one scope header per request: X-Environment-Id (preferred)
    /// or X-Tenant-Id (legacy).
    var scopeHeaderName: String?
    var scopeHeaderValue: String?
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
            scopeHeaderName = "X-Environment-Id"
            scopeHeaderValue = tenant.environmentID
        case .tenant:
            scopeHeaderName = "X-Tenant-Id"
            scopeHeaderValue = tenant.tenantID
        }
    }

    init(gatewayURL: URL, clientID: String, clientSecret: String, environmentID: String?, tenantID: String? = nil) {
        self.gatewayURL = gatewayURL
        self.clientID = clientID
        secret = { clientSecret }
        if let environmentID {
            scopeHeaderName = "X-Environment-Id"
            scopeHeaderValue = environmentID
        } else if let tenantID {
            scopeHeaderName = "X-Tenant-Id"
            scopeHeaderValue = tenantID
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

nonisolated enum JamfAPIError: LocalizedError {
    case notAuthenticated(String)
    case http(status: Int, path: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let detail):
            "Jamf did not accept the credentials. Check them and the region or Jamf Pro URL. (\(detail))"
        case .http(let status, let path):
            "Jamf answered \(path) with HTTP \(status)."
        case .invalidResponse:
            "Jamf sent a response the app could not read."
        }
    }
}

/// Direct Jamf API client, for the Platform API gateway or a Jamf Pro
/// instance: everything outside the engine (preflight, Day 0, token expiry,
/// pickers). Built on JTKit's token provider and HTTP client: one shared
/// sign-in, the token renewed a minute before it expires, JTKit's retry
/// rules, and every request in the activity log with secrets hidden
/// (request bodies never, answers only for errors). Never follows a
/// redirect to another host or to plain HTTP, the sign-in included.
///
/// Saved tenants share one client each (`TenantClients`).
actor JamfPlatformClient {
    private let configuration: JamfAPIConfiguration
    private let tokens: JamfTokenProvider
    private let http: HTTPClient

    init(
        configuration: JamfAPIConfiguration,
        activityLog: ActivityLog?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
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
        tokens = JamfTokenProvider(tokenURL: configuration.gatewayURL.appending(path: tokenPath), method: method,
                                   secret: configuration.secret, recorder: recorder)
        var headers: [String: String] = [:]
        if let name = configuration.scopeHeaderName, let value = configuration.scopeHeaderValue {
            headers[name] = value
        }
        http = HTTPClient(baseURL: configuration.gatewayURL, tokens: tokens, recorder: recorder,
                          headers: headers, redirects: .sameHostHTTPSOnly)
    }

    // MARK: Requests

    /// GET a path relative to the gateway root (e.g. "/pro/v1/categories").
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, Int) {
        try await send(HTTPRequest(method: "GET", path: path, query: query))
    }

    /// GET with a non-JSON Accept header (file downloads like the ADE
    /// public key).
    func getRaw(_ path: String, accept: String) async throws -> (Data, Int) {
        try await send(HTTPRequest(method: "GET", path: path, accept: accept))
    }

    /// POST a JSON body. Never recorded in the log: Day 0 bodies carry
    /// tokens (ADE, volume purchasing).
    func post(_ path: String, json: [String: any Sendable]) async throws -> (Data, Int) {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(HTTPRequest(method: "POST", path: path, body: body, contentType: "application/json"))
    }

    func getDecoded<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let (data, status) = try await get(path, query: query)
        guard status == 200 else { throw JamfAPIError.http(status: status, path: Self.mapped(path, for: configuration.flavor)) }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JamfAPIError.invalidResponse
        }
    }

    /// Drops the token, so the next request signs in again.
    func forgetToken() async {
        await tokens.forgetToken()
    }

    /// How many times this client signed in; for tests.
    var signInCount: Int {
        get async { await tokens.signInCount }
    }

    /// Sends the request; an error status comes back as the status, as the
    /// callers expect (preflight reads 403s), a refused sign-in as
    /// `notAuthenticated`.
    private func send(_ request: HTTPRequest) async throws -> (Data, Int) {
        guard !configuration.hasInvalidInstanceURL else {
            throw JamfAPIError.notAuthenticated("the saved Jamf Pro URL is not valid")
        }
        var request = request
        request.path = Self.encodedPath(Self.mapped(request.path, for: configuration.flavor))
        do {
            let response = try await http.send(request)
            return (response.data, response.status)
        } catch let HTTPError.status(response, _, _, duringSignIn) {
            if duringSignIn { throw JamfAPIError.notAuthenticated("HTTP \(response.status)") }
            return (response.data, response.status)
        } catch HTTPError.decoding, HTTPError.invalidURL {
            throw JamfAPIError.invalidResponse
        }
    }

    /// Callers use Platform gateway paths; a Jamf Pro instance serves the
    /// same resources under its own prefixes.
    static func mapped(_ path: String, for flavor: JamfAPIConfiguration.Flavor) -> String {
        guard flavor != .platform else { return path }
        if path.hasPrefix("/pro/") { return "/api/" + path.dropFirst("/pro/".count) }
        if path.hasPrefix("/proclassic/") { return "/JSSResource/" + path.dropFirst("/proclassic/".count) }
        return path
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
