import Foundation
import Testing
import JamfDeployerCore
import JTKit
import JTKitTestSupport
@testable import Jamf_Deployer

// ROADMAP step 5: the API client on JTKit's networking, one client per
// tenant, the six Keychain items on JTKit's store, and engine output
// cleaned before it is logged or written.

private let environment1 = "6F1C2B3A-4D5E-4F60-8172-93A4B5C6D7E8"
private let environment2 = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"

private func platformTenant(name: String = "Sandbox") -> Tenant {
    Tenant(name: name, region: .us, clientID: "client-1", environmentID: environment1, isProduction: false)
}

private func tokenJSON(_ token: String) -> String {
    #"{"access_token":"\#(token)","expires_in":900,"token_type":"Bearer"}"#
}

/// A registry on a fake server, with the secret in memory instead of the
/// Keychain.
private func registry(_ server: MockServer, signInID: @escaping @Sendable (Tenant) -> String = { $0.clientID }) -> TenantClients {
    TenantClients(session: server.session, signInID: signInID) { tenant, id in
        var configuration = JamfAPIConfiguration(tenant: tenant, signInID: id)
        configuration.secret = { "s3cr3t+value" }
        return configuration
    }
}

@MainActor
@Suite("One API client per tenant")
struct TenantClientsTests {
    private let server = MockServer { request in
        request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(200, #"{"version":"11.20.0"}"#)
    }

    @Test func aTenantKeepsOneClientAndOneSignIn() async throws {
        let clients = registry(server)
        let tenant = platformTenant()
        let first = clients.client(for: tenant, activityLog: nil)
        #expect(clients.client(for: tenant, activityLog: nil) === first)

        async let a = first.get("/pro/v1/jamf-pro-version")
        async let b = clients.client(for: tenant, activityLog: nil).get("/pro/v1/categories")
        _ = try await (a, b)
        #expect(await first.signInCount == 1)
        #expect(server.requests.filter { $0.path == "/auth/token" }.count == 1)
    }

    @Test(arguments: ["name", "region", "environment", "scope", "jamfPro", "signInID"])
    func aConnectionEditGivesANewClient(field: String) throws {
        let signInID = Locked("client-1")
        let clients = registry(server) { _ in signInID.value }
        var tenant = platformTenant()
        let before = clients.client(for: tenant, activityLog: nil)
        switch field {
        case "name": tenant.name = "Renamed"
        case "region": tenant.region = .eu
        case "environment": tenant.environmentID = environment2
        case "scope": tenant.environmentID = nil; tenant.tenantID = "tenant-1"
        case "jamfPro": tenant.connection = .jamfPro; tenant.jamfProURL = "https://acme.jamfcloud.com"
        default: signInID.value = "engineer-2"
        }
        #expect(clients.client(for: tenant, activityLog: nil) !== before)
    }

    @Test func deployBookkeepingKeepsTheClient() {
        let clients = registry(server)
        var tenant = platformTenant()
        let before = clients.client(for: tenant, activityLog: nil)
        tenant.lastDeploy = DeployRecord(date: .now, engineerName: "Jordy", succeeded: 3, failed: 0)
        tenant.deployedBlockVersions = ["wifi": "1.2.0"]
        tenant.blockSelections = [BlockSelection(blockID: "wifi")]
        tenant.isProduction = true
        #expect(clients.client(for: tenant, activityLog: nil) === before)
    }

    @Test func aSecretChangeOrRemovalDropsTheClientAndForgetsItsToken() async throws {
        let clients = registry(server)
        let tenant = platformTenant()
        let before = clients.client(for: tenant, activityLog: nil)
        _ = try await before.get("/pro/v1/categories")

        clients.secretChanged(account: tenant.id.uuidString)
        let after = clients.client(for: tenant, activityLog: nil)
        #expect(after !== before)
        // the old client's token is forgotten too, for a caller still holding it
        try await Task.sleep(for: .milliseconds(100))
        _ = try await before.get("/pro/v1/categories")
        #expect(await before.signInCount == 2)

        clients.drop(tenant.id)
        #expect(clients.client(for: tenant, activityLog: nil) !== after)
    }

    @Test func blockSettingsAndTheTeamPassphraseKeepTheClient() {
        let clients = registry(server)
        let tenant = platformTenant()
        let before = clients.client(for: tenant, activityLog: nil)
        clients.secretChanged(account: "\(tenant.id.uuidString).wifi.password")
        clients.secretChanged(account: "state-passphrase")
        #expect(clients.client(for: tenant, activityLog: nil) === before)
    }
}

@MainActor
@Suite("API client on JTKit")
struct JamfPlatformClientTests {
    private func client(_ configuration: JamfAPIConfiguration, server: MockServer, log: ActivityLog? = nil) -> JamfPlatformClient {
        JamfPlatformClient(configuration: configuration, activityLog: log, session: server.session)
    }

    private let platform = JamfAPIConfiguration(
        gatewayURL: URL(string: "https://us.api.jamfcloud.com")!, clientID: "client-1",
        clientSecret: "s3cr3t+with&specials=", environmentID: environment1)

    @Test func platformSignsInStrictlyAndSendsTheScopeHeader() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok-1")) : .json(200, "{}")
        }
        let (_, status) = try await client(platform, server: server).get("/pro/v1/categories", query: [URLQueryItem(name: "page-size", value: "1")])
        #expect(status == 200)
        let signIn = try #require(server.requests.first)
        #expect(signIn.bodyString == "grant_type=client_credentials&client_id=client-1&client_secret=s3cr3t%2Bwith%26specials%3D")
        let get = try #require(server.requests.last)
        #expect(get.url.absoluteString == "https://us.api.jamfcloud.com/pro/v1/categories?page-size=1")
        #expect(get.header("Authorization") == "Bearer tok-1")
        #expect(get.header("X-Environment-Id") == environment1)
    }

    @Test func anErrorStatusComesBackAsTheStatus() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(403, #"{"httpStatus":403}"#)
        }
        let (_, status) = try await client(platform, server: server).get("/pro/v1/scripts")
        #expect(status == 403)
    }

    @Test func aRefusedSignInIsThrownInJTKitsFormat() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        await #expect {
            _ = try await client(platform, server: server).get("/pro/v1/scripts")
        } throws: { error in
            guard let error = error as? JamfPlatformError, case .signIn(401, _, _) = error.kind else { return false }
            return error.message().hasPrefix("Sign-in failed: HTTP 401")
        }
    }

    @Test func jamfProUserMapsPathsAndUsesItsTokenEndpoint() async throws {
        let server = MockServer { request in
            request.path == "/api/v1/auth/token"
                ? .json(200, #"{"token":"user-token","expires":"2099-01-01T00:00:00Z"}"#)
                : .json(200, "{}")
        }
        let configuration = JamfAPIConfiguration(jamfProURL: URL(string: "https://acme.jamfcloud.com")!,
                                                 auth: .userAccount, clientID: "admin", clientSecret: "hunter2")
        let jamfPro = client(configuration, server: server)
        _ = try await jamfPro.get("/pro/v1/categories")
        _ = try await jamfPro.get("/proclassic/policies/name/Install Office 100%")
        #expect(server.requests.map(\.path) == ["/api/v1/auth/token", "/api/v1/categories", "/JSSResource/policies/name/Install%20Office%20100%25"])
        #expect(server.requests.last?.url.absoluteString == "https://acme.jamfcloud.com/JSSResource/policies/name/Install%20Office%20100%25")
        #expect(server.requests.first?.header("Authorization") == "Basic " + Data("admin:hunter2".utf8).base64EncodedString())
        #expect(server.requests.last?.header("X-Environment-Id") == nil)
    }

    @Test func anInvalidJamfProURLSendsNothing() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        var tenant = platformTenant()
        tenant.connection = .jamfPro
        tenant.jamfProURL = "http://not-https.example.com"
        var configuration = JamfAPIConfiguration(tenant: tenant, signInID: "id")
        configuration.secret = { "x" }
        await #expect(throws: JamfAPIError.self) { _ = try await client(configuration, server: server).get("/pro/v1/categories") }
        #expect(server.requests.isEmpty)
    }

    @Test func redirectsToAnotherHostAreRefusedForTheSignInAndRequests() async throws {
        let evil = URL(string: "https://evil.example/collect")!
        let signIn = MockServer { request in
            request.url.host() == "evil.example" ? .json(200, tokenJSON("x")) : .redirect(to: evil)
        }
        await #expect(throws: (any Error).self) { _ = try await client(platform, server: signIn).get("/pro/v1/scripts") }
        #expect(!signIn.requests.contains { $0.url.host() == "evil.example" })

        let request = MockServer { request in
            if request.url.host() == "evil.example" { return .json(200, "{}") }
            return request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .redirect(to: evil)
        }
        let (_, status) = try await client(platform, server: request).get("/pro/v1/scripts")
        #expect(status == 307)
        #expect(!request.requests.contains { $0.url.host() == "evil.example" })
    }

    @Test func theLogShowsRequestsButNeverTheSecretOrTheToken() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok-secret-value")) : .json(500, #"{"error":"boom"}"#)
        }
        let log = ActivityLog()
        var configuration = platform
        configuration.connectionName = "Sandbox"
        // a POST is never repeated after a server error, so one attempt
        _ = try? await client(configuration, server: server, log: log)
            .post("/pro/v1/volume-purchasing-locations", json: ["serviceToken": "vpp-token-value"])
        let text = log.entries.map(ActivityLogExport.transcript(of:)).joined(separator: "\n")
        #expect(log.entries.contains { $0.category == "Sign-in" })
        #expect(log.entries.contains { $0.category == "API" && $0.status == 500 && $0.connection == "Sandbox" })
        for secret in ["s3cr3t", "tok-secret-value", "vpp-token-value"] {
            #expect(!text.contains(secret))
        }
    }
}

@MainActor
@Suite("Platform API from JTKit")
struct PlatformAdoptionTests {
    private let platform = JamfAPIConfiguration(
        gatewayURL: URL(string: "https://us.api.jamfcloud.com")!, clientID: "client-1",
        clientSecret: "secret", environmentID: environment1)

    private func client(_ configuration: JamfAPIConfiguration? = nil, server: MockServer) -> JamfPlatformClient {
        JamfPlatformClient(configuration: configuration ?? platform, activityLog: nil, session: server.session)
    }

    @Test func anEnvironmentIDThatIsNotAUUIDSendsNothing() async throws {
        let server = MockServer { _ in .json(200, tokenJSON("tok")) }
        var tenant = platformTenant()
        tenant.environmentID = "env-1"
        var configuration = JamfAPIConfiguration(tenant: tenant, signInID: "client-1")
        configuration.secret = { "secret" }
        await #expect {
            _ = try await client(configuration, server: server).get("/pro/v1/categories")
        } throws: { error in
            guard let error = error as? JamfPlatformError, case .invalidEnvironmentID("env-1") = error.kind else { return false }
            return true
        }
        #expect(server.requests.isEmpty)
    }

    @Test func aLegacyTenantIDIsSentAsBefore() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(200, "{}")
        }
        var tenant = platformTenant()
        tenant.environmentID = nil
        tenant.tenantID = "legacy-tenant"
        var configuration = JamfAPIConfiguration(tenant: tenant, signInID: "client-1")
        configuration.secret = { "secret" }
        _ = try await client(configuration, server: server).get("/pro/v1/categories")
        #expect(server.requests.last?.header("X-Tenant-Id") == "legacy-tenant")
        #expect(server.requests.last?.header("X-Environment-Id") == nil)
    }

    @Test func aJamfErrorShowsItsCodeTraceIDAndHint() async throws {
        let server = MockServer { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(403, #"{"httpStatus":403,"traceId":"trace-123","errors":[{"code":"BAD_PERMISSIONS","field":"scripts","description":"Missing scripts:read"}]}"#)
        }
        struct Version: Decodable, Sendable { let version: String }
        await #expect {
            _ = try await client(server: server).getDecoded(Version.self, path: "/pro/v1/jamf-pro-version")
        } throws: { error in
            let message = error.localizedDescription
            return message.contains("BAD_PERMISSIONS (scripts): Missing scripts:read")
                && message.contains("trace-123")
                && message.contains("Jamf Account")
        }
    }

    @Test func aDay0WriteErrorIsThrownInJTKitsFormat() async throws {
        let server = MockServer { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(400, #"{"httpStatus":400,"traceId":"trace-9","errors":[{"code":"INVALID_FIELD","field":"serviceToken","description":"Token is expired"}]}"#)
        }
        await #expect {
            _ = try await client(server: server).post("/pro/v1/volume-purchasing-locations", json: ["serviceToken": "x"])
        } throws: { error in
            error.localizedDescription.contains("INVALID_FIELD (serviceToken): Token is expired")
        }
    }

    @Test func preflightTellsAMissingPermissionFromNotFoundAndFailed() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": .json(200, tokenJSON("tok"))
            case "/pro/v1/jamf-pro-version": .json(200, #"{"version":"11.33.0-t1"}"#)
            case "/pro/v1/categories": .json(200, #"{"totalCount":0,"results":[]}"#)
            case "/pro/v1/scripts": .json(403, #"{"httpStatus":403}"#)
            case "/pro/v1/device-enrollments": .json(404, #"{"httpStatus":404}"#)
            case "/pro/v1/volume-purchasing-locations": .json(401, #"{"httpStatus":401}"#)
            default: .json(200, #"{"totalCount":0,"results":[]}"#)
            }
        }
        let report = await PreflightService.run(client: client(server: server)) { _ in }
        let rows = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        #expect(rows["/pro/v1/categories"]?.outcome == .pass)
        #expect(rows["/pro/v1/scripts"]?.outcome == .fail)
        #expect(rows["/pro/v1/scripts"]?.detail == "Not allowed. Add the “scripts:read” permission to the API integration in Jamf Account.")
        #expect(rows["/pro/v1/device-enrollments"]?.outcome == .warn)
        #expect(rows["/pro/v1/device-enrollments"]?.detail.contains("HTTP 404") == true)
        #expect(rows["/pro/v1/volume-purchasing-locations"]?.outcome == .warn)
        #expect(rows["/pro/v1/volume-purchasing-locations"]?.detail.contains("HTTP 401") == true)
        #expect(report.checks.map(\.id).prefix(6) == ["auth", "version", "/pro/v1/categories", "/pro/v1/scripts",
                                                     "/pro/v1/device-enrollments", "/pro/v1/volume-purchasing-locations"])
    }

    @Test func aJamfProTenantIsToldWhichPrivilegeToAdd() {
        let row = PreflightService.permissionRow(PreflightService.permissionChecks[1], .missingPermission, server: .jamfPro)
        #expect(row.detail == "Not allowed. Add the “Read Scripts” privilege to the API role in Jamf Pro under Settings › API Roles and Clients.")
    }

    @Test func preflightTakesTheFirstExpiryFromTheWholeList() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": .json(200, tokenJSON("tok"))
            case "/pro/v1/jamf-pro-version": .json(200, #"{"version":"11.33.0"}"#)
            case "/pro/v1/device-enrollments":
                // the permission check reads one item; the expiry read reads them all
                request.url.query()?.contains("page-size=1") == true
                    ? .json(200, #"{"totalCount":2,"results":[{"tokenExpirationDate":"2027-05-01"}]}"#)
                    : .json(200, #"{"totalCount":2,"results":[{"tokenExpirationDate":"2027-05-01"},{"tokenExpirationDate":"2026-12-01"}]}"#)
            case "/pro/v1/volume-purchasing-locations":
                request.url.query()?.contains("page-size=1") == true
                    ? .json(200, #"{"totalCount":2,"results":[{"tokenExpiration":"2027-03-01T00:00:00Z"}]}"#)
                    : .json(200, #"{"totalCount":2,"results":[{"tokenExpiration":"2027-03-01T00:00:00Z"},{"tokenExpiration":"2027-01-15T00:00:00Z"}]}"#)
            default: .json(200, #"{"totalCount":0,"results":[]}"#)
            }
        }
        let report = await PreflightService.run(client: client(server: server)) { _ in }
        #expect(report.snapshot.adeTokenExpiration == "2026-12-01")
        #expect(report.snapshot.vppTokenExpiration == "2027-01-15T00:00:00Z")
    }

    @Test func environmentsAreListedSortedWithoutAScopeHeader() async throws {
        let server = MockServer { request in
            request.path == "/auth/token"
                ? .json(200, tokenJSON("tok"))
                : .json(200, #"{"results":[{"id":"\#(environment2)","name":"Production"},{"id":"\#(environment1)","name":"Lab"}]}"#)
        }
        let environments = try await JamfPlatformClient.environments(
            region: .eu, clientID: "client-1", clientSecret: "secret", activityLog: nil, session: server.session)
        #expect(environments.map(\.name) == ["Lab", "Production"])
        let list = try #require(server.requests.last)
        #expect(list.url.absoluteString == "https://eu.api.jamfcloud.com/organization/v1/environments")
        #expect(list.header("X-Environment-Id") == nil && list.header("X-Tenant-Id") == nil)
    }

    @Test func anEnvironmentScopedIntegrationIsToldWhereToFindTheID() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(403, #"{"httpStatus":403}"#)
        }
        await #expect {
            _ = try await JamfPlatformClient.environments(
                region: .us, clientID: "client-1", clientSecret: "secret", activityLog: nil, session: server.session)
        } throws: { error in
            guard let error = error as? JamfPlatformError, case .cannotListEnvironments = error.kind else { return false }
            return error.message().contains("account.jamf.com")
        }
    }
}

@Suite("Keychain items")
struct KeychainItemTests {
    @Test func allSixItemsKeepTheirServiceAndAccount() {
        let id = UUID()
        let secrets = TenantSecrets(tenantID: id)
        let items: [(KeychainItem, String, String)] = [
            (secrets.platformClientSecret, "be.jordythery.jamf-deployer.platform-client-secret", id.uuidString),
            (secrets.protectClientSecret, "be.jordythery.jamf-deployer.protect-client-secret", id.uuidString),
            (secrets.engineerClientID, "be.jordythery.jamf-deployer.engineer-client-id", id.uuidString),
            (secrets.statePassphrase, "be.jordythery.jamf-deployer.state-passphrase", id.uuidString),
            (secrets.blockSetting(blockID: "wifi", key: "password"), "be.jordythery.jamf-deployer.block-setting", "\(id.uuidString).wifi.password"),
            (TeamPassphrase.item, "be.jordythery.jamf-deployer.team", "state-passphrase"),
        ]
        for (item, service, account) in items {
            #expect(item.service == service)
            #expect(item.account == account)
        }
    }
}

@Suite("Engine output cleaning")
struct EngineOutputCleanerTests {
    @Test func aServerAnswerQuotedInsideAnEngineMessageIsCleaned() throws {
        let line = #"{"@level":"error","@message":"Error: create failed: {\"password\":\"Wifi-Pa55\",\"client_secret\":\"abc\"}","type":"diagnostic"}"#
        let cleaned = EngineOutputCleaner.cleanedLine(line)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        let message = try #require(object["@message"] as? String)
        #expect(message == #"Error: create failed: {"password":"<redacted>","client_secret":"<redacted>"}"#)
        #expect(object["type"] as? String == "diagnostic")
        #expect(!cleaned.contains("Wifi-Pa55"))
    }

    @Test func nestedDiagnosticsAndPlainLinesAreCleaned() {
        let nested = #"{"diagnostic":{"detail":"POST /auth/token client_secret=hunter2&grant_type=x","summary":"Bearer eyJabc.def"}}"#
        let cleanedNested = EngineOutputCleaner.cleanedLine(nested)
        #expect(!cleanedNested.contains("hunter2") && !cleanedNested.contains("eyJabc"))

        let plain = "│ Error: request failed, Authorization: Bearer eyJsecret.token"
        #expect(EngineOutputCleaner.cleanedLine(plain) == "│ Error: request failed, Authorization: Bearer <redacted>")
        #expect(EngineOutputCleaner.cleaned(#"{"password": "x"} and token=abc"#) == #"{"password": "<redacted>"} and token=<redacted>"#)
    }

    @Test func linesWithNothingToHideStayExactlyAsTheEnginePrintedThem() {
        let lines = [
            #"{"@level":"info","@message":"jamfpro_script.cleanup: Creating...","@timestamp":"2026-10-26T09:00:00.000000+01:00","type":"apply_start"}"#,
            "Initializing the backend...",
            "",
        ]
        #expect(EngineOutputCleaner.cleanedLog(lines) == lines.joined(separator: "\n"))
    }
}

@Suite("Component versions")
struct ComponentVersionTests {
    @Test(arguments: [
        ("1.1", "1.0", true),
        ("1.0", "1.1", false),
        ("1.0", "1.0", false),
        ("1.0.1", "1.0", true),
        ("1.0", "1.0.0", false),
        ("2.0", "1.9.9", true),
        ("0.10", "0.9", true),
    ])
    func comparesDotSeparatedVersions(candidate: String, installed: String, expected: Bool) {
        #expect(ComponentVersion.isNewer(candidate, than: installed) == expected)
    }
}

/// A value shared between a test and a closure.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
