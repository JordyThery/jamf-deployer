import XCTest
import JTKitUITestSupport

/// Walks through a Jamf Pro API connection against two test instances:
/// connect with a user account, custom objects, drift, adoption, export,
/// a rollout, Day 0 and hand-over. Steps run in name order and share state;
/// Scripts/run-jamfpro-ui-tests.sh changes objects in Jamf between steps
/// and cleans up afterwards.
final class JamfProUITests: DeployerUITestCase {
    static let sandbox = "JP Sandbox"
    static let demo = "JP Demo"

    func test01ConnectWithJamfProAPI() throws {
        try connectJamfPro(name: Self.sandbox, prefix: "JPSBX")
        try connectJamfPro(name: Self.demo, prefix: "JPDEMO")
        openTenant(Self.sandbox)
        XCTAssertTrue(any("Jamf Pro API").waitForExistence(timeout: 10), "Connection type not shown")
        XCTAssertTrue(app.buttons["Baseline Updates…"].waitForExistence(timeout: 10),
                      "Jamf Pro API tenants offer building blocks")
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Run Preflight'")).firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining("Signed in to the Jamf Pro API").waitForExistence(timeout: 60), "Preflight did not sign in")
    }

    /// A custom object only offers Jamf Pro API types and deploys through them.
    func test02CustomObjectDeploys() throws {
        stageCustomCategory(on: Self.sandbox, objectName: "jp_ui_test", name: "UIT - JP Category")
        previewAndDeploy()
        XCTAssertTrue(anyContaining("1 succeeded").waitForExistence(timeout: 15))
    }

    /// Precondition (set by the script): the category's priority was changed in Jamf.
    func test03DriftRestoreBaseline() throws {
        openTenant(Self.sandbox)
        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        XCTAssertTrue(any("Changed in Jamf").waitForExistence(timeout: 180), "Drift was not detected")
        tap(app.buttons["Restore Baseline…"])
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        sleep(5)
        XCTAssertTrue(any("Changed in Jamf").waitForNonExistence(timeout: 180), "Drift remained after restoring")
    }

    /// Precondition (set by the script): "UIT - JP Adopt" exists in the Demo instance.
    func test04AdoptExistingObject() throws {
        openTenant(Self.demo)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Adopt'")).firstMatch, timeout: 15)
        let filter = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types'")).firstMatch
        type("categor", into: filter)
        tap(app.sheets.buttons["None"])
        tap(app.sheets.checkBoxes.matching(NSPredicate(format: "label == 'categories'")).firstMatch, timeout: 30)
        tap(app.sheets.buttons["Discover Objects"])
        XCTAssertTrue(anyContaining("found").waitForExistence(timeout: 600), "Discovery did not finish")
        tap(app.sheets.buttons["None"])
        let target = app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'UIT - JP Adopt'")).firstMatch
        tap(target, timeout: 10)
        tap(app.sheets.buttons["Stage 1 for Adoption"])
        tap(app.sheets.buttons["Preview Changes"], timeout: 60)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
        XCTAssertTrue(anyContaining("1 adopted object").waitForExistence(timeout: 15))
    }

    /// Precondition (set by the script): the adopted category changed in Jamf.
    func test05DriftKeepChange() throws {
        openTenant(Self.demo)
        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        XCTAssertTrue(any("Changed in Jamf").waitForExistence(timeout: 180), "Drift was not detected")
        tap(app.buttons["Keep This Change"])
        XCTAssertTrue(anyContaining("noted — a future deploy").waitForExistence(timeout: 10) || anyContaining("kept — the baseline").exists)
    }

    /// Jamf Pro tenants export snapshots and documentation only.
    func test06ExportSnapshot() throws {
        openTenant(Self.sandbox, tab: "Export")
        XCTAssertTrue(app.radioButtons["Full snapshot"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.radioButtons["Building block"].exists, "Building blocks need the Platform API")
        XCTAssertFalse(app.radioButtons["Clone to tenant"].exists)
        let filter = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types'")).firstMatch
        XCTAssertTrue(anyContaining("of ").waitForExistence(timeout: 60))
        type("categor", into: filter)
        tap(app.buttons["None"].firstMatch)
        tap(app.checkBoxes.matching(NSPredicate(format: "label == 'categories'")).firstMatch, timeout: 30)
        tap(app.buttons.matching(NSPredicate(format: "label == 'Export'")).firstMatch)
        tap(app.buttons["Save Snapshot…"], timeout: 600)
        saveInDocuments()
        sleep(3)
    }

    /// Roll Out works for Jamf Pro tenants: Sandbox has nothing to deploy,
    /// Demo deploys a staged custom object.
    func test07Rollout() throws {
        stageCustomCategory(on: Self.demo, objectName: "jp_rollout", name: "UIT - JP Rollout")
        startRollout(rings: [Self.sandbox: 1, Self.demo: 2])
        XCTAssertTrue(waitForReview(), "Sandbox preview did not finish")
        XCTAssertFalse(app.buttons["Deploy"].isEnabled, "Sandbox should have nothing to deploy")
        tap(app.buttons["Close"])
        tap(app.buttons["Continue with Ring 2"], timeout: 60)
        deployCurrentPreview()
        tap(app.buttons["Continue"], timeout: 300)
        XCTAssertTrue(app.staticTexts["Rollout finished"].waitForExistence(timeout: 30))
        XCTAssertTrue(any("Nothing to deploy").exists)
        XCTAssertTrue(anyContaining("Deployed (").exists)
        tap(app.buttons["Done"])
    }

    func test08DaySetupTab() throws {
        openTenant(Self.demo, tab: "Day 0 Setup")
        tap(app.buttons["Check Again"], timeout: 30)
        XCTAssertTrue(app.buttons["Mark as Done"].waitForExistence(timeout: 30) || anyContaining("Organization name").exists)
    }

    /// Hand-over stops managing everything; objects stay in Jamf.
    func test09HandOver() throws {
        openTenant(Self.sandbox)
        scrollIntoView(app.buttons["Hand Over Tenant…"])
        tap(app.buttons["Hand Over Tenant…"], timeout: 15)
        let nameField = app.dialogs.textFields.firstMatch.exists ? app.dialogs.textFields.firstMatch : app.sheets.textFields.firstMatch
        type(Self.sandbox, into: nameField)
        tap(dialogButton("Prepare Hand-Over"))
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
        XCTAssertTrue(anyContaining("was handed over").waitForExistence(timeout: 15))
    }

    func test10RemoveTenants() throws {
        removeTenant(Self.sandbox)
        removeTenant(Self.demo)
    }

    /// API client (OAuth) sign-in: connect, deploy, check for changes and
    /// discover objects, then remove the tenant again.
    func test11APIClientSignIn() throws {
        let name = "JP Sandbox API Client"
        try connectJamfPro(name: name, prefix: "JPSBX", apiClient: true)
        stageCustomCategory(on: name, objectName: "jp_oauth", name: "UIT - JP OAuth")
        previewAndDeploy()
        XCTAssertTrue(anyContaining("1 succeeded").waitForExistence(timeout: 15))

        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        sleep(5)
        XCTAssertFalse(any("Changed in Jamf").waitForExistence(timeout: 120), "A fresh deploy should show no changes")

        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Adopt'")).firstMatch, timeout: 15)
        let filter = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types'")).firstMatch
        type("categor", into: filter)
        tap(app.sheets.buttons["None"])
        tap(app.sheets.checkBoxes.matching(NSPredicate(format: "label == 'categories'")).firstMatch, timeout: 30)
        tap(app.sheets.buttons["Discover Objects"])
        XCTAssertTrue(anyContaining("found").waitForExistence(timeout: 600), "Discovery with the API client did not finish")
        tap(app.sheets.buttons["Cancel"])
        removeTenant(name)
    }
}
