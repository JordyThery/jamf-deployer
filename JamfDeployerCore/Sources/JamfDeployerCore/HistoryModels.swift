import Foundation

/// summary.json inside one history/<timestamp>/ folder: who did what, when,
/// with which blocks. The full plan and log sit alongside it.
public nonisolated struct DeployHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case preview
        case deploy
        case destroy
    }

    public var id: String
    public var date: Date
    public var kind: Kind
    /// Engineer name from Settings, falling back to the macOS account.
    public var engineerName: String
    public var macOSUserName: String
    /// block id → version deployed.
    public var blockVersions: [String: String]
    public var added: Int
    public var changed: Int
    public var removed: Int
    public var stoppedManaging: Int
    public var failed: Int

    public init(
        id: String,
        date: Date,
        kind: Kind,
        engineerName: String,
        macOSUserName: String,
        blockVersions: [String: String],
        added: Int,
        changed: Int,
        removed: Int,
        stoppedManaging: Int,
        failed: Int
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.engineerName = engineerName
        self.macOSUserName = macOSUserName
        self.blockVersions = blockVersions
        self.added = added
        self.changed = changed
        self.removed = removed
        self.stoppedManaging = stoppedManaging
        self.failed = failed
    }

    /// Folder-name-safe timestamp identifier.
    public static func makeID(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
