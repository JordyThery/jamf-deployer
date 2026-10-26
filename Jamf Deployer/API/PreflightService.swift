import Foundation
import JamfDeployerCore

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

    /// Dry-read probes for the permissions the app needs from day one.
    /// Each tuple: title, path, required permission shown in the hint.
    /// `permission` is the Platform privilege; `jamfProPrivilege` the Jamf
    /// Pro API role privilege for Jamf Pro API connections.
    private static let permissionProbes: [(title: String, path: String, permission: String, jamfProPrivilege: String)] = [
        ("Read categories", "/pro/v1/categories", "categories:read", "Read Categories"),
        ("Read scripts", "/pro/v1/scripts", "scripts:read", "Read Scripts"),
        ("Read Automated Device Enrollment", "/pro/v1/device-enrollments", "device-enrollment-program-instances:read", "Read Device Enrollment Program Instances"),
        ("Read volume purchasing", "/pro/v1/volume-purchasing-locations", "volume-purchasing-locations:read", "Read Volume Purchasing Locations"),
    ]

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

        // 2. Permission dry reads. Also harvest token expiry dates for the
        //    dashboard while we're there.
        for probe in permissionProbes {
            do {
                let (data, status) = try await client.get(probe.path, query: [URLQueryItem(name: "page-size", value: "1")])
                switch status {
                case 200:
                    harvest(path: probe.path, data: data, into: &snapshot)
                    await record(PreflightCheck(
                        id: probe.path, title: probe.title,
                        outcome: .pass, detail: "Allowed."
                    ))
                case 401, 403:
                    await record(PreflightCheck(
                        id: probe.path, title: probe.title,
                        outcome: .fail,
                        detail: isJamfPro
                            ? "Not allowed. Add the \"\(probe.jamfProPrivilege)\" privilege to the API role or user account in Jamf Pro."
                            : "Not allowed. Add the \"\(probe.permission)\" permission to the API integration in Jamf Account."
                    ))
                default:
                    await record(PreflightCheck(
                        id: probe.path, title: probe.title,
                        outcome: .warn, detail: "Unexpected answer (HTTP \(status))."
                    ))
                }
            } catch {
                await record(PreflightCheck(
                    id: probe.path, title: probe.title,
                    outcome: .warn,
                    detail: "Could not check: \(error.localizedDescription)"
                ))
            }
        }

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

    /// Pulls dashboard fields out of probe responses so preflight doubles as
    /// the first token-expiry read.
    private static func harvest(path: String, data: Data, into snapshot: inout PreflightSnapshot) {
        struct ADEPage: Decodable {
            struct Instance: Decodable { let tokenExpirationDate: String? }
            let results: [Instance]
        }
        struct VPPPage: Decodable {
            struct Location: Decodable { let tokenExpiration: String? }
            let results: [Location]
        }
        if path.hasSuffix("device-enrollments"),
           let page = try? JSONDecoder().decode(ADEPage.self, from: data) {
            snapshot.adeTokenExpiration = page.results.compactMap(\.tokenExpirationDate).min()
        }
        if path.hasSuffix("volume-purchasing-locations"),
           let page = try? JSONDecoder().decode(VPPPage.self, from: data) {
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
