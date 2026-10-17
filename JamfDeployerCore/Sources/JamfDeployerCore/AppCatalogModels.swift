import Foundation

/// One app chosen in the App Catalog picker. The selection is stored as JSON
/// in the app-catalog block's `apps_json` setting; the block decodes it with
/// `jsondecode()` and creates one App Installer deployment per entry.
public nonisolated struct AppCatalogApp: Codable, Sendable, Identifiable, Hashable {
    public enum DeploymentType: String, Codable, Sendable, CaseIterable {
        /// Pushed to every in-scope device.
        case installAutomatically = "INSTALL_AUTOMATICALLY"
        /// Offered in Self Service.
        case selfService = "SELF_SERVICE"

        public var label: String {
            switch self {
            case .installAutomatically: "Install automatically"
            case .selfService: "Offer in Self Service"
            }
        }
    }

    public enum UpdateBehavior: String, Codable, Sendable, CaseIterable {
        /// Always tracks the latest catalog version.
        case automatic = "AUTOMATIC"
        /// Pins the version current at deploy time.
        case manual = "MANUAL"

        public var label: String {
            switch self {
            case .automatic: "Update automatically"
            case .manual: "Pin the current version"
            }
        }
    }

    /// The exact App Catalog title name (the API verifies it).
    public var titleName: String
    public var publisher: String
    public var deploymentType: DeploymentType
    public var updateBehavior: UpdateBehavior

    public var id: String { titleName }

    public init(
        titleName: String,
        publisher: String,
        deploymentType: DeploymentType = .selfService,
        updateBehavior: UpdateBehavior = .automatic
    ) {
        self.titleName = titleName
        self.publisher = publisher
        self.deploymentType = deploymentType
        self.updateBehavior = updateBehavior
    }

    // MARK: Setting round-trip

    public static func decode(settingValue: String) -> [AppCatalogApp] {
        guard !settingValue.isEmpty, let data = settingValue.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AppCatalogApp].self, from: data)) ?? []
    }

    public static func encode(_ apps: [AppCatalogApp]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(apps.sorted { $0.titleName < $1.titleName }) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
