import Foundation
import JamfDeployerCore
import JTKit

/// One green/amber/red row in the preflight list, with a fix-it hint.
nonisolated struct PreflightCheck: Identifiable, Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case pass
        case warn
        case fail
        case running
        case pending
    }

    var id: String
    var title: String
    var outcome: Outcome
    /// What the user sees under the title: a result or a fix-it hint.
    var detail: String
}

/// The outcome of a full preflight run.
nonisolated struct PreflightReport: Sendable {
    var checks: [PreflightCheck]
    var snapshot: PreflightSnapshot
}

/// Runs the connect-a-tenant preflight against the Platform gateway.
/// Everything is a read; nothing in the tenant is changed.
nonisolated enum PreflightService {
    static let minimumJamfProVersion = (major: 11, minor: 31)

    /// Read-only checks for the permissions the app needs from day one, run
    /// by JTKit: the Platform permission, and for Jamf Pro connections the
    /// privilege from JTKit's table.
    static let permissionChecks: [JamfPlatform.PermissionCheck] = [
        .init("Read categories", path: "/pro/v1/categories", permission: "categories:read",
              jamfProPrivilege: JamfPro.Privilege.readCategories.rawValue),
        .init("Read scripts", path: "/pro/v1/scripts", permission: "scripts:read",
              jamfProPrivilege: JamfPro.Privilege.readScripts.rawValue),
        .init("Read Automated Device Enrollment", path: adePath, permission: "device-enrollment-program-instances:read",
              jamfProPrivilege: JamfPro.Privilege.readDeviceEnrollmentProgramInstances.rawValue),
        .init("Read Apps and Books", path: vppPath, permission: "volume-purchasing-locations:read",
              jamfProPrivilege: JamfPro.Privilege.readVolumePurchasingLocations.rawValue),
    ]

    /// The Jamf Pro privileges for connecting, as the wizard lists them.
    static var jamfProPrivileges: [String] { permissionChecks.compactMap(\.jamfProPrivilege) }

    private static let adePath = "/pro/v1/device-enrollments"
    private static let vppPath = "/pro/v1/volume-purchasing-locations"

    /// - Parameter blockPermissions: what the tenant's selected blocks list;
    ///   permissions no read can show are named in a row of their own.
    static func run(
        client: JamfPlatformClient,
        connection: ConnectionKind = .platform,
        blockPermissions: Set<String> = [],
        onProgress: @MainActor @Sendable ([PreflightCheck]) -> Void
    ) async -> PreflightReport {
        let isJamfPro = connection == .jamfPro
        var checks: [PreflightCheck] = []
        var snapshot = PreflightSnapshot(date: .now, allGreen: false)

        func publish() async {
            let current = checks
            await onProgress(current)
        }

        func record(_ check: PreflightCheck) async {
            checks.append(check)
            await publish()
        }

        // 1. Credentials + Jamf Pro version in one probe.
        do {
            let version = try await client.jamfProVersion()
            snapshot.jamfProVersion = version
            await record(PreflightCheck(
                id: "auth", title: "Credentials",
                outcome: .pass,
                detail: isJamfPro ? "Signed in to the Jamf Pro API." : "Signed in to the Jamf Platform API."
            ))
            if meetsMinimumVersion(version) {
                await record(PreflightCheck(
                    id: "version", title: "Jamf Pro version",
                    outcome: .pass,
                    detail: "Version \(displayVersion(version))."
                ))
            } else {
                await record(PreflightCheck(
                    id: "version", title: "Jamf Pro version",
                    outcome: .warn,
                    detail: "Version \(displayVersion(version)) is below 11.31. Some building blocks may not deploy — update the tenant when possible."
                ))
            }
        } catch {
            await record(PreflightCheck(
                id: "auth", title: "Credentials",
                outcome: .fail,
                detail: (error as? LocalizedError)?.errorDescription
                    ?? (!isJamfPro ? "Jamf didn’t accept the sign-in. Check the client ID, client secret and region."
                        : client.signIn == .usernamePassword
                            ? "Jamf Pro didn’t accept the sign-in. Check the username and password."
                            : "Jamf Pro didn’t accept the sign-in. Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients.")
            ))
            return PreflightReport(checks: checks, snapshot: snapshot)
        }

        // 2. Permission checks, 4 at a time. Shown as running until they
        //    are all back.
        let checksBefore = checks
        checks += permissionChecks.map {
            PreflightCheck(id: $0.path, title: $0.name, outcome: .running, detail: "Checking…")
        }
        await publish()
        var allowed: Set<String> = []
        do {
            let results = try await client.checkPermissions(permissionChecks)
            checks = checksBefore + results.map { check, result in
                if result == .allowed { allowed.insert(check.path) }
                return permissionRow(check, result, server: client.server, signIn: client.signIn)
            }
        } catch {
            checks = checksBefore + permissionChecks.map {
                PreflightCheck(id: $0.path, title: $0.name, outcome: .warn,
                               detail: "Couldn’t check: \(error.localizedDescription)")
            }
        }
        checks += blockPermissionRows(blockPermissions, connection: connection)
        await publish()

        // Token expiry dates for the dashboard, from the whole lists: the
        // first to expire of every ADE instance and volume purchasing location.
        await readTokenExpiry(client: client, ade: allowed.contains(adePath), vpp: allowed.contains(vppPath),
                              into: &snapshot)

        // 3. Cloud Services Connection (needed for the App Catalog block).
        //    Checked on Jamf Platform API tenants only: App Catalog also
        //    deploys over the Jamf Pro API (its jamfpro/ module), but the
        //    check's endpoint needs the Platform gateway.
        if !isJamfPro { do {
            // Platform API only: no Jamf Pro privilege.
            let (_, status) = try await client.get(
                "/pro/v1/app-installers/titles",
                query: [URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "page-size", value: "1")],
                privileges: []
            )
            if status == 200 {
                await record(PreflightCheck(
                    id: "csc", title: "Cloud Services Connection",
                    outcome: .pass, detail: "Established — the App Catalog is available."
                ))
            } else {
                await record(PreflightCheck(
                    id: "csc", title: "Cloud Services Connection",
                    outcome: .warn,
                    detail: "Not established (HTTP \(status)). Connect it in Jamf Pro under Settings › Jamf apps, or the App Catalog block won’t be available."
                ))
            }
        } catch {
            await record(PreflightCheck(
                id: "csc", title: "Cloud Services Connection",
                outcome: .warn, detail: "Couldn’t check: \(error.localizedDescription)"
            ))
        } }

        // 4. Existing content: decides whether to suggest Adopt first.
        do {
            async let categories = client.page("/pro/v1/categories", pageSize: 1, privileges: [.readCategories]) { _ in () }
            async let scripts = client.page("/pro/v1/scripts", pageSize: 1, privileges: [.readScripts]) { _ in () }
            let total = try await count(categories) + count(scripts)
            snapshot.tenantHasContent = total > 0
            if total > 0 {
                await record(PreflightCheck(
                    id: "content", title: "Existing configuration",
                    outcome: .warn,
                    detail: "This tenant already has configuration (\(total) categories and scripts). You can adopt it later instead of recreating objects."
                ))
            } else {
                await record(PreflightCheck(
                    id: "content", title: "Existing configuration",
                    outcome: .pass,
                    detail: "The tenant looks empty — a clean start."
                ))
            }
        } catch {
            await record(PreflightCheck(
                id: "content", title: "Existing configuration",
                outcome: .warn, detail: "Couldn’t check: \(error.localizedDescription)"
            ))
        }

        snapshot.allGreen = checks.allSatisfy { $0.outcome == .pass }
        return PreflightReport(checks: checks, snapshot: snapshot)
    }

    /// A list's total: `totalCount`, or what the page holds when Jamf
    /// leaves it out.
    private static func count(_ page: JamfPlatform.Page<Void>) -> Int {
        page.totalCount ?? page.results.count + page.unreadableCount
    }

    /// Rows for block permissions a read-only check can't show: a package
    /// upload to Jamf Cloud's storage (jamfplatform 1.7.2) needs a create
    /// permission that only an upload proves. Named, so it's granted before
    /// the deploy instead of failing in it.
    static func blockPermissionRows(_ permissions: Set<String>, connection: ConnectionKind) -> [PreflightCheck] {
        guard connection == .platform, permissions.contains(BlockCapture.jamfCloudUploadPermission) else { return [] }
        return [PreflightCheck(
            id: "jcds-upload", title: "Upload packages to Jamf Cloud",
            outcome: .warn,
            detail: "A selected block uploads a package file. Grant \(BlockCapture.jamfCloudUploadPermission) to the API integration in Jamf Account: it can’t be checked before a deploy.")]
    }

    /// One permission check's row: only a 403 is "Not allowed". On a Jamf
    /// Pro connection the hint names the privilege, and where to add it:
    /// the API role, or the user account for a username and password.
    static func permissionRow(
        _ check: JamfPlatform.PermissionCheck,
        _ result: JamfPlatform.PermissionResult,
        server: JamfPlatform.Server,
        signIn: SignInMethod = .apiClient
    ) -> PreflightCheck {
        let hint = JamfPlatform.PermissionCheck.hint(for: [check], on: server, signIn: signIn) ?? check.hint(on: server)
        let (outcome, detail): (PreflightCheck.Outcome, String) = switch result {
        case .allowed: (.pass, "Allowed.")
        case .missingPermission: (.fail, "Not allowed. \(hint)")
        case .notFound: (.warn, "Couldn’t check: not found (HTTP 404).")
        case .failed(let status): (.warn, "Couldn’t check: unexpected answer (HTTP \(status)).")
        case .unreachable(let message): (.warn, "Couldn’t check: \(message)")
        }
        return PreflightCheck(id: check.path, title: check.name, outcome: outcome, detail: detail)
    }

    /// Reads the ADE instances and volume purchasing locations the checks
    /// allowed, so preflight doubles as the first token-expiry read. A list
    /// that can't be read leaves its date empty.
    static func readTokenExpiry(
        client: JamfPlatformClient,
        ade: Bool,
        vpp: Bool,
        into snapshot: inout PreflightSnapshot
    ) async {
        if ade, let expiry = try? await adeTokenExpiry(client: client) {
            snapshot.adeTokenExpiration = expiry
        }
        if vpp, let expiry = try? await vppTokenExpiry(client: client) {
            snapshot.vppTokenExpiration = expiry
        }
    }

    /// The first ADE token to expire, over every instance (all pages).
    static func adeTokenExpiry(client: JamfPlatformClient) async throws -> String? {
        struct Instance: Decodable, Sendable { let tokenExpirationDate: String? }
        return try await client.allPages(adePath, as: Instance.self, privileges: [.readDeviceEnrollmentProgramInstances])
            .compactMap(\.tokenExpirationDate).min()
    }

    /// The first volume purchasing token to expire, over every location.
    static func vppTokenExpiry(client: JamfPlatformClient) async throws -> String? {
        struct Location: Decodable, Sendable { let tokenExpiration: String? }
        return try await client.allPages(vppPath, as: Location.self, privileges: [.readVolumePurchasingLocations])
            .compactMap(\.tokenExpiration).min()
    }

    static func meetsMinimumVersion(_ raw: String) -> Bool {
        let parts = displayVersion(raw).split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        if parts[0] != minimumJamfProVersion.major {
            return parts[0] > minimumJamfProVersion.major
        }
        return parts[1] >= minimumJamfProVersion.minor
    }

    /// "11.33.0-t1790886091046" → "11.33.0"
    static func displayVersion(_ raw: String) -> String {
        String(raw.split(separator: "-").first ?? Substring(raw))
    }
}
