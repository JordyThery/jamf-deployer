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
        var errorMessage: String?

        /// Appends a live log line, keeping the tail bounded.
        func appendLog(_ line: String) {
            logTail.append(line)
            if logTail.count > 400 {
                logTail.removeFirst(logTail.count - 400)
            }
        }
    }

    private var sessions: [UUID: Session] = [:]

    func session(for tenantID: UUID) -> Session {
        if let existing = sessions[tenantID] { return existing }
        let session = Session()
        sessions[tenantID] = session
        return session
    }
}
