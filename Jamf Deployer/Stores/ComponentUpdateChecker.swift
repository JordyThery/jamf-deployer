import Foundation

/// Watches the moving pieces the app bundles — engine, providers, exporter —
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
            return ComponentVersion.isNewer(latest, than: pinned)
        }
    }

    private(set) var components: [Component] = [
        Component(name: "Deployment engine (OpenTofu)", repository: "opentofu/opentofu", pinned: EngineInfo.openTofuVersion),
        Component(name: "Jamf Platform provider", repository: "jamf/terraform-provider-jamfplatform", pinned: EngineInfo.jamfPlatformProviderVersion),
        Component(name: "Jamf Protect provider", repository: "Jamf-Concepts/terraform-provider-jamfprotect", pinned: EngineInfo.jamfProtectProviderVersion),
        Component(name: "Jamf Pro provider (Deployment Theory)", repository: "deploymenttheory/terraform-provider-jamfpro", pinned: EngineInfo.jamfProProviderVersion),
        Component(name: "Exporter (jamformer)", repository: "Jamf-Concepts/jamformer", pinned: EngineInfo.jamformerVersion),
        Component(name: "Team state backend (terraform-backend-git)", repository: "plumber-cd/terraform-backend-git", pinned: EngineInfo.stateBackendVersion),
    ]

    var updatesAvailable: [Component] {
        components.filter(\.hasUpdate)
    }

    /// At most one check per day; failures are silent (informational data).
    func checkIfDue() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: "lastComponentCheck") as? Date,
           Date.now.timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        defaults.set(Date.now, forKey: "lastComponentCheck")

        for index in components.indices {
            let repository = components[index].repository
            guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var tag = object["tag_name"] as? String
            else { continue }
            if tag.hasPrefix("v") { tag.removeFirst() }
            components[index].latest = tag
        }
    }
}

/// The version comparison for the bundled components (from DeployerKit).
/// The app's own update check comes from JTKit.
nonisolated enum ComponentVersion {
    /// Dot-separated numeric comparison; missing components count as 0.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
