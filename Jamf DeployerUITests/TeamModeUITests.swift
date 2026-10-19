import XCTest

/// Team Mode end to end with one Mac and a stand-in teammate: create a team
/// space (state moves into the state backend), check and restore through
/// it, a lock held by someone else, force-unlock, leave (state moves back),
/// join again with the team passphrase, and remove the tenant from the team
/// space. Steps run in name order; Scripts/run-team-ui-tests.sh prepares an
/// empty store and repository, acts as the teammate between steps, checks
/// the repository's contents and restores everything afterwards.
final class TeamModeUITests: DeployerUITestCase {
    static let tenant = "Team Sandbox"
    static let prefix = "UIT - "

    func test01ConnectAndDeploy() throws {
        try connect(name: Self.tenant, prefix: "SBX")
        openTenant(Self.tenant)
        let prefixField = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'JD'")).firstMatch
        if prefixField.waitForExistence(timeout: 5) {
            prefixField.click()
            prefixField.typeKey("a", modifierFlags: .command)
            prefixField.typeText(Self.prefix)
            app.typeKey(.return, modifierFlags: [])
        }
        stageCustomCategory(on: Self.tenant, objectName: "team_category", name: "UIT - Team Category")
        previewAndDeploy()
        XCTAssertTrue(anyContaining("1 succeeded").waitForExistence(timeout: 15))
    }

    /// Creates the team space and hands its passphrase to the script, which
    /// needs it to join again later. The runner is sandboxed, so it goes
    /// through the step's log, which the script keeps in its private folder.
    func test02CreateTeamSpace() throws {
        openTeamSettings()
        type(try env("TEAM_REPOSITORY"), into: app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'https://github.com/org/'")).firstMatch)
        tap(app.buttons["Create Team Space…"])
        tap(app.buttons["Copy"].firstMatch, timeout: 10)
        let passphrase = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertFalse(passphrase.isEmpty, "No team passphrase was shown")
        print("TEAM-PASSPHRASE: \(passphrase)")
        tap(app.checkBoxes["I saved the team passphrase"])
        tap(app.buttons["Create Team Space"])
        XCTAssertTrue(anyContaining("Team space created").waitForExistence(timeout: 300), "The team space was not created")
    }

    /// The record now comes from the state backend.
    func test03CheckThroughTheTeamSpace() throws {
        try checkForChanges(expectingChanges: false)
    }

    /// Precondition (set by the script): the category changed in Jamf.
    func test04DetectAndRestore() throws {
        try checkForChanges(expectingChanges: true)
        tap(app.buttons["Restore Baseline…"], timeout: 30)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 600)
        try checkForChanges(expectingChanges: false)
    }

    /// Precondition (set by the script): a teammate holds the tenant's lock.
    func test05LockedByATeammate() throws {
        openTenant(Self.tenant)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 30)
        // The check stops at the teammate's lock; wait until it has.
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: check)
        waitForExpectations(timeout: 300)
        XCTAssertTrue(anyContaining("Try again when they finish").waitForExistence(timeout: 30), "The teammate's lock was not reported")
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Sync"], timeout: 10)
        // Exporting waits for the teammate too.
        openExportSheet()
        XCTAssertTrue(anyContaining("is working on this tenant").waitForExistence(timeout: 30),
                      "The export sheet does not show the teammate's lock")
        tap(app.sheets.buttons["Cancel"])
        openTenant(Self.tenant)
        tap(app.buttons["Force Unlock…"], timeout: 60)
        tap(dialogButton("Force Unlock"), timeout: 10)
        XCTAssertTrue(app.buttons["Force Unlock…"].waitForNonExistence(timeout: 300), "The lock was not released")
        try checkForChanges(expectingChanges: false)

        // Unlocked, the tenant exports from the team space (synced first).
        openExportSheet()
        chooseTenantAndFolder(Self.tenant, try env("TEAM_EXPORT_DIR"))
        tap(app.sheets.buttons["Export"])
        XCTAssertTrue(anyContaining("Exported 1 tenant").waitForExistence(timeout: 300), "The export did not finish")
        tap(app.sheets.buttons["Done"])
    }

    func test06LeaveTeamMode() throws {
        openTeamSettings()
        tap(app.buttons["Leave Team Mode…"], timeout: 10)
        tap(dialogButton("Leave Team Mode"), timeout: 10)
        XCTAssertTrue(anyContaining("Left Team Mode").waitForExistence(timeout: 300), "Leaving did not finish")
        app.typeKey("w", modifierFlags: .command)
        try checkForChanges(expectingChanges: false)
    }

    func test07JoinTeamSpace() throws {
        openTeamSettings()
        type(try env("TEAM_REPOSITORY"), into: app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'https://github.com/org/'")).firstMatch)
        paste(try env("TEAM_PASSPHRASE"), into: app.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'Needed to join'")).firstMatch)
        tap(app.buttons["Join Team Space"])
        XCTAssertTrue(anyContaining("Joined the team space").waitForExistence(timeout: 300), "Joining did not finish")
        app.typeKey("w", modifierFlags: .command)
        try checkForChanges(expectingChanges: false)
    }

    /// Removing the tenant in a team space removes its record and state there.
    func test08RemoveTenantFromTeamSpace() throws {
        removeTenant(Self.tenant)
        sleep(10)
    }

    func test09LeaveEmptyTeamSpace() throws {
        openTeamSettings()
        tap(app.buttons["Leave Team Mode…"], timeout: 10)
        tap(dialogButton("Leave Team Mode"), timeout: 10)
        XCTAssertTrue(anyContaining("Left Team Mode").waitForExistence(timeout: 120))
    }

    // MARK: Helpers

    private func openTeamSettings() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(anyContaining("Team").waitForExistence(timeout: 10), "Settings did not open")
    }

    private func checkForChanges(expectingChanges: Bool) throws {
        openTenant(Self.tenant)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 60)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: check)
        waitForExpectations(timeout: 600)
        sleep(2)
        let failure = anyContaining("The last check for changes failed")
        if failure.exists {
            XCTFail("The check failed: \(failure.label.isEmpty ? (failure.value as? String ?? "") : failure.label)")
            return
        }
        let changed = any("Changed in Jamf")
        if expectingChanges {
            XCTAssertTrue(changed.waitForExistence(timeout: 30), "No changes were detected")
        } else {
            XCTAssertFalse(changed.waitForExistence(timeout: 5), "Changes were reported on an unchanged tenant")
        }
    }
}
