import Foundation

/// Holds each tenant's export run outside the view hierarchy, so a running
/// export keeps its progress and result when the user navigates away and
/// back. One session per tenant.
@Observable
final class ExportSessionStore {
    @Observable
    final class Session {
        var isRunning = false
        var logTail: [String] = []
        var result: JamformerRunner.ExportResult?
        /// Object types the finished run exported, so returning to the tab
        /// restores the result under the same derived block ID.
        var exportedTypes: [String] = []
        var errorMessage: String?

        /// Appends a live log line, keeping the tail bounded.
        func appendLog(_ line: String) {
            logTail.append(line)
            if logTail.count > 400 {
                logTail.removeFirst(logTail.count - 400)
            }
        }
    }

    // Not observed: inserting a session must not invalidate views mid-update
    // (the accessor runs during body). Session objects observe themselves.
    @ObservationIgnored private var sessions: [UUID: Session] = [:]

    func session(for tenantID: UUID) -> Session {
        if let existing = sessions[tenantID] { return existing }
        let session = Session()
        sessions[tenantID] = session
        return session
    }
}
