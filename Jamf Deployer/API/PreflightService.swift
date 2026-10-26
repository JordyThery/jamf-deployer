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
    /// by JTKit: the Platform permission, and the Jamf Pro API role privilege
    /// for Jamf Pro API connections.
    static let permissionChecks: [JamfPlatform.PermissionCheck] = [
        .init("Read categories", path: "/pro/v1/categories", permission: "categories:read",
              jamfProPrivilege: "Read Categories"),
        .init("Read scripts", path: "/pro/v1/scripts", permission: "scripts:read",
              jamfProPrivilege: "Read Scripts"),
        .init("Read Automated Device Enrollment", path: adePath, permission: "device-enrollment-program-instances:read",
              jamfProPrivilege: "Read Device Enrollment Program Instances"),
        .init("Read volume purchasing", path: vppPath, permission: "volume-purchasing-locations:read",
              jamfProPrivilege: "Read Volume Purchasing Locations"),
    ]

    private static let adePath = "/pro/v1/device-enrollments"
    private static let vppPath = "/pro/v1/volume-purchasing-locations"

    static func run(
        client: JamfPlatformClient,
        connection: ConnectionKind = .platform,
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
            struct Version: Decodable { let version: String }
            let version = try await client.getDecoded(Version.self, path: "/pro/v1/jamf-pro-version").version
            snapshot.jamfProVersion = version
            await record(PreflightCheck(
                id: "auth", title: "Credentials",
                outcome: .pass,
                detail: isJamfPro ? "Signed in to the Jamf Pro API." : "Signed in to the Jamf Platform gateway."
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
                    ?? "Jamf did not accept the credentials."
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
                return permissionRow(check, result, server: client.server)
            }
        } catch {
            checks = checksBefore + permissionChecks.map {
                PreflightCheck(id: $0.path, title: $0.name, outcome: .warn,
                               detail: "Could not check: \(error.localizedDescription)")
            }
        }
        await publish()

        // Token expiry dates for the dashboard, from the whole lists: the
        // first to expire of every ADE instance and volume purchasing location.
        await readTokenExpiry(client: client, ade: allowed.contains(adePath), vpp: allowed.contains(vppPath),
                              into: &snapshot)

        // 3. Cloud Services Connection (needed for the App Catalog block,
        //    which Jamf Pro API connections cannot use).
        if !isJamfPro { do {
            let (_, status) = try await client.get(
                "/pro/v1/app-installers/titles",
                query: [URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "page-size", value: "1")]
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
                    detail: "Not established (HTTP \(status)). Connect it in Jamf Pro under Settings → Jamf apps, or the App Catalog block won't be available."
                ))
            }
        } catch {
            await record(PreflightCheck(
                id: "csc", title: "Cloud Services Connection",
                outcome: .warn, detail: "Could not check: \(error.localizedDescription)"
            ))
        } }

        // 4. Existing content: decides whether to suggest Adopt first.
        do {
            struct Page: Decodable { let totalCount: Int }
            async let categories = client.getDecoded(Page.self, path: "/pro/v1/categories", query: [URLQueryItem(name: "page-size", value: "1")])
            async let scripts = client.getDecoded(Page.self, path: "/pro/v1/scripts", query: [URLQueryItem(name: "page-size", value: "1")])
            let total = try await categories.totalCount + scripts.totalCount
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
                outcome: .warn, detail: "Could not check: \(error.localizedDescription)"
            ))
        }

        snapshot.allGreen = checks.allSatisfy { $0.outcome == .pass }
        return PreflightReport(checks: checks, snapshot: snapshot)
    }

    /// One permission check's row: only a 403 is "Not allowed".
    static func permissionRow(
        _ check: JamfPlatform.PermissionCheck,
        _ result: JamfPlatform.PermissionResult,
        server: JamfPlatform.Server
    ) -> PreflightCheck {
        let (outcome, detail): (PreflightCheck.Outcome, String) = switch result {
        case .allowed: (.pass, "Allowed.")
        case .missingPermission: (.fail, "Not allowed. \(check.hint(on: server))")
        case .notFound: (.warn, "Could not check: not found (HTTP 404).")
        case .failed(let status): (.warn, "Could not check: unexpected answer (HTTP \(status)).")
        case .unreachable(let message): (.warn, "Could not check: \(message)")
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
        struct ADEPage: Decodable, Sendable {
            struct Instance: Decodable, Sendable { let tokenExpirationDate: String? }
            let results: [Instance]
        }
        struct VPPPage: Decodable, Sendable {
            struct Location: Decodable, Sendable { let tokenExpiration: String? }
            let results: [Location]
        }
        if ade, let page = try? await client.getDecoded(ADEPage.self, path: adePath) {
            snapshot.adeTokenExpiration = page.results.compactMap(\.tokenExpirationDate).min()
        }
        if vpp, let page = try? await client.getDecoded(VPPPage.self, path: vppPath) {
            snapshot.vppTokenExpiration = page.results.compactMap(\.tokenExpiration).min()
        }
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
