import Foundation

/// Cross-cutting UI state the menu bar needs: what's selected, and pending
/// menu-initiated actions the views consume.
@Observable
final class AppState {
    var selection: SidebarSelection? = .fleet

    /// Bumped by Tenant → Preview Changes (⌘P) / Deploy… (⌘D); the tenant
    /// detail view opens the preview sheet in response.
    var previewRequestCount = 0

    var selectedTenantID: UUID? {
        if case .tenant(let id) = selection { return id }
        return nil
    }
}
