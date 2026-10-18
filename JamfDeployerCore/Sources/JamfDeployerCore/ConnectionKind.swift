import Foundation

/// How a tenant is reached. Fixed when the tenant is connected: its record
/// is written in one API's vocabulary and cannot switch later.
public nonisolated enum ConnectionKind: String, Codable, Sendable, CaseIterable {
    /// The Jamf Platform API gateway (the jamfplatform engine plugin).
    case platform
    /// The Jamf Pro API of one instance (the community jamfpro plugin).
    /// Adopt-and-maintain only: catalog blocks are written for Platform.
    case jamfPro

    /// The name jamformer uses for this connection's object types.
    public var exporterProvider: String {
        switch self {
        case .platform: "jamfplatform"
        case .jamfPro: "jamfpro"
        }
    }
}
