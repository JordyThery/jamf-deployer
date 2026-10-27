import XCTest
import JTKitUITestSupport

/// The Mac App Store Apps block deployed through the Platform API: pick a
/// licensed app, scope it to an empty test group, deploy, check, detect a
/// change made in Jamf, restore, and remove it. Steps run in name order;
/// Scripts/run-app-store-ui-tests.sh creates the group, checks the app in
/// Jamf, changes it between steps and cleans up.
final class AppStoreUITests: DeployerUITestCase {
    static let tenant = "AS Platform"
    static let block = "Mac App Store Apps"

    func test01Connect() throws {
        try connect(name: Self.tenant, prefix: "SBX")
        openTenant(Self.tenant)
        let prefixField = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'JD'")).firstMatch
        if prefixField.waitForExistence(timeout: 5) {
            prefixField.click()
            prefixField.typeKey("a", modifierFlags: .command)
            prefixField.typeText("UIT - ")
            app.typeKey(.return, modifierFlags: [])
        }
    }

    func test02PickAndDeploy() throws {
        openTenant(Self.tenant)
        let block = blockCheckbox(Self.block)
        XCTAssertTrue(block.waitForExistence(timeout: 30))
        if (block.value as? Int) != 1 { block.click() }
        if !app.buttons["Hide Settings"].waitForExistence(timeout: 3) {
            tap(app.buttons.matching(NSPredicate(format: "label == 'Show Settings'")).firstMatch, timeout: 10)
        }
        tap(app.popUpButtons.matching(NSPredicate(format: "value == 'Choose a group…'")).firstMatch, timeout: 10)
        tap(app.menuItems["UIT - AS Empty Macs"].firstMatch, timeout: 10)
        tap(app.buttons["Choose Apps…"].firstMatch, timeout: 10)
        type(try env("APP_NAME"), into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter licensed apps'")).firstMatch)
        sleep(2)
        let add = app.sheets.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 60), "The licensed app is not listed")
        add.click()
        XCTAssertTrue(anyContaining("1 app selected").waitForExistence(timeout: 10))
        tap(app.sheets.buttons["Done"])
        XCTAssertFalse(anyContaining("needs a value before this block can deploy").waitForExistence(timeout: 3), "A required setting is still empty")
        previewAndDeploy()
        XCTAssertTrue(anyContaining("1 succeeded").waitForExistence(timeout: 15), "The app did not deploy")
    }

    func test03NoChangesAfterDeploy() throws {
        try checkForChanges(expectingChanges: false)
    }

    /// Precondition (set by the script): the app's deployment type changed in Jamf.
    func test04DetectAndRestore() throws {
        try checkForChanges(expectingChanges: true)
        tap(app.buttons["Restore Baseline…"], timeout: 30)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 600)
        try checkForChanges(expectingChanges: false)
    }

    func test05RemoveBlockAndTenant() throws {
        openTenant(Self.tenant)
        let block = blockCheckbox(Self.block)
        tap(block, timeout: 30)
        tap(dialogButton("Remove from Tenant"), timeout: 10)
        previewAndDeploy()
        XCTAssertTrue(anyContaining("0 failed").waitForExistence(timeout: 15), "The app was not removed")
        removeTenant(Self.tenant)
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
