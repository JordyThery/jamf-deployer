import SwiftUI
import Observation

/// Work a screen runs that isn't engine work: an export, Adopt's
/// discovery, a Day 0 step, a rollout under way. Switching demo mode swaps
/// the main window and would tear it down, so the Demo Mode switch waits
/// for it as it waits for engine work (`AppWorlds.isBusy`).
@MainActor
@Observable
final class ScreenWork {
    static let shared = ScreenWork()

    /// What runs, by token; the value names it, for tests and debugging.
    private(set) var running: [UUID: String] = [:]

    var isBusy: Bool { !running.isEmpty }

    /// Starts tracking `label`; pass the token to `end(_:)` when it's done.
    func begin(_ label: String) -> UUID {
        let token = UUID()
        running[token] = label
        return token
    }

    func end(_ token: UUID) {
        running[token] = nil
    }

    /// Runs `work`, tracked for as long as it runs.
    func tracking<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let token = begin(label)
        defer { end(token) }
        return try await work()
    }
}

extension View {
    /// Tracks `label` in `ScreenWork` while `isActive` is true and the view
    /// is on screen.
    func tracksScreenWork(_ label: String, while isActive: Bool, in work: ScreenWork = .shared) -> some View {
        modifier(ScreenWorkTracking(label: label, isActive: isActive, work: work))
    }
}

private struct ScreenWorkTracking: ViewModifier {
    let label: String
    let isActive: Bool
    let work: ScreenWork
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active, token == nil {
                    token = work.begin(label)
                } else if !active, let current = token {
                    work.end(current)
                    token = nil
                }
            }
            .onDisappear {
                if let current = token {
                    work.end(current)
                    token = nil
                }
            }
    }
}

/// Tells `AppState` while one of the main window's sheets is open, so the
/// menu bar dims its commands meanwhile.
struct ReportsSheet: ViewModifier {
    @Environment(AppState.self) private var appState
    let id: String
    let isOpen: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isOpen, initial: true) { _, open in appState.sheet(id, isOpen: open) }
            .onDisappear { appState.sheet(id, isOpen: false) }
    }
}

extension View {
    func reportsSheet(_ id: String, isOpen: Bool) -> some View {
        modifier(ReportsSheet(id: id, isOpen: isOpen))
    }
}
