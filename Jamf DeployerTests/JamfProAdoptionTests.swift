import Foundation
import Testing
import JamfDeployerCore
import JTKit
import JTKitTestSupport
@testable import Jamf_Deployer

// ROADMAP step 7: privileges from JTKit's table, wording for direct Jamf Pro
// tenants, JTKit's Jamf Pro page reader and version call, and Classic API
// error pages in the engine's text made readable.

private let jamfProURL = URL(string: "https://acme.jamfcloud.com")!

private func tokenAnswer(_ request: RecordedRequest) -> MockResponse? {
    switch request.path {
    case "/api/oauth/token": .json(200, #"{"access_token":"tok","expires_in":900,"token_type":"Bearer"}"#)
    case "/api/v1/auth/token": .json(200, #"{"token":"user-token","expires":"2099-01-01T00:00:00Z"}"#)
    case "/auth/token": .json(200, #"{"access_token":"tok","expires_in":900,"token_type":"Bearer"}"#)
    default: nil
    }
}

private func jamfPro(_ auth: Tenant.JamfProAuth, server: MockServer) -> JamfPlatformClient {
    JamfPlatformClient(
        configuration: JamfAPIConfiguration(jamfProURL: jamfProURL, auth: auth, clientID: "admin", clientSecret: "hunter2"),
        activityLog: nil, session: server.session)
}

private func platform(server: MockServer) -> JamfPlatformClient {
    JamfPlatformClient(
        configuration: JamfAPIConfiguration(gatewayURL: URL(string: "https://us.api.jamfcloud.com")!, clientID: "client-1",
                                            clientSecret: "secret", environmentID: "6F1C2B3A-4D5E-4F60-8172-93A4B5C6D7E8"),
        activityLog: nil, session: server.session)
}

@MainActor
@Suite("Jamf Pro on JTKit")
struct JamfProAdoptionTests {
    private let forbidden = MockServer { request in
        tokenAnswer(request) ?? .json(403, #"{"httpStatus":403,"errors":[]}"#)
    }

    @Test func aRefusalNamesThePrivilegeOnTheAPIRole() async throws {
        await #expect {
            _ = try await jamfPro(.apiClient, server: forbidden).allPages(
                "/pro/v1/volume-purchasing-locations", as: String.self, privileges: [.readVolumePurchasingLocations])
        } throws: { error in
            error.localizedDescription.contains(
                "The API role is missing the “Read Volume Purchasing Locations” privilege. Add it in Jamf Pro under Settings › API Roles and Clients.")
        }
    }

    @Test func aRefusalNamesThePrivilegeOnTheUserAccount() async throws {
        struct ServerURL: Decodable, Sendable { let url: String? }
        await #expect {
            _ = try await jamfPro(.userAccount, server: forbidden).getDecoded(
                ServerURL.self, path: "/pro/v1/jamf-pro-server-url", privileges: [.readJSSURL])
        } throws: { error in
            let message = error.localizedDescription
            return message.contains(
                "The user account is missing the “Read JSS URL” privilege. Add it in Jamf Pro under Settings › User Accounts and Groups.")
                && !message.contains("API role")
        }
    }

    @Test func aWrongPasswordShowsNoRegionAndNoClientSecret() async throws {
        let server = MockServer { _ in .json(401, #"{"httpStatus":401}"#) }
        await #expect {
            _ = try await jamfPro(.userAccount, server: server).jamfProVersion()
        } throws: { error in
            let message = error.localizedDescription
            return message.contains("Check the username and password.")
                && !message.contains("region") && !message.contains("client secret")
        }
    }

    @Test func aDay0WriteNamesItsPrivilege() async throws {
        await #expect {
            _ = try await jamfPro(.apiClient, server: forbidden).post(
                "/pro/v1/device-enrollments/upload-token", json: ["encodedToken": "x"],
                privileges: [.createDeviceEnrollmentProgramInstances])
        } throws: { error in
            error.localizedDescription.contains("“Create Device Enrollment Program Instances”")
        }
    }

    @Test func aRefusalOnThePlatformAPIStillPointsToJamfAccount() async throws {
        await #expect {
            _ = try await platform(server: forbidden).allPages(
                "/pro/v1/categories", as: String.self, privileges: [.readCategories])
        } throws: { error in
            error.localizedDescription.contains("Jamf Account")
        }
    }

    @Test func thePreflightTellsAUserAccountWhereToAddThePrivilege() {
        let check = PreflightService.permissionChecks[3]
        let user = PreflightService.permissionRow(check, .missingPermission, server: .jamfPro, signIn: .usernamePassword)
        #expect(user.detail == "Not allowed. Add the “Read Volume Purchasing Locations” privilege to the user account in Jamf Pro under Settings › User Accounts and Groups.")
        let client = PreflightService.permissionRow(check, .missingPermission, server: .jamfPro, signIn: .apiClient)
        #expect(client.detail == "Not allowed. Add the “Read Volume Purchasing Locations” privilege to the API role in Jamf Pro under Settings › API Roles and Clients.")
        let gateway = PreflightService.permissionRow(check, .missingPermission, server: .platformAPI)
        #expect(gateway.detail == "Not allowed. Add the “volume-purchasing-locations:read” permission to the API integration in Jamf Account.")
    }

    @Test func thePreflightAndTheWizardTakeTheirPrivilegesFromJTKit() {
        let expected: [JamfPro.Privilege] = [.readCategories, .readScripts, .readDeviceEnrollmentProgramInstances,
                                              .readVolumePurchasingLocations]
        #expect(PreflightService.jamfProPrivileges == expected.map(\.rawValue))
        #expect(PreflightService.jamfProPrivileges == ["Read Categories", "Read Scripts",
                                                       "Read Device Enrollment Program Instances",
                                                       "Read Volume Purchasing Locations"])
    }

    @Test func theLookupsAfterAFailedCreateNameTheirPrivileges() {
        func privileges(_ type: String) -> [JamfPro.Privilege] {
            TenantDeployService.lookupPrivileges(for: CreateFailureRecovery.Candidate(address: "a", resourceType: type, name: "N"))
        }
        #expect(privileges("jamfplatform_pro_policy") == [.readPolicies])
        #expect(privileges("jamfpro_policy") == [.readPolicies])
        #expect(privileges("jamfpro_macos_configuration_profile_plist") == [.readMacOSConfigurationProfiles])
        #expect(privileges("jamfplatform_pro_patch_software_title") == [.readPatchManagementSoftwareTitles])
        // Jamf Pro has no App Installer privilege
        #expect(privileges("jamfpro_app_installer").isEmpty)
    }

    @Test func listsAreReadToTheLastPage() async throws {
        let server = MockServer { request in
            if let token = tokenAnswer(request) { return token }
            let page = request.queryValue("page") == "1" ? 1 : 0
            return page == 0
                ? .json(200, #"{"totalCount":3,"results":[{"id":"1","name":"B"},{"id":"2","name":"A"}]}"#)
                : .json(200, #"{"totalCount":3,"results":[{"id":"3","name":"C"}]}"#)
        }
        struct Item: Decodable, Sendable { let id: String; let name: String }
        let items = try await jamfPro(.apiClient, server: server).allPages(
            "/pro/v1/categories", as: Item.self, pageSize: 2, privileges: [.readCategories])
        #expect(items.map(\.id) == ["1", "2", "3"])
        let lists = server.requests.filter { $0.path == "/api/v1/categories" }
        #expect(lists.count == 2)
        #expect(lists.allSatisfy { $0.queryValue("page-size") == "2" })
    }

    @Test func aListWithoutResultsIsAnErrorNotAnEmptyList() async throws {
        let server = MockServer { request in tokenAnswer(request) ?? .json(200, #"{"totalCount":2}"#) }
        await #expect(throws: (any Error).self) {
            _ = try await jamfPro(.apiClient, server: server).allPages(
                "/pro/v1/volume-purchasing-locations", as: String.self, privileges: [.readVolumePurchasingLocations])
        }
    }

    @Test func theExpiryIsTheFirstOverEveryPage() async throws {
        let server = MockServer { request in
            if let token = tokenAnswer(request) { return token }
            let page = request.queryValue("page") == "1" ? 1 : 0
            let full = (0..<100).map { _ in #"{"tokenExpirationDate":"2028-01-01"}"# }.joined(separator: ",")
            return page == 0
                ? .json(200, #"{"totalCount":101,"results":[\#(full)]}"#)
                : .json(200, #"{"totalCount":101,"results":[{"tokenExpirationDate":"2026-11-30"}]}"#)
        }
        // before step 7 only the first page was read
        #expect(try await PreflightService.adeTokenExpiry(client: jamfPro(.apiClient, server: server)) == "2026-11-30")
    }

    @Test func theVersionIsReadWithJTKitsCall() async throws {
        let server = MockServer { request in tokenAnswer(request) ?? .json(200, #"{"version":"11.33.1-t1792501724838"}"#) }
        #expect(try await jamfPro(.userAccount, server: server).jamfProVersion() == "11.33.1-t1792501724838")
        #expect(server.requests.last?.path == "/api/v1/jamf-pro-version")
    }

    @Test func theSignInMessageFitsTheConnection() {
        let gateway = JamfAPIError.notAuthenticated("no client secret saved", flavor: .platform).errorDescription ?? ""
        #expect(gateway == "Jamf did not accept the credentials. Check the client ID, client secret and region. (no client secret saved)")

        let client = JamfAPIError.notAuthenticated("no client secret saved", flavor: .jamfProAPIClient).errorDescription ?? ""
        #expect(client == "Jamf Pro did not accept the credentials. Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients. (no client secret saved)")

        let user = JamfAPIError.notAuthenticated("no password saved", flavor: .jamfProUser).errorDescription ?? ""
        #expect(user == "Jamf Pro did not accept the credentials. Check the username and password. (no password saved)")

        for text in [client, user, JamfAPIError.invalidInstanceURL.errorDescription ?? ""] {
            #expect(!text.contains("region") && !text.contains("Jamf Account"))
        }
        #expect(!user.contains("client secret"))
    }

    @Test func aSavedTenantGetsTheMessageForItsConnection() throws {
        var tenant = Tenant(name: "Acme", region: .us, clientID: "admin", environmentID: nil, isProduction: false)
        tenant.connection = .jamfPro
        tenant.jamfProURL = "https://acme.jamfcloud.com"
        tenant.jamfProAuth = .userAccount
        #expect(tenant.errorConnection == .jamfProUser)
        tenant.jamfProAuth = .apiClient
        #expect(tenant.errorConnection == .jamfProAPIClient)
        tenant.connection = .platform
        #expect(tenant.errorConnection == .platform)
    }
}

@Suite("Classic API error pages in the engine's text")
struct EngineErrorPageTests {
    /// Made up: a Classic API HTML error page quoting the XML it was sent,
    /// password included, the way Jamf Pro's 409 pages repeat the request.
    private let htmlPage = """
        <html><head><title>Status page</title></head><body><p>Conflict</p>\
        <p>Error: Problem with field &lt;password&gt;Wifi-Pa55&lt;/password&gt;</p>\
        <p>You can get technical details here.</p></body></html>
        """
    private let xmlPage = #"<?xml version="1.0" encoding="UTF-8"?><error><message>Unable to save</message><password>Wifi-Pa55</password></error>"#

    @Test func anHTMLPageReadsAsItsMessageWithoutThePassword() {
        let text = "Error creating policy: status 409 Conflict: \(htmlPage) (attempt 1)"
        let readable = EngineOutputCleaner.readableErrorPages(in: text)
        #expect(readable.hasPrefix("Error creating policy: status 409 Conflict: Conflict – Error: Problem with field"))
        #expect(readable.hasSuffix(" (attempt 1)"))
        #expect(!readable.contains("Wifi-Pa55"))
        #expect(!readable.contains("<html") && !readable.contains("technical details"))
    }

    @Test func anXMLErrorReadsAsItsMessageWithoutThePassword() {
        let readable = EngineOutputCleaner.readableErrorPages(in: "status 400: \(xmlPage)")
        #expect(readable.hasPrefix("status 400: Unable to save"))
        #expect(!readable.contains("Wifi-Pa55"))
        #expect(!readable.contains("<error"))
    }

    @Test func aDiagnosticShowsTheMessage() throws {
        let json: [String: Any] = ["severity": "error", "summary": "Error creating Jamf Pro policy",
                                   "detail": "API request failed with status 409: \(htmlPage)",
                                   "address": "module.a.jamfpro_policy.b"]
        let diagnostic = try JSONDecoder().decode(EngineStreamEvent.Diagnostic.self,
                                                  from: JSONSerialization.data(withJSONObject: json))
        let readable = EngineOutputCleaner.readableErrorPages(in: diagnostic)
        #expect(readable.summary == "Error creating Jamf Pro policy")
        #expect(readable.detail?.hasPrefix("API request failed with status 409: Conflict – Error:") == true)
        #expect(readable.detail?.contains("Wifi-Pa55") == false)
        #expect(readable.address == "module.a.jamfpro_policy.b")
    }

    @Test func theHistoryLogHoldsTheCleanedText() throws {
        let event: [String: Any] = [
            "@level": "error", "type": "diagnostic",
            "diagnostic": ["severity": "error", "summary": "Error creating Jamf Pro policy",
                           "detail": "API request failed with status 409: \(htmlPage)"],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        let log = EngineOutputCleaner.cleanedLog([line, "Initializing the backend..."])
        #expect(!log.contains("Wifi-Pa55"))
        #expect(!log.contains("<html"))
        let first = try #require(log.split(separator: "\n").first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let detail = try #require((object["diagnostic"] as? [String: Any])?["detail"] as? String)
        #expect(detail.hasPrefix("API request failed with status 409: Conflict – Error: Problem with field"))
        #expect(log.hasSuffix("\nInitializing the backend..."))
    }

    @Test func textWithoutAnErrorPageStaysExactlyAsItWas() {
        for text in [
            "Error: <html> is not a valid name",
            #"Error creating profile: <?xml version="1.0"?><plist><dict/></plist>"#,
            "jamfpro_policy.cleanup: Creating...",
            "status 500 Internal Server Error",
        ] {
            #expect(EngineOutputCleaner.readableErrorPages(in: text) == text)
        }
        let line = #"{"@level":"info","@message":"jamfpro_script.cleanup: Creating...","type":"apply_start"}"#
        #expect(EngineOutputCleaner.cleanedLog([line]) == line)
    }
}
