import XCTest

/// Export as Terraform end to end: a tenant deployed with demo blocks and a
/// custom object is exported for review, then moved to a test repository.
/// Steps run in name order; Scripts/run-export-ui-tests.sh prepares the
/// repository and folders, runs the repository's own workflows against the
/// moved tenant, and cleans up.
final class ExportUITests: DeployerUITestCase {
    static let tenant = "Export Sandbox"
    static let catalogName = "UIT Export Catalog"

    func test01ConnectAndDeploy() throws {
        try connect(name: Self.tenant, prefix: "SBX")
        openTenant(Self.tenant)
        let prefixField = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'JD'")).firstMatch
        if prefixField.waitForExistence(timeout: 5) {
            prefixField.click()
            prefixField.typeKey("a", modifierFlags: .command)
            prefixField.typeText("UIT EX - ")
            app.typeKey(.return, modifierFlags: [])
        }

        removeCatalogSources(named: Self.catalogName)
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Add Git Catalog…"], timeout: 10)
        type(Self.catalogName, into: field("Shared Blocks"))
        type(try env("UITEST_CATALOG_URL"), into: field("https://github.com/org/blocks"))
        tap(app.sheets.buttons["Fetch Release Tags"])
        let tagPicker = app.sheets.popUpButtons.firstMatch
        XCTAssertTrue(tagPicker.waitForExistence(timeout: 30), "No tags fetched")
        tagPicker.click()
        tap(app.menuItems["v1.0.0"])
        tap(app.sheets.buttons["Add Catalog"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 60), "Catalog was not added")

        openTenant(Self.tenant)
        // Matched by the demo blocks' own descriptions: other catalogs on
        // this Mac may have blocks with the same names.
        for block in ["Categories, Applications, Enrollment", "Extension Attributes, A Baseline Marker"] {
            let checkbox = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", block)).firstMatch
            XCTAssertTrue(checkbox.waitForExistence(timeout: 30), "\(block) is not in the library")
            if (checkbox.value as? Int) != 1 { checkbox.click() }
        }
        stageCustomCategory(on: Self.tenant, objectName: "export_custom", name: "UIT EX - Custom", priority: "5")
        previewAndDeploy()
        XCTAssertTrue(anyContaining("7 succeeded").waitForExistence(timeout: 15), "The baseline did not deploy")
    }

    /// With technical details on (set by the script), a preview shows the
    /// commands it ran and the generated configuration.
    func test01bPreviewShowsTheEngineWork() throws {
        openTenant(Self.tenant)
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        XCTAssertTrue(anyContaining("Behind this preview").waitForExistence(timeout: 300), "The preview shows no engine details")
        XCTAssertTrue(anyContaining("tofu plan -input=false -out=plan.bin -json").exists, "The plan command is not shown")
        XCTAssertTrue(anyContaining("tofu apply -input=false -json").exists, "The deploy command is not shown")
        XCTAssertTrue(app.buttons["Show Workspace in Finder"].exists)
        tap(app.sheets.buttons["Close"])
    }

    func test02ExportForReview() throws {
        openExportSheet()
        chooseTenantAndFolder(try env("EXPORT_REVIEW_DIR"))
        tap(app.sheets.buttons["Export"])
        XCTAssertTrue(anyContaining("Exported 1 tenant").waitForExistence(timeout: 300), "The export did not finish")
        tap(app.sheets.buttons["Done"])
    }

    func test03MoveToRepository() throws {
        openExportSheet()
        chooseTenantAndFolder(try env("EXPORT_MOVE_DIR"))
        let move = app.sheets.radioButtons.matching(NSPredicate(format: "label ENDSWITH %@", "Move to a repository")).firstMatch
        scrollIntoView(move)
        move.click()
        XCTAssertEqual(move.value as? Int, 1, "Move to a repository was not selected")
        let url = app.sheets.textFields.matching(
            NSPredicate(format: "placeholderValue == 'https://github.com/org/jamf-tenants.git'")).firstMatch
        scrollIntoView(url)
        type(try env("EXPORT_REPOSITORY"), into: url)
        let accept = app.sheets.checkBoxes["Stop managing these tenants in this app"]
        scrollIntoView(accept)
        accept.click()
        tap(app.sheets.buttons["Export and Move"])
        XCTAssertTrue(anyContaining("Moved 1 tenant").waitForExistence(timeout: 600), "The move did not finish")
        tap(app.sheets.buttons["Done"])
        openTenant(Self.tenant)
        XCTAssertTrue(anyContaining("moved to the Terraform repository").waitForExistence(timeout: 10),
                      "The tenant is not shown as moved")
    }

    func test04RemoveTenantAndCatalog() throws {
        removeTenant(Self.tenant)
        removeCatalogSources(named: Self.catalogName)
    }

    // MARK: Helpers

    /// The sheet's form scrolls under its footer; controls further down are
    /// scrolled up before use.
    private func scrollIntoView(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) is not in the sheet")
        let form = app.sheets.scrollViews.firstMatch
        let footerTop = app.sheets.buttons["Cancel"].frame.minY
        var attempts = 0
        while (!element.isHittable || element.frame.maxY > footerTop - 4), attempts < 20 {
            form.scroll(byDeltaX: 0, deltaY: -80)
            attempts += 1
        }
    }

    private func openExportSheet() {
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Export as Terraform…"], timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10))
    }

    /// Ticks the test tenant (and only it) and picks the folder through the
    /// open panel's Go to Folder field.
    private func chooseTenantAndFolder(_ path: String) {
        for checkbox in app.sheets.checkBoxes.allElementsBoundByIndex
        where !checkbox.label.hasPrefix(Self.tenant) && checkbox.label != "Stop managing these tenants in this app"
            && (checkbox.value as? Int) == 1 {
            checkbox.click()
        }
        let mine = app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", Self.tenant)).firstMatch
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
