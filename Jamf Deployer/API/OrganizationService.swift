import Foundation
import DeployerKit

/// Jamf Account Organization API: lists environments so the wizard can offer
/// a picker instead of pasted UUIDs. Organization-scope integrations only —
/// environment-scoped ones get a friendly fallback to manual entry.
nonisolated enum OrganizationService {
    struct Environment: Identifiable, Sendable, Hashable {
        var id: String
        var name: String
    }

    enum Failure: LocalizedError {
        case notPermitted
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                "This integration can't list environments — that needs an organization-scope integration. Paste the environment ID instead."
            case .unavailable(let detail):
                "Could not fetch environments: \(detail)"
            }
        }
    }

    static func environments(
        gatewayURL: URL,
        clientID: String,
        clientSecret: String,
        activityLog: ActivityLog?
    ) async throws -> [Environment] {
        // No scope header: the Organization API addresses the organization
        // the integration itself belongs to.
        let client = JamfPlatformClient(
            configuration: JamfAPIConfiguration(
                gatewayURL: gatewayURL,
                clientID: clientID,
                clientSecret: clientSecret,
                environmentID: nil
            ),
            activityLog: activityLog
        )

        struct Page: Decodable {
            struct Item: Decodable {
                let id: String?
                let environmentId: String?
                let name: String?
            }
            let results: [Item]?
            let environments: [Item]?
        }

        do {
            let (data, status) = try await client.get("/organization/v1/environments")
            switch status {
            case 200:
                guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
                    throw Failure.unavailable("unexpected response shape")
                }
                let items = page.results ?? page.environments ?? []
                return items.compactMap { item in
                    guard let id = item.id ?? item.environmentId else { return nil }
                    return Environment(id: id, name: item.name ?? id)
                }
            case 401, 403, 404:
                throw Failure.notPermitted
            default:
                throw Failure.unavailable("HTTP \(status)")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }
    }
}
