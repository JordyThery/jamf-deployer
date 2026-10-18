import Foundation
import DeployerKit

/// One Day 0 step with its detected state.
nonisolated struct Day0Step: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case done(detail: String)
        case pending(detail: String)
        case info(detail: String)
        case skipped
        case unknown(detail: String)
    }

    var id: String
    var title: String
    var state: State
}

/// Day 0 setup: the tenant groundwork that lives outside the deployment
/// engine because it carries Apple tokens and secrets that renew yearly
/// (they would otherwise show up as constant drift). All direct API.
@Observable
final class Day0Service {
    private let activityLog: ActivityLog

    init(activityLog: ActivityLog) {
        self.activityLog = activityLog
    }

    private(set) var steps: [Day0Step] = []
    private(set) var jamfProURL: URL?
    private(set) var isDetecting = false

    private func client(for tenant: Tenant) throws -> JamfPlatformClient {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            throw TenantDeployService.DeployError.missingCredentials
        }
        return JamfPlatformClient(
            configuration: JamfAPIConfiguration(tenant: tenant, clientSecret: secret),
            activityLog: activityLog
        )
    }

    // MARK: Detection

    func detect(tenant: Tenant) async {
        isDetecting = true
        defer { isDetecting = false }
        guard let client = try? client(for: tenant) else {
            steps = [Day0Step(
                id: "credentials", title: "Stored credentials",
                state: .pending(detail: "The tenant's client secret is missing from the Keychain.")
            )]
            return
        }

        var detected: [Day0Step] = []

        func add(_ id: String, _ title: String, _ state: Day0Step.State) {
            if tenant.day0.skippedSteps.contains(id), case .pending = state {
                detected.append(Day0Step(id: id, title: title, state: .skipped))
            } else {
                detected.append(Day0Step(id: id, title: title, state: state))
            }
        }

        // Jamf Pro URL for deep links.
        nonisolated struct ServerURL: Decodable, Sendable { let url: String? }
        if let server = try? await client.getDecoded(ServerURL.self, path: "/pro/v1/jamf-pro-server-url"),
           let raw = server.url, let url = URL(string: raw) {
            jamfProURL = url
        }

        // APNs: no public read endpoint — manually confirmed.
        if let date = tenant.day0.apnsConfirmedDate {
            add("apns", "Apple Push Notification certificate",
                .done(detail: "Confirmed \(date.formatted(date: .abbreviated, time: .omitted)). Renew it yearly with the same Apple Account."))
        } else {
            add("apns", "Apple Push Notification certificate",
                .pending(detail: "Required before any device can enroll. Set it up in Jamf Pro with an organization Apple Account, then mark it done here."))
        }

        // ADE.
        nonisolated struct ADEPage: Decodable, Sendable {
            nonisolated struct Instance: Decodable, Sendable {
                let name: String
                let tokenExpirationDate: String?
            }
            let totalCount: Int
            let results: [Instance]
        }
        if let page = try? await client.getDecoded(ADEPage.self, path: "/pro/v1/device-enrollments") {
            if let instance = page.results.first {
                add("ade", "Automated Device Enrollment",
                    .done(detail: "“\(instance.name)” connected\(instance.tokenExpirationDate.map { ", token expires \($0)" } ?? "")."))
            } else {
                add("ade", "Automated Device Enrollment",
                    .pending(detail: "Connect Apple Business Manager so new devices enroll automatically: download the public key, create the MDM server in ABM, upload its token here."))
            }
        } else {
            add("ade", "Automated Device Enrollment", .unknown(detail: "Could not check."))
        }

        // VPP.
        nonisolated struct VPPPage: Decodable, Sendable {
            nonisolated struct Location: Decodable, Sendable {
                let name: String?
                let tokenExpiration: String?
            }
            let totalCount: Int
            let results: [Location]
        }
        if let page = try? await client.getDecoded(VPPPage.self, path: "/pro/v1/volume-purchasing-locations") {
            if let location = page.results.first {
                add("vpp", "Apps and Books (volume purchasing)",
                    .done(detail: "“\(location.name ?? "Location")” connected\(location.tokenExpiration.map { ", token expires \($0.prefix(10))" } ?? "")."))
            } else {
                add("vpp", "Apps and Books (volume purchasing)",
                    .pending(detail: "Upload the location token (.vpptoken) from Apple Business Manager → Payments and Billing."))
            }
        } else {
            add("vpp", "Apps and Books (volume purchasing)", .unknown(detail: "Could not check."))
        }

        // Self Service branding.
        nonisolated struct BrandingPage: Decodable, Sendable { let totalCount: Int }
        if let page = try? await client.getDecoded(BrandingPage.self, path: "/pro/v1/self-service/branding/macos") {
            add("branding", "Self Service branding",
                page.totalCount > 0
                    ? .done(detail: "Branding is configured.")
                    : .pending(detail: "Give Self Service your organization's name before users first see it."))
        } else {
            add("branding", "Self Service branding", .unknown(detail: "Could not check."))
        }

        // SSO.
        let ssoState: Day0Step.State
        if let (data, status) = try? await client.get("/pro/v3/sso"), status == 200,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let enabled = (object["ssoEnabled"] as? Bool) ?? (object["enabled"] as? Bool)
            switch enabled {
            case true: ssoState = .done(detail: "Single sign-on is enabled.")
            case false: ssoState = .info(detail: "Not enabled. Optional — configure it in Jamf Pro's SSO settings when your identity provider is ready.")
            default: ssoState = .info(detail: "Configured state could not be read. Review it in Jamf Pro's SSO settings.")
            }
        } else {
            ssoState = .unknown(detail: "Could not check.")
        }
        add("sso", "Single sign-on", ssoState)

        // Jamf Protect link.
        if let (data, status) = try? await client.get("/pro/v1/jamf-protect") {
            if status == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["registrationId"] != nil {
                add("protect", "Jamf Protect link",
                    .done(detail: "Registered with \(object["protectUrl"] as? String ?? "Jamf Protect")."))
            } else {
                add("protect", "Jamf Protect link",
                    .pending(detail: "Optional. Link Jamf Protect so its deployment and plans sync with Jamf Pro."))
            }
        } else {
            add("protect", "Jamf Protect link", .unknown(detail: "Could not check."))
        }

        // Cloud Services Connection (status only).
        if let (_, status) = try? await client.get(
            "/pro/v1/app-installers/titles",
            query: [URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "page-size", value: "1")]
        ) {
            add("csc", "Cloud Services Connection",
                status == 200
                    ? .done(detail: "Established — the App Catalog works.")
                    : .pending(detail: "Connect it in Jamf Pro under Settings → Jamf apps; the App Catalog block needs it."))
        } else {
            add("csc", "Cloud Services Connection", .unknown(detail: "Could not check."))
        }

        steps = detected
    }

    // MARK: Actions

    /// The ADE public key the user uploads to Apple Business Manager.
    func downloadADEPublicKey(tenant: Tenant) async throws -> Data {
        let client = try client(for: tenant)
        let (data, status) = try await client.getRaw("/pro/v1/device-enrollments/public-key", accept: "application/x-pem-file")
        guard status == 200 else { throw JamfAPIError.http(status: status, path: "/v1/device-enrollments/public-key") }
        return data
    }

    /// Uploads the .p7m server token downloaded from Apple Business Manager.
    func uploadADEToken(tenant: Tenant, tokenFile: Data, name: String) async throws {
        let client = try client(for: tenant)
        let (_, status) = try await client.post("/pro/v1/device-enrollments/upload-token", json: [
            "tokenFileName": name,
            "encodedToken": tokenFile.base64EncodedString(),
        ])
        guard status == 200 || status == 201 else {
            throw JamfAPIError.http(status: status, path: "/v1/device-enrollments/upload-token")
        }
    }

    /// Uploads the .vpptoken from Apple Business Manager. The file content
    /// is already the base64 service token.
    func uploadVPPToken(tenant: Tenant, tokenFile: Data, name: String) async throws {
        let client = try client(for: tenant)
        let serviceToken = String(decoding: tokenFile, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, status) = try await client.post("/pro/v1/volume-purchasing-locations", json: [
            "name": name,
            "serviceToken": serviceToken,
        ])
        guard status == 200 || status == 201 else {
            throw JamfAPIError.http(status: status, path: "/v1/volume-purchasing-locations")
        }
    }

    /// Creates a minimal macOS Self Service branding configuration.
    func createBranding(tenant: Tenant, brandingName: String) async throws {
        let client = try client(for: tenant)
        let (_, status) = try await client.post("/pro/v1/self-service/branding/macos", json: [
            "applicationName": brandingName,
            "brandingName": brandingName,
            "homeHeading": "Welcome to \(brandingName)",
        ])
        guard status == 200 || status == 201 else {
            throw JamfAPIError.http(status: status, path: "/v1/self-service/branding/macos")
        }
    }

    /// Links Jamf Pro to a Jamf Protect tenant.
    func registerProtect(tenant: Tenant, protectURL: String, clientID: String, password: String) async throws {
        let client = try client(for: tenant)
        var graphqlURL = protectURL
        if !graphqlURL.hasSuffix("/graphql") {
            graphqlURL = graphqlURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/graphql"
        }
        let (_, status) = try await client.post("/pro/v1/jamf-protect/register", json: [
            "protectUrl": graphqlURL,
            "clientId": clientID,
            "password": password,
        ])
        guard status == 200 || status == 201 else {
            throw JamfAPIError.http(status: status, path: "/v1/jamf-protect/register")
        }
    }
}
