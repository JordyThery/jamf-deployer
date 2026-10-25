import Foundation
import DeployerKit
import JTKit

/// Connection details for one tenant's Platform API integration.
/// The secret is read from the Keychain by the caller and lives in memory
/// only for the lifetime of the client.
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
    var clientSecret: String
    /// Exactly one scope header per request: X-Environment-Id (preferred)
    /// or X-Tenant-Id (legacy).
    var scopeHeaderName: String?
    var scopeHeaderValue: String?
    /// A Jamf Pro tenant whose saved URL is not a valid instance URL; no
    /// credentials are sent anywhere.
    var hasInvalidInstanceURL = false

    init(tenant: Tenant, clientSecret: String) {
        clientID = tenant.engineerClientID
        self.clientSecret = clientSecret
        if tenant.isJamfPro {
            let instance = Self.instanceURL(tenant.jamfProURL ?? "")
            gatewayURL = instance ?? tenant.region.gatewayURL
            hasInvalidInstanceURL = instance == nil
            flavor = tenant.jamfProAuth == .userAccount ? .jamfProUser : .jamfProAPIClient
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
        self.clientSecret = clientSecret
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
        self.clientSecret = clientSecret
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
/// pickers). Tokens are refreshed one minute before they expire. Never logs
/// secrets or headers, and never follows a redirect to another host.
actor JamfPlatformClient {
    private let configuration: JamfAPIConfiguration
    private let activityLog: ActivityLog?
    private let session: URLSession
    private var token: (value: String, expiry: Date)?

    init(
        configuration: JamfAPIConfiguration,
        activityLog: ActivityLog?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.activityLog = activityLog
        self.session = session
    }

    // MARK: Requests

    /// GET a path relative to the gateway root (e.g. "/pro/v1/categories").
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, Int) {
        try await send(method: "GET", path: path, query: query)
    }

    /// GET with a non-JSON Accept header (file downloads like the ADE
    /// public key).
    func getRaw(_ path: String, accept: String) async throws -> (Data, Int) {
        try await send(method: "GET", path: path, query: [], accept: accept)
    }

    /// POST a JSON body.
    func post(_ path: String, json: [String: any Sendable]) async throws -> (Data, Int) {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(method: "POST", path: path, query: [], body: body, contentType: "application/json")
    }

    func getDecoded<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let (data, status) = try await send(method: "GET", path: path, query: query)
        guard status == 200 else { throw JamfAPIError.http(status: status, path: Self.mapped(path, for: configuration.flavor)) }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JamfAPIError.invalidResponse
        }
    }

    private func send(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data? = nil,
        contentType: String? = nil,
        accept: String = "application/json",
        attempt: Int = 1
    ) async throws -> (Data, Int) {
        let accessToken = try await validToken()
        let wirePath = Self.mapped(path, for: configuration.flavor)

        guard var components = URLComponents(
            url: configuration.gatewayURL.appending(path: wirePath),
            resolvingAgainstBaseURL: false
        ) else { throw JamfAPIError.invalidResponse }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw JamfAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let name = configuration.scopeHeaderName, let value = configuration.scopeHeaderValue {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request, delegate: SameHostRedirects.shared)
            guard let http = response as? HTTPURLResponse else { throw JamfAPIError.invalidResponse }
            let duration = (ContinuousClock.now - start).seconds
            log(method: method, path: wirePath, status: http.statusCode, duration: duration, note: attempt > 1 ? "attempt \(attempt)" : nil)

            // A token that ended early (revoked, or a shorter server
            // lifetime) is discarded and fetched again once.
            if http.statusCode == 401, attempt == 1 {
                token = nil
                return try await send(method: method, path: path, query: query, body: body, contentType: contentType, accept: accept, attempt: attempt + 1)
            }

            // A write that timed out at the gateway may still have happened,
            // so only reads retry on server errors; rate limits always retry.
            let retryable = http.statusCode == 429 || (method == "GET" && shouldRetry(status: http.statusCode))
            if retryable, attempt < 4 {
                try await backOff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                return try await send(method: method, path: path, query: query, body: body, contentType: contentType, accept: accept, attempt: attempt + 1)
            }
            return (data, http.statusCode)
        } catch let error as URLError where method == "GET" && isTransient(error) && attempt < 4 {
            log(method: method, path: wirePath, status: nil, duration: (ContinuousClock.now - start).seconds, note: "network error, will retry: \(error.code.rawValue)")
            try await backOff(attempt: attempt, retryAfter: nil)
            return try await send(method: method, path: path, query: query, body: body, contentType: contentType, accept: accept, attempt: attempt + 1)
        }
    }

    // MARK: Token

    private func validToken() async throws -> String {
        if let token, token.expiry > .now + 60 {
            return token.value
        }
        if configuration.hasInvalidInstanceURL {
            throw JamfAPIError.notAuthenticated("the saved Jamf Pro URL is not valid")
        }

        if configuration.flavor == .jamfProUser {
            return try await jamfProUserToken()
        }
        let tokenPath = configuration.flavor == .platform ? "/auth/token" : "/api/oauth/token"
        var request = URLRequest(url: configuration.gatewayURL.appending(path: tokenPath))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Strict form encoding: URLComponents leaves "+" unescaped in query
        // strings, which a form parser reads back as a space and corrupts
        // secrets containing "+".
        func formEncoded(_ value: String) -> String {
            let unreserved = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        }
        let body = [
            ("grant_type", "client_credentials"),
            ("client_id", configuration.clientID),
            ("client_secret", configuration.clientSecret),
        ]
        .map { "\($0)=\(formEncoded($1))" }
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request, delegate: SameHostRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw JamfAPIError.invalidResponse }
        log(method: "POST", path: tokenPath, status: http.statusCode, duration: (ContinuousClock.now - start).seconds, note: nil)

        guard http.statusCode == 200 else {
            throw JamfAPIError.notAuthenticated("HTTP \(http.statusCode)")
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw JamfAPIError.invalidResponse
        }
        let expiry = Date.now + (decoded.expires_in ?? 900)
        token = (decoded.access_token, expiry)
        return decoded.access_token
    }

    /// Jamf Pro user accounts trade basic credentials for a bearer token.
    private func jamfProUserToken() async throws -> String {
        var request = URLRequest(url: configuration.gatewayURL.appending(path: "/api/v1/auth/token"))
        request.httpMethod = "POST"
        let credentials = Data("\(configuration.clientID):\(configuration.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request, delegate: SameHostRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw JamfAPIError.invalidResponse }
        log(method: "POST", path: "/api/v1/auth/token", status: http.statusCode, duration: (ContinuousClock.now - start).seconds, note: nil)
        guard http.statusCode == 200 else {
            throw JamfAPIError.notAuthenticated("HTTP \(http.statusCode)")
        }
        struct TokenResponse: Decodable {
            let token: String
            let expires: String?
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw JamfAPIError.invalidResponse
        }
        // Jamf Pro reports the expiry as ISO 8601, with or without
        // fractional seconds; without one, assume the 30-minute default and
        // refresh well before.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = decoded.expires.flatMap { withFraction.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        token = (decoded.token, expiry ?? Date.now + 20 * 60)
        return decoded.token
    }

    /// Callers use Platform gateway paths; a Jamf Pro instance serves the
    /// same resources under its own prefixes.
    static func mapped(_ path: String, for flavor: JamfAPIConfiguration.Flavor) -> String {
        guard flavor != .platform else { return path }
        if path.hasPrefix("/pro/") { return "/api/" + path.dropFirst("/pro/".count) }
        if path.hasPrefix("/proclassic/") { return "/JSSResource/" + path.dropFirst("/proclassic/".count) }
        return path
    }

    // MARK: Helpers

    private func shouldRetry(status: Int) -> Bool {
        status == 429 || status == 503 || status == 504
    }

    private func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    private func backOff(attempt: Int, retryAfter: String?) async throws {
        let seconds: Double
        if let retryAfter, let given = Double(retryAfter) {
            seconds = min(given, 300)
        } else {
            seconds = min(pow(2, Double(attempt)) + Double.random(in: 0...1), 60)
        }
        try await Task.sleep(for: .seconds(seconds))
    }

    private func log(method: String, path: String, status: Int?, duration: Double, note: String?) {
        guard let activityLog else { return }
        let entry = ActivityLogEntry(
            category: "API",
            operation: method,
            detail: path,
            status: status,
            duration: duration,
            note: note
        )
        Task { @MainActor in
            activityLog.append(entry)
        }
    }
}

extension Duration {
    nonisolated var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Refuses redirects that leave the original host or HTTPS, so credentials
/// and tokens never reach a host the user did not enter.
private nonisolated final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SameHostRedirects()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let sameHost = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
        completionHandler(sameHost ? request : nil)
    }
}
