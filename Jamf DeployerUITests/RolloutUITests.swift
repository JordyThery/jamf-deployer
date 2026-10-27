import XCTest
import JTKitUITestSupport

/// Drives the real app against two test tenants. These tests deploy for real
/// and expect credentials in the runner's environment, so run them through
/// Scripts/run-rollout-ui-tests.sh, which also cleans up afterwards.
final class RolloutUITests: DeployerUITestCase {
    /// A harmless object each tenant gets during the rollout.
    static let categoryName = "Rollout UI Test"

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
        startRollout(rings: ["Rollout Sandbox": 1, "Rollout Demo": 2])

        deployCurrentPreview()
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
        startRollout(rings: ["Rollout Sandbox": 1, "Rollout Demo": 2])

        // Sandbox: preview shows nothing; Close counts as nothing to deploy.
        XCTAssertTrue(waitForReview(), "Sandbox preview did not finish")
        XCTAssertFalse(app.buttons["Deploy"].isEnabled, "Sandbox should have nothing to deploy")
        tap(app.buttons["Close"])

        tap(app.buttons["Continue with Ring 2"], timeout: 30)
        deployCurrentPreview()
        tap(app.buttons["Continue"], timeout: 30)

        XCTAssertTrue(app.staticTexts["Rollout finished"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Nothing to deploy"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Deployed (1)"].exists)
        tap(app.buttons["Done"])
    }

    func test5RemoveTenants() throws {
        removeTenant("Rollout Sandbox")
        removeTenant("Rollout Demo")
    }

    // MARK: Helpers

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
}
