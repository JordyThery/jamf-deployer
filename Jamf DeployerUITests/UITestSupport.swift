import XCTest
import AppKit

/// Shared helpers for UI tests that drive the real app against test
/// tenants. Credentials arrive as environment variables (see Scripts/).
class DeployerUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = makeApp()
        app.launch()
        app.activate()
        // A larger window keeps long forms on screen (clicks need a hit point).
        let window = app.windows["main"].firstMatch
        if window.waitForExistence(timeout: 10), window.frame.height < 800 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0 {
            print("UIDUMP-BEGIN\n\(app.debugDescription)\nUIDUMP-END")
        }
        NSPasteboard.general.clearContents()
        app.terminate()
    }

    /// The Debug build next to the test runner (not an installed release).
    func makeApp() -> XCUIApplication {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // …/Runner.app/Contents/PlugIns
            .deletingLastPathComponent() // …/Runner.app/Contents
            .deletingLastPathComponent() // …/Runner.app
            .deletingLastPathComponent() // Build/Products/Debug
        return XCUIApplication(url: products.appending(path: "Jamf Deployer.app"))
    }

    // MARK: Elements

    /// A text field in the open sheet, found by its placeholder (form
    /// fields carry no accessibility label).
    func field(_ placeholderPrefix: String) -> XCUIElement {
        app.sheets.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", placeholderPrefix)).firstMatch
    }

    /// Any element whose label, title, value or identifier matches.
    func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR title == %@ OR value == %@ OR identifier == %@", text, text, text, text
        )).firstMatch
    }

    /// Any element whose label or value contains the text.
    func anyContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", text, text
        )).firstMatch
    }

    func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("\(key) is not set for the test runner")
        }
        return value
    }

    // MARK: Actions

    func tap(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let element = element.firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        // Sidebar rows and labels report themselves disabled; only controls are checked.
        if element.elementType != .staticText {
            let enabled = NSPredicate(format: "isEnabled == true")
            let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Disabled \(element)", file: file, line: line)
        }
        element.click()
    }

    func type(_ text: String, into element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        element.click()
        element.typeText(text)
    }

    /// Pastes instead of typing so secrets never appear in the test log.
    func paste(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.click()
        field.typeKey("v", modifierFlags: .command)
        NSPasteboard.general.clearContents()
    }

    func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 300) -> Bool {
        element.waitForNonExistence(timeout: timeout)
    }

    // MARK: Navigation

    func openSidebar(_ label: String) {
        tap(app.outlines.staticTexts[label], timeout: 15)
    }

    func openTenant(_ name: String, tab: String = "Overview") {
        // A click while a text field is editing only ends editing, and right
        // after connecting the page can take a few seconds to appear; retry
        // until it shows.
        for _ in 0..<5 {
            openSidebar(name)
            if app.windows[name].waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(app.windows[name].exists, "Tenant page \(name) did not open")
        let segment = app.radioButtons[tab].firstMatch
        if segment.waitForExistence(timeout: 5) { segment.click() }
    }

    // MARK: Flows

    /// Connects a tenant through the wizard; credentials come from the
    /// `<prefix>_CLIENT_ID`, `_CLIENT_SECRET` and `_ENVIRONMENT_ID` variables.
    func connect(name: String, prefix: String) throws {
        let clientID = try env("\(prefix)_CLIENT_ID")
        let secret = try env("\(prefix)_CLIENT_SECRET")
        let environmentID = try env("\(prefix)_ENVIRONMENT_ID")

        // Optional: `<prefix>_REGION` (default US) and a Protect connection
        // from `<prefix>_PROTECT_URL`, `_PROTECT_CLIENT_ID`, `_PROTECT_CLIENT_SECRET`.
        let environment = ProcessInfo.processInfo.environment
        let region = environment["\(prefix)_REGION"] ?? "US"

        if app.outlines.staticTexts[name].exists { return }
        tap(app.toolbars.buttons["Connect a Tenant…"])

        type(name, into: field("Contoso Production"))
        tap(app.sheets.popUpButtons.matching(NSPredicate(format: "value == 'EU'")).firstMatch)
        tap(app.menuItems[region])
        tap(app.buttons["Continue"])
        tap(app.buttons["Continue"])

        paste(clientID, into: field("d5e385c3"))
        paste(secret, into: app.sheets.secureTextFields.firstMatch)
        paste(environmentID, into: field("e77c1408"))
        tap(app.buttons["Continue"])
        if let protectURL = environment["\(prefix)_PROTECT_URL"] {
            paste(protectURL, into: field("https://yourorg.protect.jamfcloud.com"))
            // The client ID field has no placeholder; it follows the URL field.
            paste(try env("\(prefix)_PROTECT_CLIENT_ID"), into: app.sheets.textFields.element(boundBy: 1))
            paste(try env("\(prefix)_PROTECT_CLIENT_SECRET"), into: app.sheets.secureTextFields.firstMatch)
        }
        tap(app.buttons["Run Preflight"])
        tap(app.buttons["Add Tenant"], timeout: 180)
        XCTAssertTrue(app.outlines.staticTexts[name].waitForExistence(timeout: 10))
    }

    /// Connects a tenant through the Jamf Pro API with a user account;
    /// credentials come from `<prefix>_URL`, `_USERNAME` and `_PASSWORD`.
    /// With `apiClient`, signs in with `<prefix>_CLIENT_ID` / `_CLIENT_SECRET` instead.
    func connectJamfPro(name: String, prefix: String, apiClient: Bool = false) throws {
        let url = try env("\(prefix)_URL")
        let username = try env(apiClient ? "\(prefix)_CLIENT_ID" : "\(prefix)_USERNAME")
        let password = try env(apiClient ? "\(prefix)_CLIENT_SECRET" : "\(prefix)_PASSWORD")

        if app.outlines.staticTexts[name].exists { return }
        tap(app.toolbars.buttons["Connect a Tenant…"])
        type(name, into: field("Contoso Production"))
        tap(app.sheets.popUpButtons.matching(NSPredicate(format: "value == 'Jamf Platform API'")).firstMatch)
        tap(app.menuItems["Jamf Pro API"])
        tap(app.buttons["Continue"])
        tap(app.buttons["Continue"])

        paste(url, into: field("https://yourorg.jamfcloud.com"))
        if apiClient {
            paste(username, into: field("d5e385c3"))
        } else {
            tap(app.sheets.popUpButtons.matching(NSPredicate(format: "value == 'API client'")).firstMatch)
            tap(app.menuItems["User account"])
            paste(username, into: field("Jamf Pro username"))
        }
        paste(password, into: app.sheets.secureTextFields.firstMatch)
        tap(app.buttons["Continue"])
        tap(app.buttons["Add Tenant"], timeout: 180)
        XCTAssertTrue(app.outlines.staticTexts[name].waitForExistence(timeout: 10))
    }

    /// Stages a category through Add a Custom Object.
    func stageCustomCategory(on tenantName: String, objectName: String, name: String, priority: String = "9") {
        openTenant(tenantName)
        tap(app.buttons["Add a Custom Object…"], timeout: 30)
        let filter = field("Filter object types")
        XCTAssertTrue(filter.waitForExistence(timeout: 180), "Object types did not load")
        filter.click()
        filter.typeText("_category")
        let row = app.sheets.staticTexts.matching(NSPredicate(format: "value ENDSWITH '_category'")).firstMatch
        tap(row, timeout: 30)
        type(objectName, into: field("my_custom_object"))
        type(name, into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == %@", "name")).firstMatch)
        type(priority, into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == %@", "0")).firstMatch)
        tap(app.buttons["Stage Object"])
    }

    func removeTenant(_ name: String) {
        let row = app.outlines.staticTexts[name].firstMatch
        guard row.waitForExistence(timeout: 5) else { return }
        row.rightClick()
        tap(app.menuItems["Remove Tenant…"])
        tap(app.sheets.buttons["Remove Tenant"], timeout: 10)
        // In Team Mode the tenant's state is deleted from the team space first.
        XCTAssertTrue(row.waitForNonExistence(timeout: 120))
    }

    /// Waits until a preview sheet reaches its review step.
    func waitForReview(timeout: TimeInterval = 600) -> Bool {
        let deploy = app.buttons["Deploy"]
        let save = app.buttons["Save Recovery Sheet…"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if save.exists || deploy.exists { return true }
            sleep(2)
        }
        return false
    }

    /// Confirms an open save panel. The test scripts point the app's
    /// remembered save folder at ~/Documents before running.
    func saveInDocuments() {
        tap(app.buttons["OKButton"].firstMatch, timeout: 15)
        // The confirmation's own button, never its Touch Bar copy.
        let inSheet = app.sheets.buttons["Replace"].firstMatch
        let inDialog = app.dialogs.buttons["Replace"].firstMatch
        if inSheet.waitForExistence(timeout: 2) {
            inSheet.click()
        } else if inDialog.exists {
            inDialog.click()
        }
    }

    /// Saves the recovery sheet when asked (first deploy), then deploys.
    func deployCurrentPreview() {
        XCTAssertTrue(waitForReview(), "Preview did not finish")
        let save = app.buttons["Save Recovery Sheet…"]
        if save.exists {
            save.click()
            saveInDocuments()
        }
        tap(app.buttons["Deploy"], timeout: 15)
    }

    /// Opens Preview Changes for the selected tenant, deploys, and waits for Done.
    func previewAndDeploy(file: StaticString = #filePath, line: UInt = #line) {
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
    }

    /// Opens Roll Out…, optionally picks what to roll out, sets each listed
    /// tenant's ring (unlisted tenants are excluded) and starts.
    func startRollout(rings: [String: Int], change: String? = nil) {
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Roll Out…"], timeout: 10)
        if let change {
            let radio = app.sheets.radioButtons.matching(NSPredicate(format: "label CONTAINS %@", change)).firstMatch
            XCTAssertTrue(radio.waitForExistence(timeout: 10), "No option \(change)")
            // The button spans the row; click its label at the left.
            radio.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
            XCTAssertEqual(radio.value as? Int, 1, "Option \(change) was not selected")
        }
        let popups = app.sheets.popUpButtons.matching(NSPredicate(format: "value BEGINSWITH 'Ring'"))
        XCTAssertTrue(popups.firstMatch.waitForExistence(timeout: 10))
        let switches = app.sheets.switches.allElementsBoundByIndex
        for popup in popups.allElementsBoundByIndex {
            // Match the row by vertical position: the tenant name sits on the same line.
            guard let include = switches.first(where: { abs($0.frame.midY - popup.frame.midY) < 14 }) else { continue }
            let name = rings.keys.first { name in
                app.sheets.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name))
                    .allElementsBoundByIndex.contains { abs($0.frame.midY - popup.frame.midY) < 14 }
            }
            let wanted = name != nil
            if ((include.value as? Int) == 1) != wanted { include.click() }
            if let name, let ring = rings[name], (popup.value as? String) != "Ring \(ring)" {
                popup.click()
                tap(app.menuItems["Ring \(ring)"])
            }
        }
        tap(app.buttons["Start Rollout"])
    }

    /// A button in a sheet, alert or dialog (never a Touch Bar copy).
    func dialogButton(_ label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label].firstMatch
        if inSheet.waitForExistence(timeout: 3) { return inSheet }
        return app.dialogs.buttons[label].firstMatch
    }

    /// Removes every catalog source with this name (Manage Sources rows are
    /// matched by the row that shows the name, never by position).
    func removeCatalogSources(named name: String) {
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Manage Sources…"], timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            let label = app.sheets.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch
            guard label.waitForExistence(timeout: 2) else { break }
            let row = app.sheets.buttons.matching(NSPredicate(format: "label == 'Remove…'")).allElementsBoundByIndex
                .min { abs($0.frame.midY - label.frame.midY) < abs($1.frame.midY - label.frame.midY) }
            guard let remove = row, abs(remove.frame.midY - label.frame.midY) < 30 else { break }
            remove.click()
            tap(dialogButton("Remove Source"), timeout: 10)
            sleep(1)
        }
        tap(app.sheets.buttons["Done"].exists ? app.sheets.buttons["Done"] : app.sheets.buttons["Close"], timeout: 5)
    }

    /// The baseline editor's checkbox for a catalog block.
    /// Opens a block's settings: the Show Settings button on the block's row.
    func openSettings(of blockLabelPrefix: String) {
        let checkbox = blockCheckbox(String(blockLabelPrefix.dropLast()))
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10), "\(blockLabelPrefix) not listed")
        let buttons = app.buttons.matching(NSPredicate(format: "label == 'Show Settings'")).allElementsBoundByIndex
        let row = buttons.min { abs($0.frame.midY - checkbox.frame.midY) < abs($1.frame.midY - checkbox.frame.midY) }
        guard let button = row, abs(button.frame.midY - checkbox.frame.midY) < 30 else {
            XCTFail("No Show Settings button next to \(blockLabelPrefix)")
            return
        }
        button.click()
    }

    /// Runs Check for Changes on a tenant and checks whether it found any.
    func checkForChanges(on tenant: String, expectingChanges: Bool) throws {
        openTenant(tenant)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 30)
        // The button is disabled while the check runs.
        let finished = NSPredicate(format: "isEnabled == true")
        expectation(for: finished, evaluatedWith: check)
        waitForExpectations(timeout: 1200)
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

    func blockCheckbox(_ name: String) -> XCUIElement {
        app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    // MARK: Export as Terraform

    func openExportSheet() {
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Export as Terraform…"], timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10))
    }

    /// Ticks `tenant` (and only it) in the export sheet and picks the folder
    /// through the open panel's Go to Folder field.
    func chooseTenantAndFolder(_ tenant: String, _ path: String) {
        for checkbox in app.sheets.checkBoxes.allElementsBoundByIndex
        where !checkbox.label.hasPrefix(tenant) && checkbox.label != "Stop managing these tenants in this app"
            && (checkbox.value as? Int) == 1 {
            checkbox.click()
        }
        let mine = app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", tenant)).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "The tenant is not offered")
        if (mine.value as? Int) != 1 { mine.click() }

        tap(app.sheets.buttons["Choose…"])
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The folder panel did not open")
        app.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        app.typeText(path + "\n")
        sleep(1)
        tap(app.dialogs.buttons["Choose"].firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining((path as NSString).lastPathComponent).waitForExistence(timeout: 10), "The folder was not chosen")
    }
}
