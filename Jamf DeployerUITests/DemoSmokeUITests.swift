import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// the same answers every run, no tenant, nothing saved. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
final class DemoSmokeUITests: DeployerUITestCase {
    private let contoso = "Contoso (Demo)"

    override func launchApp() {
        launchInDemo()
    }

    func test1Launch() {
        let main = app.windows["main"].firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        XCTAssertTrue(app.outlines.staticTexts[contoso].waitForExistence(timeout: 20), "The demo fleet isn't in the sidebar")
        XCTAssertTrue(app.outlines.staticTexts["Contoso Lab (Demo)"].exists, "Contoso Lab is missing")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Team", "Advanced", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Jamf Deployer's + opens the Connect wizard (it checks a real
        // tenant), so the editor is opened and the wizard cancelled.
        checkConnectionsEditorOpens()
    }

    /// Contoso: Check for Changes finds the Teams change, Preview shows the
    /// fixed plan, Deploy is dimmed.
    func test5MainTask() {
        checkForChangesOnContoso()

        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        let unavailable = anyContaining("Deploying isn't available in Demo Mode.")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 60), "The preview didn't reach its review step")
        XCTAssertTrue(anyContaining("Reverts the change found in Jamf").exists, "The Teams update isn't in the plan")
        let deploy = app.sheets.buttons["Deploy"].firstMatch
        XCTAssertTrue(deploy.exists, "No Deploy button")
        XCTAssertFalse(deploy.isEnabled, "Deploy must be dimmed in Demo Mode")
        tap(app.sheets.buttons["Close"].firstMatch)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "The preview did not close")
    }

    func test6ActivityLog() {
        checkForChangesOnContoso()
        checkActivityLog()
    }

    func test7DemoTitles() {
        XCTAssertTrue(app.windows["main"].firstMatch.waitForExistence(timeout: 20))
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    // MARK: Helpers

    private func checkForChangesOnContoso(file: StaticString = #filePath, line: UInt = #line) {
        openSidebar(contoso)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 20, file: file, line: line)
        // The button is dimmed while the check runs.
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: check)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 60), .completed, "The check didn't finish", file: file, line: line)
        XCTAssertTrue(any("Changed in Jamf").waitForExistence(timeout: 20), "The Teams change wasn't found", file: file, line: line)
    }
}
