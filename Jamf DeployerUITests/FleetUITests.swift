import XCTest
import JTKitUITestSupport

/// Deploys the demo catalog's Fleet preset — the fleet blocks, PreStages
/// included — to a tenant with an Automated Device Enrollment instance,
/// checks it converges, and removes it again. Steps run in name order and
/// share state; Scripts/run-fleet-ui-tests.sh prepares the catalog, checks
/// the objects in Jamf between steps and cleans up.
final class FleetUITests: DeployerUITestCase {
    static let tenant = "Fleet Test"
    static let catalogName = "UI Fleet Catalog"
    static let prefix = "UIF - "

    func test1ConnectAndSetPrefix() throws {
        try connect(name: Self.tenant, prefix: "FLT")
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

    func test2AddCatalog() throws {
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

    /// The Fleet preset, with the tenant's ADE instance on both PreStages.
    func test3DeployFleetPreset() throws {
        openTenant(Self.tenant)
        tap(app.menuButtons["Apply a Preset"].firstMatch, timeout: 30)
        tap(app.menuItems["Fleet"], timeout: 5)
        if dialogButton("Apply Preset").waitForExistence(timeout: 2) { dialogButton("Apply Preset").click() }
        for block in ["Fleet Foundation", "Mac Security", "iPad and iPhone Restrictions", "Saved Searches"] {
            XCTAssertEqual(blockCheckbox(block).value as? Int, 1, "\(block) is not selected by the preset")
        }
        let adeName = try env("FLEET_ADE_NAME")
        for block in ["Mac PreStages,", "iPad and iPhone PreStages,"] {
            openSettings(of: block)
            let ade = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Required' AND value == ''")).firstMatch
            type(adeName, into: ade)
            app.typeKey(.return, modifierFlags: [])
            tap(app.buttons["Hide Settings"].firstMatch, timeout: 5)
        }
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 1800)
        XCTAssertTrue(anyContaining(" 0 failed").waitForExistence(timeout: 15), "Some fleet objects failed to deploy")
    }

    func test4NoChangesAfterDeploy() throws {
        try checkForChanges(on: Self.tenant, expectingChanges: false)
    }

    /// Two fleet blocks that do the same job as another block cannot be
    /// combined: selecting FileVault next to Mac Security is flagged.
    func test5ConflictIsFlagged() throws {
        openTenant(Self.tenant)
        let fileVault = blockCheckbox("FileVault")
        XCTAssertTrue(fileVault.waitForExistence(timeout: 10))
        fileVault.click()
        XCTAssertTrue(anyContaining("Cannot be used together with").waitForExistence(timeout: 10), "The conflict is not shown")
        fileVault.click()
        if dialogButton("Remove from Tenant").waitForExistence(timeout: 3) { dialogButton("Remove from Tenant").click() }
        XCTAssertFalse(anyContaining("Cannot be used together with").waitForExistence(timeout: 3))
    }

    func test6RemoveEverything() throws {
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
        XCTAssertTrue(anyContaining(" 0 failed").waitForExistence(timeout: 15), "Some fleet objects failed to delete")
    }

    func test7RemoveTenantAndCatalog() throws {
        removeTenant(Self.tenant)
        removeCatalogSources(named: Self.catalogName)
    }
}
