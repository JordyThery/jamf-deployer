import Foundation

/// Cross-cutting UI state the menu bar needs: what's selected, and pending
/// menu-initiated actions the views consume.
@Observable
final class AppState {
    /// The sidebar's selection: the main window shows it, and the View
    /// menu changes it.
    var selection: SidebarSelection? = .fleet

    /// Bumped by Tenant → Preview Changes (⌘P) / Deploy… (⌘D); the tenant
    /// detail view opens the preview sheet in response.
    var previewRequestCount = 0

    /// A menu command waiting for the view that runs it, as its on-screen
    /// button would. That view clears it once handled; a view that appears
    /// later (after the menu changed the selection) picks it up then.
    private(set) var menuRequest: MenuRequest?
    private var menuRequestSerial = 0

    var selectedTenantID: UUID? {
        if case .tenant(let id) = selection { return id }
        return nil
    }

    func request(_ command: MenuCommand) {
        menuRequestSerial += 1
        menuRequest = MenuRequest(command: command, serial: menuRequestSerial)
    }

    /// The waiting command when it is one of `commands`, cleared so it runs
    /// once.
    func take(_ commands: Set<MenuCommand>) -> MenuCommand? {
        guard let command = menuRequest?.command, commands.contains(command) else { return nil }
        menuRequest = nil
        return command
    }
}

/// Menu bar commands run by a view on screen.
nonisolated enum MenuCommand: Hashable, Sendable {
    // the main window
    case connectTenant
    // the selected tenant (TenantDetailView)
    case showOverview, showSetup, showExport
    case checkForChanges, adopt, addCustomObject, runPreflight, updateSecret, handOver, forceUnlock
    // the baseline editor in the tenant's Overview
    case baselineUpdates
    // the sidebar, which owns the removal confirmation
    case removeTenant
    // the dashboard's toolbar
    case exportTerraform, rollOut
    // Building Blocks
    case manageSources, addGitCatalog
    // History
    case reloadHistory
}

nonisolated struct MenuRequest: Equatable, Sendable {
    let command: MenuCommand
    /// Tells two requests for the same command apart.
    let serial: Int
}
