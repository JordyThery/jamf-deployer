import XCTest
import JTKitUITestSupport

/// The screenshots on jordythery.be and in the README, taken in demo mode
/// with Contoso's sample fleet. Not part of the release check (it names its
/// UI tests one by one), and the app's own scheme runs no UI tests, so ⌘U
/// never starts this. Run it by name; the screenshots are kept in the test
/// result as "jamf-deployer-dashboard", "jamf-deployer-tenant",
/// "jamf-deployer-day0" and "jamf-deployer-app-catalog".
final class WebsiteScreenshotUITests: DeployerUITestCase {
    /// The sample tenant in sync (Contoso has a change made in Jamf).
    private let lab = "Contoso Lab (Demo)"

    override var demoLaunchArguments: [String] {
        super.demoLaunchArguments + ["-checksForUpdates", "NO", "-AppleInterfaceStyle", "Light"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.isReleaseCheck, "Website screenshots aren't part of the release check")
        try super.setUpWithError()
    }

    func testWebsiteScreenshots() {
        let main = app.windows["main"].firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        XCTAssertTrue(app.outlines.staticTexts[lab].waitForExistence(timeout: 20), "The demo fleet isn't in the sidebar")
        zoom(main)

        // The dashboard after Check All Tenants: sync state, baseline size,
        // last deploy and both token columns filled in.
        openSidebar("Dashboard")
        XCTAssertTrue(any("ADE token").waitForExistence(timeout: 10), "The dashboard didn't open")
        tap(app.menuBars.menuBarItems["Tenant"])
        tap(app.menuBars.menuItems["Check All Tenants"], timeout: 10)
        XCTAssertTrue(any("In sync").waitForExistence(timeout: 60), "Contoso Lab isn't shown in sync")
        XCTAssertTrue(any("1 change made in Jamf").waitForExistence(timeout: 30), "Contoso's change isn't shown")
        XCTAssertTrue(waitEnabled(app.toolbars.buttons["Check All Tenants"], timeout: 30), "The fleet check didn't finish")
        settle()
        keep(main.screenshot(), named: "jamf-deployer-dashboard")

        // Contoso Lab's Overview: connection details, preflight, what is
        // managed and building blocks to add.
        openLab(tab: "Overview")
        let run = main.buttons["Run Preflight"]
        scrollIntoView(run)
        tap(run, timeout: 10)
        XCTAssertTrue(waitEnabled(main.buttons["Run Preflight"], timeout: 30), "The preflight didn't finish")
        XCTAssertFalse(anyContaining("Not allowed.").exists, "A permission row failed")
        scrollIntoView(main.radioButtons["Overview"].firstMatch)
        settle()
        keep(main.screenshot(), named: "jamf-deployer-tenant")

        // Day 0 Setup with the statuses read from the demo server.
        openLab(tab: "Day 0 Setup")
        XCTAssertTrue(anyContaining("“Contoso Apple Business” connected").waitForExistence(timeout: 30),
                      "Day 0 didn't detect the ADE instance")
        settle()
        keep(main.screenshot(), named: "jamf-deployer-day0")

        // The App Catalog picker: Firefox selected, its delivery and update choices.
        openLab(tab: "Overview")
        let catalogBlock = blockCheckbox("App Catalog")
        scrollIntoView(catalogBlock, timeout: 20)
        openSettings(of: "App Catalog,")
        let chooseApps = main.buttons["Choose Apps…"]
        scrollIntoView(chooseApps)
        tap(chooseApps, timeout: 10)
        XCTAssertTrue(anyContaining("App Catalog — \(lab)").waitForExistence(timeout: 10), "The App Catalog picker didn't open")
        // The row's pickers carry no accessibility label: Delivery, Updates, Category.
        XCTAssertTrue(app.sheets.buttons["Remove Mozilla Firefox"].waitForExistence(timeout: 10), "Firefox isn't selected")
        XCTAssertGreaterThanOrEqual(app.sheets.popUpButtons.count, 2, "No delivery and update choices")
        settle()
        keep(main.screenshot(), named: "jamf-deployer-app-catalog")
        tap(app.sheets.buttons["Done"])
    }

    // MARK: Helpers

    private func openLab(tab: String) {
        openSidebar(lab)
        tap(app.radioButtons[tab].firstMatch, timeout: 10)
    }

    /// Lets loading indicators and announcements finish before a screenshot.
    private func settle() {
        sleep(3)
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    /// Zooms the window to fill the screen (drags don't move or resize it).
    private func zoom(_ window: XCUIElement) {
        let before = window.frame
        tap(app.menuBars.menuBarItems["Window"].firstMatch)
        tap(app.menuItems["Zoom"].firstMatch)
        sleep(1)
        if window.frame.height <= before.height {
            // The window was already zoomed: zooming toggled it back.
            tap(app.menuBars.menuBarItems["Window"].firstMatch)
            tap(app.menuItems["Zoom"].firstMatch)
            sleep(1)
        }
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
