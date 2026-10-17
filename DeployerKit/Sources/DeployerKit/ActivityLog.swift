import Foundation

/// One recorded operation: an HTTP request, an engine run, a deploy step.
public nonisolated struct ActivityLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    /// Short source tag, e.g. "API", "Engine", "Export".
    public var category: String
    /// The verb: an HTTP method or an engine subcommand.
    public var operation: String
    /// The object: a URL path, a tenant name, a file.
    public var detail: String
    /// HTTP status where applicable.
    public var status: Int?
    public var duration: TimeInterval?
    public var note: String?

    public init(
        category: String,
        operation: String,
        detail: String,
        status: Int? = nil,
        duration: TimeInterval? = nil,
        note: String? = nil
    ) {
        self.id = UUID()
        self.date = .now
        self.category = category
        self.operation = operation
        self.detail = detail
        self.status = status
        self.duration = duration
        self.note = note
    }

    public var isFailure: Bool {
        guard let status else { return false }
        return status >= 400
    }
}

/// In-memory, capped activity log shown in its own window.
/// Secrets, headers and bodies are never logged.
@Observable
public final class ActivityLog {
    public private(set) var entries: [ActivityLogEntry] = []
    private let cap = 1000

    public init() {}

    public func append(_ entry: ActivityLogEntry) {
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    public func clear() {
        entries.removeAll()
    }
}
