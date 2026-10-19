import XCTest

/// Walks through the app's main functions against two test tenants: catalog
/// sources, the baseline editor, deploys, drift handling, removals,
/// adoption, export, history, Day 0, catalog-release rollouts and hand-over.
/// Steps run in name order and share state; Scripts/run-function-ui-tests.sh
/// prepares the local test catalog, runs them and cleans up.
final class FunctionUITests: DeployerUITestCase {
    static let sandbox = "UI Sandbox"
    static let demo = "UI Demo"
    static let catalogName = "UI Test Catalog"
    static let prefix = "UIT - "
    /// The test catalog's Categories block; other sources may hold captured
    /// blocks with the same name.
    static let categoriesBlock = "Categories, Applications"

    func test01ConnectAndSetPrefix() throws {
        try connect(name: Self.sandbox, prefix: "SBX")
        try connect(name: Self.demo, prefix: "DEMO")
        for name in [Self.sandbox, Self.demo] {
            openTenant(name)
            let prefixField = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'JD'")).firstMatch
            if prefixField.waitForExistence(timeout: 5) {
                prefixField.click()
                prefixField.typeKey("a", modifierFlags: .command)
                prefixField.typeText(Self.prefix)
                app.typeKey(.return, modifierFlags: [])
            }
            XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", Self.prefix)).firstMatch.waitForExistence(timeout: 5))
        }
    }

    func test02AddGitCatalog() throws {
        let url = try env("UITEST_CATALOG_URL")
        // Leftovers from an interrupted run would shadow the new source.
        removeCatalogSources(named: Self.catalogName)
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Add Git Catalog…"], timeout: 10)
        type(Self.catalogName, into: field("Shared Blocks"))
        type(url, into: field("https://github.com/org/blocks"))
        tap(app.sheets.buttons["Fetch Release Tags"])
        let tagPicker = app.sheets.popUpButtons.firstMatch
        XCTAssertTrue(tagPicker.waitForExistence(timeout: 30), "No tags fetched")
        tagPicker.click()
        tap(app.menuItems["v1.0.0"])
        tap(app.sheets.buttons["Add Catalog"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 60), "Catalog was not added")
        XCTAssertTrue(anyContaining("Categories").waitForExistence(timeout: 30), "Catalog blocks not listed")
    }

    func test03SelectBlockAndDeploy() throws {
        openTenant(Self.sandbox)
        let block = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", Self.categoriesBlock)).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 30), "Categories block not in the baseline editor")
        if (block.value as? Int) != 1 { block.click() }
        previewAndDeploy()
        XCTAssertTrue(anyContaining("4 succeeded").waitForExistence(timeout: 15) || anyContaining("succeeded, 0 failed").exists)
    }

    /// Precondition (set by the script): a category's priority was changed in Jamf.
    func test04DriftRestoreBaseline() throws {
        openTenant(Self.sandbox)
        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        XCTAssertTrue(any("Changed in Jamf").waitForExistence(timeout: 180), "Drift was not detected")
        XCTAssertTrue(anyContaining("UIT - Security").exists)
        tap(app.buttons["Restore Baseline…"])
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        sleep(5)
        XCTAssertTrue(any("Changed in Jamf").waitForNonExistence(timeout: 180), "Drift remained after restoring")
    }

    /// Precondition (set by the script): the priority was changed in Jamf again.
    func test05DriftKeepChange() throws {
        openTenant(Self.sandbox)
        tap(app.toolbars.buttons["Check for Changes"], timeout: 10)
        XCTAssertTrue(any("Changed in Jamf").waitForExistence(timeout: 180), "Drift was not detected")
        tap(app.buttons["Keep This Change"])
        XCTAssertTrue(anyContaining("noted — a future deploy").waitForExistence(timeout: 10) || anyContaining("kept — the baseline").exists, "Kept-change note not shown")
    }

    func test06DeployDemoBaseline() throws {
        openTenant(Self.demo)
        let block = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", Self.categoriesBlock)).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 30))
        if (block.value as? Int) != 1 { block.click() }
        previewAndDeploy()
    }

    /// Rolls the catalog's newer release out: Sandbox deploys, Demo is skipped
    /// and must keep its current release.
    func test07RolloutCatalogRelease() throws {
        startRollout(rings: [Self.sandbox: 1, Self.demo: 2], change: "The latest release of \(Self.catalogName)")
        XCTAssertTrue(waitForReview(), "Sandbox preview did not finish")
        XCTAssertTrue(anyContaining("UIT - Applications").exists, "Release update not in the preview")
        deployCurrentPreview()
        tap(app.buttons["Continue"], timeout: 300)
        tap(app.buttons["Continue with Ring 2"], timeout: 60)
        XCTAssertTrue(waitForReview(), "Demo preview did not finish")
        tap(app.buttons["Close"])
        tap(app.buttons["Skip and Continue"], timeout: 15)
        XCTAssertTrue(app.staticTexts["Rollout finished"].waitForExistence(timeout: 30))
        XCTAssertTrue(anyContaining("Deployed (").exists)
        XCTAssertTrue(any("Skipped").exists)
        tap(app.buttons["Done"])

        // Demo kept v1.0.0, so the update is still offered there.
        openTenant(Self.demo)
        tap(app.buttons["Baseline Updates…"], timeout: 10)
        XCTAssertTrue(anyContaining("v1.0.1").waitForExistence(timeout: 60), "Skipped tenant lost its release pin")
        tap(app.sheets.buttons["Close"])
    }

    func test08HistoryRollBack() throws {
        openSidebar("History")
        XCTAssertTrue(any(Self.demo).waitForExistence(timeout: 10), "History lists no deploys")
        XCTAssertTrue(any(Self.sandbox).exists)
        // Roll Demo back to its only deploy: the same baseline, so harmless.
        // The sidebar row also shows the tenant name; history rows carry a Roll Back button.
        let demoRow = app.outlineRows.containing(.button, identifier: "Roll Back…")
            .containing(NSPredicate(format: "value == %@", Self.demo)).firstMatch
        tap(demoRow.buttons["Roll Back…"], timeout: 10)
        tap(dialogButton("Roll Back"), timeout: 10)
        XCTAssertTrue(anyContaining("now uses the baseline from").waitForExistence(timeout: 10))
        tap(dialogButton("OK"))
    }

    /// Unticking a deployed block and choosing Remove from Tenant deletes its objects.
    func test09RemoveBlockFromTenant() throws {
        openTenant(Self.demo)
        let block = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", Self.categoriesBlock)).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 30))
        block.click()
        tap(dialogButton("Remove from Tenant"), timeout: 10)
        XCTAssertTrue(anyContaining("Will be removed from the tenant").waitForExistence(timeout: 10))
        previewAndDeploy()
    }

    /// Stop Managing leaves the objects in Jamf.
    func test10StopManagingBlock() throws {
        openTenant(Self.sandbox)
        let block = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", Self.categoriesBlock)).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 30))
        block.click()
        tap(dialogButton("Stop Managing"), timeout: 10)
        XCTAssertTrue(anyContaining("Will stop managing").waitForExistence(timeout: 10))
        previewAndDeploy()
    }

    /// Exports and discovery need Terraform; the Export tab downloads it once.
    func test10bDownloadTerraform() throws {
        openTenant(Self.sandbox, tab: "Export")
        let download = app.buttons["Download Terraform"]
        if download.waitForExistence(timeout: 10) { download.click() }
        XCTAssertTrue(anyContaining("Exports read the tenant").waitForExistence(timeout: 600), "Terraform download did not finish")
    }

    /// Adopts the categories left behind by test 10.
    func test11AdoptExistingObjects() throws {
        openTenant(Self.sandbox)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Adopt'")).firstMatch, timeout: 15)
        let filter = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Filter types", "Filter types")).firstMatch
        type("categor", into: filter)
        tap(app.sheets.buttons["None"])
        tap(app.sheets.checkBoxes.matching(NSPredicate(format: "label == 'category'")).firstMatch)
        tap(app.sheets.buttons["Discover Objects"])
        let none = app.sheets.buttons["None"]
        XCTAssertTrue(anyContaining("objects found").waitForExistence(timeout: 600), "Discovery did not finish")
        tap(none)
        let targets = app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'UIT - '")).allElementsBoundByIndex
        XCTAssertEqual(targets.count, 4, "Expected the four test categories")
        for target in targets { target.click() }
        tap(app.sheets.buttons["Stage 4 for Adoption"])
        tap(app.sheets.buttons["Preview Changes"], timeout: 60)
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
        XCTAssertTrue(anyContaining("4 adopted objects").waitForExistence(timeout: 15))
    }

    /// The Mac App Store block's picker lists the tenant's licensed apps.
    /// Nothing is deployed: the block is unticked again afterwards.
    func test11cAppStorePicker() throws {
        openTenant(Self.sandbox)
        let block = blockCheckbox("Mac App Store Apps")
        XCTAssertTrue(block.waitForExistence(timeout: 30))
        if (block.value as? Int) != 1 { block.click() }
        // A block without a scope yet opens its settings by itself.
        if !app.buttons["Hide Settings"].waitForExistence(timeout: 3) {
            tap(app.buttons.matching(NSPredicate(format: "label == 'Show Settings'")).firstMatch, timeout: 10)
        }
        tap(app.buttons["Choose Apps…"].firstMatch, timeout: 10)
        let add = app.sheets.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 60), "No licensed apps listed")
        add.click()
        XCTAssertTrue(anyContaining("1 app selected").waitForExistence(timeout: 10))
        tap(app.sheets.buttons["Done"])
        XCTAssertTrue(blockCheckbox("Mac App Store Apps").waitForExistence(timeout: 10))
        blockCheckbox("Mac App Store Apps").click()
        XCTAssertEqual(blockCheckbox("Mac App Store Apps").value as? Int, 0)
    }

    /// Hand-over stops managing everything and archives the record.
    func test12HandOver() throws {
        openTenant(Self.sandbox)
        tap(app.buttons["Hand Over Tenant…"], timeout: 15)
        let nameField = app.dialogs.textFields.firstMatch.exists ? app.dialogs.textFields.firstMatch : app.sheets.textFields.firstMatch
        type(Self.sandbox, into: nameField)
        tap(dialogButton("Prepare Hand-Over"))
        deployCurrentPreview()
        tap(app.buttons["Done"], timeout: 300)
        XCTAssertTrue(anyContaining("was handed over").waitForExistence(timeout: 15))
    }

    func test13DaySetupTab() throws {
        openTenant(Self.demo, tab: "Day 0 Setup")
        tap(app.buttons["Check Again"], timeout: 30)
        XCTAssertTrue(anyContaining("Organization name").waitForExistence(timeout: 30) || app.buttons["Create Branding"].exists || app.buttons["Mark as Done"].exists)
    }

    // MARK: Export (reads only)

    /// Picks an export kind, selects only the category type and runs the export.
    private func exportCategories(from tenant: String, kind: String) {
        openTenant(tenant, tab: "Export")
        let segment = app.radioButtons[kind].firstMatch
        tap(segment, timeout: 15)
        let filter = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types'")).firstMatch
        XCTAssertTrue(anyContaining("of ").waitForExistence(timeout: 60))
        type("categor", into: filter)
        tap(app.buttons["None"].firstMatch)
        tap(app.checkBoxes.matching(NSPredicate(format: "label == 'category'")).firstMatch, timeout: 30)
        tap(app.buttons.matching(NSPredicate(format: "label == 'Export'")).firstMatch)
    }

    func test14ExportAsBuiltDocumentation() throws {
        exportCategories(from: Self.sandbox, kind: "As-built documentation")
        tap(app.buttons["Save As-Built Documentation…"], timeout: 600)
        saveInDocuments()
    }

    func test15CloneToTenant() throws {
        exportCategories(from: Self.sandbox, kind: "Clone to tenant")
        XCTAssertTrue(anyContaining("selected)").waitForExistence(timeout: 600), "Export did not finish")
        // The second None belongs to the object list (the first to the type list).
        tap(app.buttons.matching(NSPredicate(format: "label == 'None'")).element(boundBy: 1))
        let targets = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'UIT - '")).allElementsBoundByIndex
        XCTAssertEqual(targets.count, 4)
        for target in targets { target.click() }
        let picker = app.popUpButtons.matching(NSPredicate(format: "value == 'Choose a tenant…'")).firstMatch
        tap(picker, timeout: 10)
        tap(app.menuItems[Self.demo])
        tap(app.buttons["Stage Clone"])
        XCTAssertTrue(anyContaining("Staged 4 objects").waitForExistence(timeout: 30), "Clone did not stage exactly the four test categories")

        openTenant(Self.demo)
        previewAndDeploy()
    }

    /// Removes the clone from Demo again (deletes the cloned objects).
    func test16RemoveClone() throws {
        openTenant(Self.demo)
        let clone = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'Clone of UI Sandbox'")).firstMatch
        XCTAssertTrue(clone.waitForExistence(timeout: 30))
        clone.click()
        tap(dialogButton("Remove from Tenant"), timeout: 10)
        previewAndDeploy()
    }

    func test17SaveSnapshot() throws {
        exportCategories(from: Self.demo, kind: "Full snapshot")
        tap(app.buttons["Save Snapshot…"], timeout: 600)
        saveInDocuments()
        sleep(3)
    }

    // MARK: Library and settings

    func test18BlockDetailsAndSettings() throws {
        openSidebar("Building Blocks")
        tap(anyContaining("Categories"), timeout: 30)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "Block details did not open")
        tap(dialogButton("Close"))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings' OR title CONTAINS 'General'")).firstMatch.waitForExistence(timeout: 10)
                      || app.checkBoxes["Check for app updates automatically"].waitForExistence(timeout: 5), "Settings did not open")
        app.typeKey("w", modifierFlags: .command)
    }

    func test19RemoveCatalogSource() throws {
        removeCatalogSources(named: Self.catalogName)
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Manage Sources…"], timeout: 10)
        XCTAssertFalse(app.sheets.staticTexts.matching(NSPredicate(format: "value == %@", Self.catalogName)).firstMatch.waitForExistence(timeout: 3),
                       "The test catalog is still listed")
    }

    func test20RemoveTenants() throws {
        removeTenant(Self.sandbox)
        removeTenant(Self.demo)
    }
}
