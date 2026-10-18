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
    /// The app's own Jamf Pro category; nil uses the block's category.
    public var categoryID: String?
    /// Display name of `categoryID`.
    public var categoryName: String?

    public var id: String { titleName }

    public init(
        titleName: String,
        publisher: String,
        deploymentType: DeploymentType = .selfService,
        updateBehavior: UpdateBehavior = .automatic,
        categoryID: String? = nil,
        categoryName: String? = nil
    ) {
        self.titleName = titleName
        self.publisher = publisher
        self.deploymentType = deploymentType
        self.updateBehavior = updateBehavior
        self.categoryID = categoryID
        self.categoryName = categoryName
    }

    enum CodingKeys: String, CodingKey {
        case titleName, publisher, deploymentType, updateBehavior
        case categoryID = "categoryId"
        case categoryName
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

/// One App Store app in a Mac or iPad and iPhone App Store block. The Adam
/// ID identifies the app on every tenant; name and version are looked up
/// from the App Store when deploying.
public nonisolated struct AppStoreApp: Codable, Sendable, Identifiable, Hashable {
    public enum DeploymentType: String, Codable, Sendable, CaseIterable {
        case installAutomatically = "INSTALL_AUTOMATICALLY"
        case selfService = "SELF_SERVICE"

        public var label: String {
            switch self {
            case .installAutomatically: "Install automatically"
            case .selfService: "Offer in Self Service"
            }
        }
    }

    public var adamID: String
    /// Display name at the time it was picked.
    public var name: String
    public var deploymentType: DeploymentType
    /// The app's own Jamf Pro category; nil uses the block's category.
    public var categoryID: String?
    public var categoryName: String?

    public var id: String { adamID }

    public init(adamID: String, name: String, deploymentType: DeploymentType = .selfService,
                categoryID: String? = nil, categoryName: String? = nil) {
        self.adamID = adamID
        self.name = name
        self.deploymentType = deploymentType
        self.categoryID = categoryID
        self.categoryName = categoryName
    }

    enum CodingKeys: String, CodingKey {
        case adamID = "adamId"
        case name, deploymentType
        case categoryID = "categoryId"
        case categoryName
    }

    public static func decode(settingValue: String) -> [AppStoreApp] {
        guard !settingValue.isEmpty, let data = settingValue.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AppStoreApp].self, from: data)) ?? []
    }

    public static func encode(_ apps: [AppStoreApp]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(apps.sorted { $0.name < $1.name }) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
