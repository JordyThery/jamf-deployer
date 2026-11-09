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

        async let a = first.get("/pro/v1/jamf-pro-version", privileges: [])
        async let b = clients.client(for: tenant, activityLog: nil).get("/pro/v1/categories", privileges: [.readCategories])
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
        _ = try await before.get("/pro/v1/categories", privileges: [.readCategories])

        clients.secretChanged(account: tenant.id.uuidString)
        let after = clients.client(for: tenant, activityLog: nil)
        #expect(after !== before)
        // the old client's token is forgotten too, for a caller still holding it
        try await Task.sleep(for: .milliseconds(100))
        _ = try await before.get("/pro/v1/categories", privileges: [.readCategories])
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
        let (_, status) = try await client(platform, server: server).get("/pro/v1/categories", query: [URLQueryItem(name: "page-size", value: "1")], privileges: [.readCategories])
        #expect(status == 200)
        let signIn = try #require(server.requests.first)
        #expect(signIn.bodyString == "grant_type=client_credentials&client_id=client-1&client_secret=s3cr3t%2Bwith%26specials%3D")
        let get = try #require(server.requests.last)
        #expect(get.url.absoluteString == "https://us.api.jamfcloud.com/pro/v1/categories?page-size=1")
        #expect(get.header("Authorization") == "Bearer tok-1")
        // JTKit 1.1.0 sends an Environment ID lowercased
        #expect(get.header("X-Environment-Id") == environment1.lowercased())
    }

    @Test func anErrorStatusComesBackAsTheStatus() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(403, #"{"httpStatus":403}"#)
        }
        let (_, status) = try await client(platform, server: server).get("/pro/v1/scripts", privileges: [.readScripts])
        #expect(status == 403)
    }

    /// What the preflight and Day 0 read from `get`: a 2xx with its answer,
    /// a 404 and another error status as the status, none of them thrown.
    @Test(arguments: [200, 204, 404, 403, 409])
    func getHandsBackEveryAnswersStatus(_ answer: Int) async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(answer, #"{"ssoEnabled":true}"#)
        }
        let (data, status) = try await client(platform, server: server).get("/pro/v3/sso", privileges: [.readSSOSettings])
        #expect(status == answer)
        #expect(data == ((200..<300).contains(answer) ? Data(#"{"ssoEnabled":true}"#.utf8) : Data()))
    }

    @Test func aRefusedSignInIsThrownInJTKitsFormat() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        await #expect {
            _ = try await client(platform, server: server).get("/pro/v1/scripts", privileges: [.readScripts])
        } throws: { error in
            guard let error = error as? JamfPlatform.APIError, case .signIn(401, _, _) = error.kind else { return false }
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
        _ = try await jamfPro.get("/pro/v1/categories", privileges: [.readCategories])
        _ = try await jamfPro.get("/proclassic/policies/name/Install Office 100%", privileges: [.readPolicies])
        #expect(server.requests.map(\.path) == ["/api/v1/auth/token", "/api/v1/categories", "/JSSResource/policies/name/Install%20Office%20100%25"])
        #expect(server.requests.last?.url.absoluteString == "https://acme.jamfcloud.com/JSSResource/policies/name/Install%20Office%20100%25")
        #expect(server.requests.first?.header("Authorization") == "Basic " + Data("admin:hunter2".utf8).base64EncodedString())
        #expect(server.requests.last?.header("X-Environment-Id") == nil)
    }

    // Settings › Connections › Test Connection: JTKit's testConnection with
    // the preflight's first read checks, worded for the connection.

    @Test func testConnectionChecksTheReadsAndShowsTheVersion() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": .json(200, tokenJSON("tok"))
            case "/pro/v1/jamf-pro-version": .json(200, #"{"version":"11.24.0-t1234"}"#)
            default: .json(200, #"{"totalCount":0,"results":[]}"#)
            }
        }
        let text = try await client(platform, server: server).testConnection(checks: PreflightService.permissionChecks)
        #expect(text == "Connected · Jamf Pro 11.24.0")
        let read = Set(server.requests.map(\.path))
        #expect(PreflightService.permissionChecks.allSatisfy { read.contains($0.path) })
    }

    @Test func testConnectionNamesAMissingJamfProPrivilege() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/api/oauth/token": .json(200, tokenJSON("tok"))
            case "/api/v1/scripts": .json(403, #"{"httpStatus":403}"#)
            default: .json(200, #"{"version":"11.24.0","totalCount":0,"results":[]}"#)
            }
        }
        let configuration = JamfAPIConfiguration(jamfProURL: URL(string: "https://pin.example.invalid")!,
                                                 auth: .apiClient, clientID: "client", clientSecret: "secret")
        await #expect {
            _ = try await client(configuration, server: server).testConnection(checks: PreflightService.permissionChecks)
        } throws: { error in
            guard let shortfall = error as? JamfPlatformClient.PermissionShortfall else { return false }
            return shortfall.errorDescription == "Signed in, but the API client is missing a privilege."
                && shortfall.failureReason?.contains("“\(JamfPro.Privilege.readScripts.rawValue)”") == true
                && shortfall.failureReason?.contains("API Roles and Clients") == true
                && shortfall.failureReason?.contains("Jamf Account") == false
        }
    }

    @Test func testConnectionNamesAMissingPlatformPermission() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": .json(200, tokenJSON("tok"))
            case "/pro/v1/categories": .json(403, #"{"httpStatus":403}"#)
            default: .json(200, #"{"version":"11.24.0","totalCount":0,"results":[]}"#)
            }
        }
        await #expect {
            _ = try await client(platform, server: server).testConnection(checks: PreflightService.permissionChecks)
        } throws: { error in
            guard let shortfall = error as? JamfPlatformClient.PermissionShortfall else { return false }
            return shortfall.errorDescription?.contains("categories:read") == true
                && shortfall.failureReason?.contains("Jamf Account") == true
        }
    }

    @Test func anInvalidJamfProURLSendsNothing() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        var tenant = platformTenant()
        tenant.connection = .jamfPro
        tenant.jamfProURL = "http://not-https.example.com"
        var configuration = JamfAPIConfiguration(tenant: tenant, signInID: "id")
        configuration.secret = { "x" }
        await #expect(throws: JamfAPIError.self) { _ = try await client(configuration, server: server).get("/pro/v1/categories", privileges: [.readCategories]) }
        #expect(server.requests.isEmpty)
    }

    @Test func redirectsToAnotherHostAreRefusedForTheSignInAndRequests() async throws {
        let evil = URL(string: "https://evil.example/collect")!
        let signIn = MockServer { request in
            request.url.host() == "evil.example" ? .json(200, tokenJSON("x")) : .redirect(to: evil)
        }
        await #expect(throws: (any Error).self) { _ = try await client(platform, server: signIn).get("/pro/v1/scripts", privileges: [.readScripts]) }
        #expect(!signIn.requests.contains { $0.url.host() == "evil.example" })

        let request = MockServer { request in
            if request.url.host() == "evil.example" { return .json(200, "{}") }
            return request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .redirect(to: evil)
        }
        let (_, status) = try await client(platform, server: request).get("/pro/v1/scripts", privileges: [.readScripts])
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
            .post("/pro/v1/volume-purchasing-locations", json: ["serviceToken": "vpp-token-value"],
                  privileges: [.createVolumePurchasingLocations])
        let text = log.entries.map(ActivityLogExport.transcript(of:)).joined(separator: "\n")
        #expect(log.entries.contains { $0.category == "Sign-in" })
        #expect(log.entries.contains { $0.category == "API" && $0.status == 500 && $0.connection == "Sandbox" })
        for secret in ["s3cr3t", "tok-secret-value", "vpp-token-value"] {
            #expect(!text.contains(secret))
        }
    }

    /// The Classic API answers in XML unless asked for JSON (as seen on the
    /// Sandbox, 2026-10-26); the answers below are trimmed from that tenant.
    /// The lookup after a failed create reads JSON, so it must ask for it.
    @Test func aFailedCreateIsLookedUpInJSONOnTheClassicAPI() async throws {
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, tokenJSON("tok")) }
            let json = request.header("Accept") == "application/json"
            switch (request.path, json) {
            case ("/proclassic/policies/name/JD%20Repro%20-%20Classic%20lookup", true):
                return .json(200, #"{"policy":{"general":{"id":193,"name":"JD Repro - Classic lookup","enabled":false}}}"#)
            case ("/proclassic/policies/name/JD%20Repro%20-%20Classic%20lookup", false):
                return MockResponse(status: 200, headers: ["Content-Type": "text/xml;charset=utf-8"], body: Data(
                    #"<?xml version="1.0" encoding="UTF-8"?><policy><general><id>193</id><name>JD Repro - Classic lookup</name><enabled>false</enabled></general></policy>"#.utf8))
            case ("/proclassic/patchsoftwaretitles", true):
                return .json(200, #"{"patch_software_titles":[{"name_id":"MicrosoftOutlook2016","source_id":"1","name":"Microsoft Outlook","id":"1"}]}"#)
            case ("/proclassic/patchsoftwaretitles", false):
                return MockResponse(status: 200, headers: ["Content-Type": "text/xml;charset=utf-8"], body: Data(
                    #"<?xml version="1.0" encoding="UTF-8"?><patch_software_titles><size>1</size><patch_software_title><name_id>MicrosoftOutlook2016</name_id><source_id>1</source_id><name>Microsoft Outlook</name><id>1</id></patch_software_title></patch_software_titles>"#.utf8))
            default:
                return .json(404, "{}")
            }
        }
        let jamf = client(platform, server: server)
        let policy = CreateFailureRecovery.Candidate(
            address: "module.cap.jamfplatform_pro_policy.repro", resourceType: "jamfplatform_pro_policy",
            name: "JD Repro - Classic lookup")
        let title = CreateFailureRecovery.Candidate(
            address: "module.cap.jamfplatform_pro_patch_software_title.outlook",
            resourceType: "jamfplatform_pro_patch_software_title", name: "Microsoft Outlook")
        #expect(await TenantDeployService.createdObjectID(for: policy, client: jamf, excluding: []) == "193")
        #expect(await TenantDeployService.createdObjectID(for: title, client: jamf, excluding: []) == "1")
        #expect(await TenantDeployService.createdObjectID(for: policy, client: jamf, excluding: ["193"]) == nil)
    }
}

/// A create that fails with a 500 while Jamf creates the object anyway,
/// from the lookup before the apply to the import file the next preview
/// adopts. The Classic API answers a by-name lookup for a name nobody uses
/// with 404.
@MainActor
@Suite("Failed-create recovery from the lookup before the apply")
struct FailedCreateRecoveryTests {
    private let platform = JamfAPIConfiguration(
        gatewayURL: URL(string: "https://us.api.jamfcloud.com")!, clientID: "client-1",
        clientSecret: "secret", environmentID: environment1)

    /// Planned creates: a policy and a macOS profile on both connection
    /// types, a patch title and an App Installer.
    private static let planJSON = """
    {"format_version":"1.2","resource_changes":[
      {"address":"module.a.jamfplatform_pro_policy.p","type":"jamfplatform_pro_policy","name":"p",
       "change":{"actions":["create"],"before":null,"after":{"name":"JD - Policy"}}},
      {"address":"module.a.jamfplatform_pro_macos_configuration_profile.m","type":"jamfplatform_pro_macos_configuration_profile","name":"m",
       "change":{"actions":["create"],"before":null,"after":{"name":"JD - Profile"}}},
      {"address":"module.b.jamfpro_policy.p","type":"jamfpro_policy","name":"p",
       "change":{"actions":["create"],"before":null,"after":{"general":{"name":"JD - Pro Policy"}}}},
      {"address":"module.b.jamfpro_macos_configuration_profile_plist.m","type":"jamfpro_macos_configuration_profile_plist","name":"m",
       "change":{"actions":["create"],"before":null,"after":{"name":"JD - Pro Profile"}}},
      {"address":"module.c.jamfplatform_pro_patch_software_title.t","type":"jamfplatform_pro_patch_software_title","name":"t",
       "change":{"actions":["create"],"before":null,"after":{"name":"JD - Title"}}},
      {"address":"module.c.jamfplatform_pro_app_installer.i","type":"jamfplatform_pro_app_installer","name":"i",
       "change":{"actions":["create"],"before":null,"after":{"name":"JD - Installer"}}}
    ]}
    """

    /// Jamf's objects by name; empty until the failed apply "creates" them.
    private static let created: [String: String] = [
        "JD - Policy": "11", "JD - Profile": "12", "JD - Pro Policy": "13", "JD - Pro Profile": "14",
        "JD - Title": "15", "JD - Installer": "16",
    ]

    private func plan() throws -> PlanFile {
        try JSONDecoder().decode(PlanFile.self, from: Data(Self.planJSON.utf8))
    }

    /// The 500 the engine reports for every planned create.
    private func diagnostics(_ plan: PlanFile) throws -> [EngineStreamEvent.Diagnostic] {
        try (plan.resourceChanges ?? []).map { change in
            let json = #"{"severity":"error","summary":"Error creating object","detail":"unexpected status 500","address":"\#(change.address)"}"#
            return try JSONDecoder().decode(EngineStreamEvent.Diagnostic.self, from: Data(json.utf8))
        }
    }

    /// A fake Jamf: `exists` says whether the apply has created the objects
    /// yet; `before` answers lookups made before then when set.
    private func server(exists: Locked<Bool>, before: (@Sendable (RecordedRequest) throws -> MockResponse)? = nil) -> MockServer {
        MockServer { request in
            if request.path == "/auth/token" { return .json(200, tokenJSON("tok")) }
            if !exists.value, let before { return try before(request) }
            let objects = exists.value ? Self.created : [:]
            let path = request.path.removingPercentEncoding ?? request.path
            for (prefix, root) in [("/proclassic/policies/name/", "policy"),
                                   ("/proclassic/osxconfigurationprofiles/name/", "os_x_configuration_profile")]
            where path.hasPrefix(prefix) {
                let name = String(path.dropFirst(prefix.count))
                guard let id = objects[name] else { return .json(404, "{}") }
                return .json(200, #"{"\#(root)":{"general":{"id":\#(id),"name":"\#(name)"}}}"#)
            }
            let list = objects.map { #"{"id":"\#($0.value)","name":"\#($0.key)"}"# }.joined(separator: ",")
            switch path {
            case "/proclassic/patchsoftwaretitles": return .json(200, #"{"patch_software_titles":[\#(list)]}"#)
            case "/pro/v1/app-installers/deployments": return .json(200, #"{"results":[\#(list)]}"#)
            default: return .json(404, "{}")
            }
        }
    }

    /// The deploy's recovery steps: look up before the apply, fail every
    /// create with a 500 (Jamf creates the objects anyway), then look the
    /// recoverable ones up again. Returns the import blocks written.
    private func recover(_ server: MockServer, exists: Locked<Bool>) async throws -> [String: String] {
        let jamf = JamfPlatformClient(configuration: platform, activityLog: nil, session: server.session)
        let plan = try plan()
        var before: [String: Set<String>?] = [:]
        for candidate in CreateFailureRecovery.plannedCreates(plan: plan) {
            before[candidate.address] = .some(await TenantDeployService.existingIDsBeforeApply(candidate, client: jamf))
        }
        exists.value = true
        let candidates = TenantDeployService.recoverable(
            CreateFailureRecovery.candidates(diagnostics: try diagnostics(plan), plan: plan), existingBeforeApply: before)
        var found: [String: String] = [:]
        for candidate in candidates {
            if let id = await TenantDeployService.createdObjectID(
                for: candidate, client: jamf, excluding: [], existedBefore: (before[candidate.address] ?? nil) ?? []) {
                found[candidate.address] = id
            }
        }
        // What the next preview reads: an import block per recovered object,
        // so it adopts them instead of planning a second create.
        let text = CreateFailureRecovery.importFile(found.map { (address: $0.key, id: $0.value) })
        var imports: [String: String] = [:]
        for match in text.matches(of: /to = (\S+)\n\s*id = "([^"]+)"/) {
            imports[String(match.1)] = String(match.2)
        }
        return imports
    }

    @Test func policiesAndProfilesNotFoundBeforeTheApplyAreRecovered() async throws {
        let exists = Locked(false)
        let imports = try await recover(server(exists: exists), exists: exists)
        #expect(imports == [
            "module.a.jamfplatform_pro_policy.p": "11",
            "module.a.jamfplatform_pro_macos_configuration_profile.m": "12",
            "module.b.jamfpro_policy.p": "13",
            "module.b.jamfpro_macos_configuration_profile_plist.m": "14",
            "module.c.jamfplatform_pro_patch_software_title.t": "15",
            "module.c.jamfplatform_pro_app_installer.i": "16",
        ])
    }

    @Test func aByNameLookupAnswering404MeansNoObjectHadTheName() async throws {
        let server = server(exists: Locked(false))
        let jamf = JamfPlatformClient(configuration: platform, activityLog: nil, session: server.session)
        let policy = CreateFailureRecovery.Candidate(
            address: "module.a.jamfplatform_pro_policy.p", resourceType: "jamfplatform_pro_policy", name: "JD - Policy")
        #expect(await TenantDeployService.existingIDsBeforeApply(policy, client: jamf) == [])
        // After a failed apply a 404 still means "not found".
        #expect(await TenantDeployService.lookup(policy, client: jamf) == nil)
    }

    @Test(arguments: ["403", "network"])
    func aRefusedOrFailedLookupBeforeTheApplyIsNeverRecovered(_ failure: String) async throws {
        let exists = Locked(false)
        let server = server(exists: exists) { _ in
            if failure == "network" { throw URLError(.notConnectedToInternet) }
            return .json(403, #"{"httpStatus":403}"#)
        }
        #expect(try await recover(server, exists: exists).isEmpty)
    }

    @Test func listLookupsBehaveAsBefore() async throws {
        let jamf = JamfPlatformClient(
            configuration: platform, activityLog: nil, session: server(exists: Locked(false)).session)
        let title = CreateFailureRecovery.Candidate(
            address: "module.c.jamfplatform_pro_patch_software_title.t",
            resourceType: "jamfplatform_pro_patch_software_title", name: "JD - Title")
        let installer = CreateFailureRecovery.Candidate(
            address: "module.c.jamfplatform_pro_app_installer.i",
            resourceType: "jamfplatform_pro_app_installer", name: "JD - Installer")
        #expect(await TenantDeployService.existingIDsBeforeApply(title, client: jamf) == [])
        #expect(await TenantDeployService.existingIDsBeforeApply(installer, client: jamf) == [])

        // A list that answers 404 stays unknown.
        let missing = MockServer { request in
            request.path == "/auth/token" ? .json(200, tokenJSON("tok")) : .json(404, "{}")
        }
        let lost = JamfPlatformClient(configuration: platform, activityLog: nil, session: missing.session)
        #expect(await TenantDeployService.existingIDsBeforeApply(title, client: lost) == nil)
        #expect(await TenantDeployService.existingIDsBeforeApply(installer, client: lost) == nil)
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
            _ = try await client(configuration, server: server).get("/pro/v1/categories", privileges: [.readCategories])
        } throws: { error in
            guard let error = error as? JamfPlatform.APIError, case .invalidEnvironmentID("env-1") = error.kind else { return false }
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
        _ = try await client(configuration, server: server).get("/pro/v1/categories", privileges: [.readCategories])
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
            _ = try await client(server: server).getDecoded(Version.self, path: "/pro/v1/jamf-pro-version", privileges: [])
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
            _ = try await client(server: server).post("/pro/v1/volume-purchasing-locations", json: ["serviceToken": "x"],
                                                privileges: [.createVolumePurchasingLocations])
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

    /// The preflight's Cloud Services Connection row reads `get`'s status:
    /// 2xx, 404 and an error status each as before.
    @Test(arguments: [
        (200, PreflightCheck.Outcome.pass, "Established — the App Catalog is available."),
        (404, .warn, "Not established (HTTP 404). Connect it in Jamf Pro under Settings › Jamf apps, or the App Catalog block won’t be available."),
        (403, .warn, "Not established (HTTP 403). Connect it in Jamf Pro under Settings › Jamf apps, or the App Catalog block won’t be available."),
    ])
    func preflightReadsTheCloudServicesConnectionStatus(_ answer: Int, _ outcome: PreflightCheck.Outcome, _ detail: String) async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": .json(200, tokenJSON("tok"))
            case "/pro/v1/jamf-pro-version": .json(200, #"{"version":"11.33.0"}"#)
            case "/pro/v1/app-installers/titles": .json(answer, #"{"totalCount":0,"results":[]}"#)
            default: .json(200, #"{"totalCount":0,"results":[]}"#)
            }
        }
        let report = await PreflightService.run(client: client(server: server)) { _ in }
        let row = try #require(report.checks.first { $0.id == "csc" })
        #expect(row.outcome == outcome)
        #expect(row.detail == detail)
    }

    /// A refused sign-in is still thrown, so the preflight stops at the
    /// credentials and never reads a status.
    @Test func preflightStopsAtARefusedSignIn() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        let report = await PreflightService.run(client: client(server: server)) { _ in }
        #expect(report.checks.map(\.id) == ["auth"])
        #expect(report.checks.first?.outcome == .fail)
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
                request.queryValue("page-size") == "1"
                    ? .json(200, #"{"totalCount":2,"results":[{"tokenExpirationDate":"2027-05-01"}]}"#)
                    : .json(200, #"{"totalCount":2,"results":[{"tokenExpirationDate":"2027-05-01"},{"tokenExpirationDate":"2026-12-01"}]}"#)
            case "/pro/v1/volume-purchasing-locations":
                request.queryValue("page-size") == "1"
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
            guard let error = error as? JamfPlatform.APIError, case .cannotListEnvironments = error.kind else { return false }
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
    @MainActor func comparesDotSeparatedVersions(candidate: String, installed: String, expected: Bool) {
        // The bundled components use JTKit's comparison, as the app's own update check does.
        #expect(ComponentUpdateChecker.Component(name: "", repository: "", pinned: installed, latest: candidate).hasUpdate
            == expected)
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
