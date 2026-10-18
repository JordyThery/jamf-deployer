import XCTest
import AppKit

/// Drives the real app against two test tenants. These tests deploy for real
/// and expect credentials in the runner's environment, so run them through
/// Scripts/run-rollout-ui-tests.sh, which also cleans up afterwards.
final class RolloutUITests: XCTestCase {
    private var app: XCUIApplication!

    /// A harmless object each tenant gets during the rollout.
    static let categoryName = "Rollout UI Test"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = makeApp()
        app.launch()
        app.activate()
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0 {
            print("UIDUMP-BEGIN\n\(app.debugDescription)\nUIDUMP-END")
        }
        NSPasteboard.general.clearContents()
        app.terminate()
    }

    /// The Debug build next to the test runner (not an installed release).
    private func makeApp() -> XCUIApplication {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // …/Runner.app/Contents/PlugIns
            .deletingLastPathComponent() // …/Runner.app/Contents
            .deletingLastPathComponent() // …/Runner.app
            .deletingLastPathComponent() // Build/Products/Debug
        return XCUIApplication(url: products.appending(path: "Jamf Deployer.app"))
    }

    // MARK: Steps (run in name order)

    func test1ConnectTenants() throws {
        try connect(name: "Rollout Sandbox", prefix: "SBX")
        try connect(name: "Rollout Demo", prefix: "DEMO")
    }

    func test2StageCategories() throws {
        try stageCategory(on: "Rollout Sandbox")
        try stageCategory(on: "Rollout Demo")
    }

    /// Ring 1 deploys; ring 2 is closed without deploying and the rollout stops.
    func test3RolloutDeployThenStop() throws {
        try startRollout(demoRing: 2)

        try deployCurrentTenant()
        tap(app.buttons["Continue"], timeout: 30)

        // Pause between rings.
        tap(app.buttons["Continue with Ring 2"], timeout: 30)

        // Demo's preview: close without deploying.
        let close = app.buttons["Close"]
        XCTAssertTrue(waitForReview(), "Demo preview did not finish")
        tap(close)
        tap(app.buttons["Stop Rollout"], timeout: 15)

        XCTAssertTrue(app.staticTexts["Rollout finished"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Deployed (1)"].exists || app.descendants(matching: .any)["Deployed (1)"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Not deployed"].exists)
        tap(app.buttons["Done"])
    }

    /// Ring 1 has nothing left to deploy and continues by itself; ring 2 deploys.
    func test4RolloutSkipsUnchangedThenDeploys() throws {
        try startRollout(demoRing: 2)

        // Sandbox: preview shows nothing; Close counts as nothing to deploy.
        XCTAssertTrue(waitForReview(), "Sandbox preview did not finish")
        XCTAssertFalse(app.buttons["Deploy"].isEnabled, "Sandbox should have nothing to deploy")
        tap(app.buttons["Close"])

        tap(app.buttons["Continue with Ring 2"], timeout: 30)
        try deployCurrentTenant()
        tap(app.buttons["Continue"], timeout: 30)

        XCTAssertTrue(app.staticTexts["Rollout finished"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Nothing to deploy"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Deployed (1)"].exists)
        tap(app.buttons["Done"])
    }

    func test5RemoveTenants() throws {
        for name in ["Rollout Sandbox", "Rollout Demo"] {
            let row = app.outlines.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.rightClick()
            tap(app.menuItems["Remove Tenant…"])
            tap(app.sheets.buttons["Remove Tenant"], timeout: 10)
            XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        }
    }

    // MARK: Helpers

    /// A text field in the open sheet, found by its placeholder (form
    /// fields carry no accessibility label).
    private func field(_ placeholderPrefix: String) -> XCUIElement {
        app.sheets.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", placeholderPrefix)).firstMatch
    }

    private func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("\(key) is not set for the test runner")
        }
        return value
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
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

    /// Pastes instead of typing so secrets never appear in the test log.
    private func paste(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.click()
        field.typeKey("v", modifierFlags: .command)
        NSPasteboard.general.clearContents()
    }

    private func connect(name: String, prefix: String) throws {
        let clientID = try env("\(prefix)_CLIENT_ID")
        let secret = try env("\(prefix)_CLIENT_SECRET")
        let environmentID = try env("\(prefix)_ENVIRONMENT_ID")

        if app.outlines.staticTexts[name].exists { return }
        tap(app.toolbars.buttons["Connect a Tenant"])

        let nameField = field("Contoso Production")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText(name)
        tap(app.sheets.popUpButtons.firstMatch)
        tap(app.menuItems["US"])
        tap(app.buttons["Continue"])
        tap(app.buttons["Continue"])

        paste(clientID, into: field("d5e385c3"))
        paste(secret, into: app.sheets.secureTextFields.firstMatch)
        paste(environmentID, into: field("e77c1408"))
        tap(app.buttons["Continue"])
        tap(app.buttons["Run Preflight"])
        tap(app.buttons["Add Tenant"], timeout: 180)
        XCTAssertTrue(app.outlines.staticTexts[name].waitForExistence(timeout: 10))
    }

    private func stageCategory(on tenantName: String) throws {
        tap(app.outlines.staticTexts[tenantName], timeout: 10)
        tap(app.buttons["Add a Custom Object…"], timeout: 30)
        let filter = field("Filter object types")
        XCTAssertTrue(filter.waitForExistence(timeout: 120), "Provider schema did not load")
        filter.click()
        filter.typeText("pro_category")
        tap(app.staticTexts["jamfplatform_pro_category"], timeout: 30)
        let objectName = field("my_custom_object")
        XCTAssertTrue(objectName.waitForExistence(timeout: 5))
        objectName.click()
        objectName.typeText("rollout_ui_test")
        let nameField = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == %@", "name")).firstMatch
        nameField.click()
        nameField.typeText(Self.categoryName)
        let priority = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == %@", "0")).firstMatch
        priority.click()
        priority.typeText("9")
        tap(app.buttons["Stage Object"])
    }

    private func startRollout(demoRing: Int) throws {
        tap(app.outlines.staticTexts["Dashboard"], timeout: 10)
        tap(app.toolbars.buttons["Roll Out…"], timeout: 10)
        let picker = app.popUpButtons.matching(identifier: "Ring").element(boundBy: 0)
        _ = picker.waitForExistence(timeout: 5)
        // Tenants are listed in store order; set the Demo row's ring.
        let rows = app.popUpButtons.matching(NSPredicate(format: "value BEGINSWITH 'Ring'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        for index in 0..<rows.count {
            let popup = rows.element(boundBy: index)
            let isDemo = popup.frame.midY.isFinite && app.staticTexts.matching(NSPredicate(format: "value == 'Rollout Demo' OR label == 'Rollout Demo'"))
                .allElementsBoundByIndex.contains { abs($0.frame.midY - popup.frame.midY) < 12 }
            let ring = isDemo ? demoRing : 1
            if (popup.value as? String) != "Ring \(ring)" {
                popup.click()
                tap(app.menuItems["Ring \(ring)"])
            }
        }
        tap(app.buttons["Start Rollout"])
    }

    /// Waits until the embedded preview reaches its review step.
    private func waitForReview() -> Bool {
        let deploy = app.buttons["Deploy"]
        let save = app.buttons["Save Recovery Sheet…"]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if save.exists || deploy.exists { return true }
            sleep(2)
        }
        return false
    }

    private func deployCurrentTenant() throws {
        XCTAssertTrue(waitForReview(), "Preview did not finish")
        let save = app.buttons["Save Recovery Sheet…"]
        if save.exists {
            save.click()
            // The save panel: accept the suggested name and folder.
            let panelSave = app.buttons["OKButton"].firstMatch
            tap(panelSave, timeout: 10)
            let replace = app.buttons["Replace"]
            if replace.waitForExistence(timeout: 2) { replace.click() }
        }
        tap(app.buttons["Deploy"], timeout: 15)
    }
}
