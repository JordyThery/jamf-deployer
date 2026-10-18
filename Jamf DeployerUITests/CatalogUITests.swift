import XCTest

/// Deploys every block of the demo catalog, plus the App Catalog, to one
/// tenant through either connection, then checks, drifts, restores and
/// removes it all. Steps run in name order and share state;
/// Scripts/run-catalog-ui-tests.sh picks the connection and instance,
/// verifies every object in Jamf between steps, and cleans up afterwards.
final class CatalogUITests: DeployerUITestCase {
    static let tenant = "Catalog Test"
    static let catalogName = "UI Catalog Test"
    static let prefix = "UIC - "

    private var isJamfPro: Bool { (try? env("CATALOG_CONNECTION")) == "jamfPro" }

    func test01Connect() throws {
        let credentials = try env("CATALOG_CREDENTIALS")
        if isJamfPro {
            try connectJamfPro(name: Self.tenant, prefix: credentials)
        } else {
            try connect(name: Self.tenant, prefix: credentials)
        }
        openTenant(Self.tenant)
        let prefixField = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'JD'")).firstMatch
        if prefixField.waitForExistence(timeout: 5) {
            prefixField.click()
            prefixField.typeKey("a", modifierFlags: .command)
            prefixField.typeText(Self.prefix)
            app.typeKey(.return, modifierFlags: [])
        }
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", Self.prefix)).firstMatch.waitForExistence(timeout: 5))
    }

    func test02AddCatalog() throws {
        let url = try env("UITEST_CATALOG_URL")
        removeCatalogSources(named: Self.catalogName)
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Add Git Catalog…"], timeout: 10)
        type(Self.catalogName, into: field("Shared Blocks"))
        type(url, into: field("https://github.com/org/blocks"))
        tap(app.sheets.buttons["Fetch Release Tags"])
        let tagPicker = app.sheets.popUpButtons.firstMatch
        XCTAssertTrue(tagPicker.waitForExistence(timeout: 30), "No tags fetched")
        tagPicker.click()
        tap(app.menuItems[try env("UITEST_CATALOG_TAG")])
        tap(app.sheets.buttons["Add Catalog"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 60), "Catalog was not added")
    }

    /// The Complete preset, the ADE instance for both PreStages, and the App
    /// Catalog with one app on a group the preset creates.
    func test03ComposeBaseline() throws {
        openTenant(Self.tenant)
        let presets = app.menuButtons["Apply a Preset"].firstMatch
        tap(presets, timeout: 30)
        tap(app.menuItems["Complete"], timeout: 5)
        if dialogButton("Apply Preset").waitForExistence(timeout: 2) { dialogButton("Apply Preset").click() }
        if isJamfPro {
            XCTAssertTrue(anyContaining("Left out of the preset").waitForExistence(timeout: 10),
                          "Blocks without a Jamf Pro API version should be named")
        }

        for block in ["Enrollment,", "Mobile Enrollment,"] {
            openSettings(of: block)
            let ade = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Required' AND value == ''")).firstMatch
            type("Apple Business Manager", into: ade)
            app.typeKey(.return, modifierFlags: [])
            tap(app.buttons["Hide Settings"].firstMatch, timeout: 5)
        }

        let appCatalog = blockCheckbox("App Catalog")
        XCTAssertTrue(appCatalog.waitForExistence(timeout: 10))
        if (appCatalog.value as? Int) != 1 { appCatalog.click() }
        if !app.buttons["Hide Settings"].waitForExistence(timeout: 3) { openSettings(of: "App Catalog,") }
        let scope = app.popUpButtons.matching(NSPredicate(format: "value == 'Choose a group…'")).firstMatch
        tap(scope, timeout: 10)
        tap(app.menuItems["All Managed Macs"].firstMatch, timeout: 5)
        tap(app.buttons["Choose Apps…"].firstMatch, timeout: 10)
        type("Google Chrome", into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Search apps and publishers'")).firstMatch)
        // The Add button on the "Google Chrome" row itself: other titles
        // match the search too, and results arrive after a short delay.
        let title = app.sheets.staticTexts.matching(NSPredicate(format: "value == 'Google Chrome'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "App Catalog search did not list Google Chrome")
        sleep(2)
        let add = app.sheets.buttons.matching(NSPredicate(format: "label == 'Add'")).allElementsBoundByIndex
            .min { abs($0.frame.midY - title.frame.midY) < abs($1.frame.midY - title.frame.midY) }
        XCTAssertNotNil(add, "No Add button next to Google Chrome")
        add?.click()
        XCTAssertTrue(app.sheets.buttons.matching(NSPredicate(format: "label == 'Remove'")).firstMatch.waitForExistence(timeout: 10),
                      "Google Chrome was not added")
        tap(app.sheets.buttons["Done"])
        XCTAssertFalse(anyContaining("needs a value before this block can deploy").waitForExistence(timeout: 3), "A required setting is still empty")
        XCTAssertFalse(anyContaining("Choose which group this block applies to").exists, "A block has no scope")
    }

    func test04DeployEverything() throws {
        openTenant(Self.tenant)
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 1800)
        XCTAssertTrue(anyContaining("0 failed").waitForExistence(timeout: 15), "Some objects failed to deploy")
    }

    /// A fresh deploy shows no changes.
    func test05NoChangesAfterDeploy() throws {
        try checkForChanges(expectingChanges: false)
    }

    /// Precondition (set by the script): one field changed on every object type.
    func test06DetectsEveryChange() throws {
        try checkForChanges(expectingChanges: true)
    }

    func test07RestoreBaseline() throws {
        openTenant(Self.tenant)
        tap(app.buttons["Restore Baseline…"], timeout: 30)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 1800)
        try checkForChanges(expectingChanges: false)
    }

    /// Precondition (set by the script): six "UIC - Adopt" objects of
    /// different types exist in Jamf. All of them are adopted at once.
    func test07bAdoptObjectsOfEveryKind() throws {
        openTenant(Self.tenant)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Adopt'")).firstMatch, timeout: 15)
        let filter = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types'")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 60))
        tap(app.sheets.buttons["None"], timeout: 30)
        let types = isJamfPro
            ? ["categories", "scripts", "policies", "smart_computer_groups", "static_computer_groups", "extension_attributes"]
            : ["category", "script", "policy", "device_groups", "computer_extension_attribute"]
        for type in types {
            filter.click()
            filter.typeKey("a", modifierFlags: .command)
            filter.typeText(type)
            tap(app.sheets.checkBoxes.matching(NSPredicate(format: "label == %@", type)).firstMatch, timeout: 30)
        }
        tap(app.sheets.buttons["Discover Objects"])
        XCTAssertTrue(anyContaining("found").waitForExistence(timeout: 900), "Discovery did not finish")
        tap(app.sheets.buttons["None"])
        type("UIC - Adopt", into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter objects'")).firstMatch)
        sleep(1)
        let targets = app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'UIC - Adopt'")).allElementsBoundByIndex
        XCTAssertEqual(targets.count, 6, "Expected the six objects to adopt")
        for target in targets { target.click() }
        tap(app.sheets.buttons["Stage 6 for Adoption"], timeout: 10)
        tap(app.sheets.buttons["Preview Changes"], timeout: 120)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 1800)
        XCTAssertTrue(anyContaining("6 adopted objects").waitForExistence(timeout: 15), "The objects were not adopted")
        try checkForChanges(expectingChanges: false)
    }

    /// Precondition (set by the script): the adopted policy and script changed in Jamf.
    func test07cRestoreAdoptedObjects() throws {
        try checkForChanges(expectingChanges: true)
        tap(app.buttons["Restore Baseline…"], timeout: 30)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 1800)
        try checkForChanges(expectingChanges: false)
    }

    /// Unticks every block and removes them all from the tenant in one deploy.
    func test08RemoveEverything() throws {
        openTenant(Self.tenant)
        for _ in 0..<40 {
            let ticked = app.checkBoxes.matching(NSPredicate(format: "value == 1")).allElementsBoundByIndex
                .first { $0.isHittable || $0.exists }
            guard let checkbox = ticked else { break }
            checkbox.click()
            tap(dialogButton("Remove from Tenant"), timeout: 10)
            sleep(1)
        }
        XCTAssertEqual(app.checkBoxes.matching(NSPredicate(format: "value == 1")).count, 0, "Blocks are still selected")
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 1800)
        XCTAssertTrue(anyContaining("0 failed").waitForExistence(timeout: 15), "Some objects failed to delete")
    }

    func test09RemoveTenantAndCatalog() throws {
        removeTenant(Self.tenant)
        removeCatalogSources(named: Self.catalogName)
    }

    // MARK: Helpers

    /// Opens a block's settings: the Show Settings button on the block's row.
    private func openSettings(of blockLabelPrefix: String) {
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

    private func checkForChanges(expectingChanges: Bool) throws {
        openTenant(Self.tenant)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 30)
        // The button is disabled while the check runs.
        let finished = NSPredicate(format: "isEnabled == true")
        expectation(for: finished, evaluatedWith: check)
        waitForExpectations(timeout: 1200)
        sleep(2)
        let changed = any("Changed in Jamf")
        if expectingChanges {
            XCTAssertTrue(changed.waitForExistence(timeout: 30), "No changes were detected")
        } else {
            XCTAssertFalse(changed.waitForExistence(timeout: 5), "Changes were reported on an unchanged tenant")
        }
    }
}
