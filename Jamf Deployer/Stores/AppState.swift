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

    /// The main window's sheets that are open now: menu commands are dimmed
    /// while one is, so a second sheet never stacks on it.
    private(set) var openSheets: Set<String> = []

    var isSheetOpen: Bool { !openSheets.isEmpty }

    func sheet(_ id: String, isOpen: Bool) {
        if isOpen { openSheets.insert(id) } else { openSheets.remove(id) }
    }

    var selectedTenantID: UUID? {
        if case .tenant(let id) = selection { return id }
        return nil
    }

    /// Records the command with the tenant selected now: a tenant's command
    /// runs only for the tenant it was issued for.
    func request(_ command: MenuCommand) {
        menuRequestSerial += 1
        menuRequest = MenuRequest(command: command, serial: menuRequestSerial, tenantID: selectedTenantID)
    }

    /// The waiting command when it is one of `commands`, cleared so it runs
    /// once. With `tenantID` (a tenant's page taking it), a command issued
    /// for another tenant, or with none selected, is dropped instead.
    func take(_ commands: Set<MenuCommand>, for tenantID: UUID? = nil) -> MenuCommand? {
        takeRequest(commands, for: tenantID)?.command
    }

    /// The same, with the tenant the command was issued for.
    func takeRequest(_ commands: Set<MenuCommand>, for tenantID: UUID? = nil) -> MenuRequest? {
        guard let request = menuRequest, commands.contains(request.command) else { return nil }
        menuRequest = nil
        if let tenantID, request.tenantID != tenantID { return nil }
        return request
    }

    /// Whether the waiting command is `command`, issued for `tenantID`. One
    /// issued for another tenant is dropped.
    func isWaiting(_ command: MenuCommand, for tenantID: UUID) -> Bool {
        guard let request = menuRequest, request.command == command else { return false }
        guard request.tenantID == tenantID else {
            menuRequest = nil
            return false
        }
        return true
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
    /// The tenant selected when it was issued.
    var tenantID: UUID? = nil
}
