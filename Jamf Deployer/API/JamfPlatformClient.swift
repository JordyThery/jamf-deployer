import Foundation
import DeployerKit

/// Connection details for one tenant's Platform API integration.
/// The secret is read from the Keychain by the caller and lives in memory
/// only for the lifetime of the client.
nonisolated struct JamfAPIConfiguration: Sendable {
    var gatewayURL: URL
    var clientID: String
    var clientSecret: String
    /// Exactly one scope header per request: X-Environment-Id (preferred)
    /// or X-Tenant-Id (legacy).
    var scopeHeaderName: String?
    var scopeHeaderValue: String?

    init(tenant: Tenant, clientSecret: String) {
        gatewayURL = tenant.region.gatewayURL
        clientID = tenant.clientID
        self.clientSecret = clientSecret
        switch tenant.apiScope {
        case .environment:
            scopeHeaderName = "X-Environment-Id"
            scopeHeaderValue = tenant.environmentID
        case .tenant:
            scopeHeaderName = "X-Tenant-Id"
            scopeHeaderValue = tenant.tenantID
        }
    }

    init(gatewayURL: URL, clientID: String, clientSecret: String, environmentID: String?) {
        self.gatewayURL = gatewayURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        scopeHeaderName = environmentID == nil ? nil : "X-Environment-Id"
        scopeHeaderValue = environmentID
    }
}

nonisolated enum JamfAPIError: LocalizedError {
    case notAuthenticated(String)
    case permissionDenied(path: String)
    case http(status: Int, path: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let detail):
            "Jamf did not accept the credentials. Check the client ID, client secret and region. (\(detail))"
        case .permissionDenied(let path):
            "The API integration is missing a permission for \(path). Add it in Jamf Account and try again."
        case .http(let status, let path):
            "Jamf answered \(path) with HTTP \(status)."
        case .invalidResponse:
            "Jamf sent a response the app could not read."
        }
    }
}

/// Direct Jamf Platform API client: everything outside the engine
/// (preflight, Day 0, token expiry, pickers). OAuth tokens live 900 seconds
/// and are refreshed one minute early. Never logs secrets or headers.
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
        guard status == 200 else { throw JamfAPIError.http(status: status, path: path) }
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

        guard var components = URLComponents(
            url: configuration.gatewayURL.appending(path: path),
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
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw JamfAPIError.invalidResponse }
            let duration = (ContinuousClock.now - start).seconds
            log(method: method, path: path, status: http.statusCode, duration: duration, note: attempt > 1 ? "attempt \(attempt)" : nil)

            if shouldRetry(status: http.statusCode), attempt < 4 {
                try await backOff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                return try await send(method: method, path: path, query: query, body: body, contentType: contentType, accept: accept, attempt: attempt + 1)
            }
            return (data, http.statusCode)
        } catch let error as URLError where isTransient(error) && attempt < 4 {
            log(method: method, path: path, status: nil, duration: (ContinuousClock.now - start).seconds, note: "network error, will retry: \(error.code.rawValue)")
            try await backOff(attempt: attempt, retryAfter: nil)
            return try await send(method: method, path: path, query: query, body: body, contentType: contentType, accept: accept, attempt: attempt + 1)
        }
    }

    // MARK: Token

    private func validToken() async throws -> String {
        if let token, token.expiry > .now + 60 {
            return token.value
        }

        var request = URLRequest(url: configuration.gatewayURL.appending(path: "/auth/token"))
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JamfAPIError.invalidResponse }
        log(method: "POST", path: "/auth/token", status: http.statusCode, duration: (ContinuousClock.now - start).seconds, note: nil)

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
