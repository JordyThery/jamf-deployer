import Foundation
import JTKit

/// Watches the moving pieces the app bundles — engine, engine plugins, exporter —
/// and reports when upstream has moved past the pinned versions. Purely
/// informational: these components only ever change with an app update, so
/// the signal is "ship a new app build", shown in Settings.
@Observable
final class ComponentUpdateChecker {
    struct Component: Identifiable, Sendable {
        var name: String
        var repository: String
        var pinned: String
        var latest: String?

        var id: String { repository }

        var hasUpdate: Bool {
            guard let latest else { return false }
            return UpdateChecker.isNewer(latest, than: pinned)
        }
    }

    private(set) var components: [Component] = [
        Component(name: "Deployment engine (OpenTofu)", repository: "opentofu/opentofu", pinned: EngineInfo.openTofuVersion),
        Component(name: "Jamf Platform plugin", repository: "jamf/terraform-provider-jamfplatform", pinned: EngineInfo.jamfPlatformProviderVersion),
        Component(name: "Jamf Protect plugin", repository: "Jamf-Concepts/terraform-provider-jamfprotect", pinned: EngineInfo.jamfProtectProviderVersion),
        Component(name: "Jamf Pro plugin (Deployment Theory)", repository: "deploymenttheory/terraform-provider-jamfpro", pinned: EngineInfo.jamfProProviderVersion),
        Component(name: "Exporter (jamformer)", repository: "Jamf-Concepts/jamformer", pinned: EngineInfo.jamformerVersion),
        Component(name: "Team state backend (terraform-backend-git)", repository: "plumber-cd/terraform-backend-git", pinned: EngineInfo.stateBackendVersion),
    ]

    var updatesAvailable: [Component] {
        components.filter(\.hasUpdate)
    }

    /// Where the last check's date is kept, and how releases are fetched;
    /// tests pass their own.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    static let lastCheckKey = "lastComponentCheck"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    /// At most one check per day; failures are silent (informational data).
    /// The day only counts once a release was actually read, so a Mac that
    /// starts offline checks again next launch.
    func checkIfDue() async {
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date.now.timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }

        var anyRead = false
        for index in components.indices {
            let repository = components[index].repository
            guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var tag = object["tag_name"] as? String
            else { continue }
            anyRead = true
            // GitHub's "latest" is never a prerelease; a tag that says so anyway is skipped.
            guard object["prerelease"] as? Bool != true else { continue }
            if tag.hasPrefix("v") { tag.removeFirst() }
            components[index].latest = tag
        }
        if anyRead { defaults.set(Date.now, forKey: Self.lastCheckKey) }
    }
}
