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
        // EXPORT_CONNECTION=jamfpro runs the suite on a Jamf Pro API tenant.
        if ProcessInfo.processInfo.environment["EXPORT_CONNECTION"] == "jamfpro" {
            try connectJamfPro(name: Self.tenant, prefix: "JPX")
        } else {
            try connect(name: Self.tenant, prefix: "SBX")
        }
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
        // EXPORT_EXTRAS=1 adds the Jamf Protect baseline, Security Cloud
        // (using the tenant's existing UEM Connect) and the test catalog's
        // block with a secret setting (EXPORT_SECRET).
        let extras = ProcessInfo.processInfo.environment["EXPORT_EXTRAS"] == "1"
        var blocks = ["Categories, Applications, Enrollment", "Extension Attributes, A Baseline Marker"]
        if extras {
            blocks += ["Jamf Protect Baseline, Endpoint security", "Security Cloud, Connects Jamf Security Cloud", "UIT Secret Marker, "]
        }
        for block in blocks {
            let checkbox = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", block)).firstMatch
            XCTAssertTrue(checkbox.waitForExistence(timeout: 90), "\(block) is not in the library")
            if (checkbox.value as? Int) != 1 { checkbox.click() }
        }
        if extras {
            // EXPORT_UEM_CONNECT=create lets the block make the connection.
            if ProcessInfo.processInfo.environment["EXPORT_UEM_CONNECT"] != "create" {
                let uemConnect = app.popUpButtons.matching(NSPredicate(format: "value == 'Connect this Jamf Pro tenant'")).firstMatch
                openSettings(until: uemConnect)
                uemConnect.click()
                tap(app.menuItems["Use the existing connection"])
            }
            let token = app.secureTextFields["Test token"]
            openSettings(until: token)
            paste(try env("EXPORT_SECRET"), into: token)
            app.typeKey(.tab, modifierFlags: [])
        }
        stageCustomCategory(on: Self.tenant, objectName: "export_custom", name: "UIT EX - Custom", priority: "5")
        previewAndDeploy()
        let created = ProcessInfo.processInfo.environment["EXPORT_UEM_CONNECT"] == "create"
        XCTAssertTrue(anyContaining(extras ? (created ? "14 succeeded" : "13 succeeded") : "7 succeeded").waitForExistence(timeout: 15),
                      "The baseline did not deploy")
    }

    /// With technical details on (set by the script), the tenant page names
    /// each section's Terraform equivalent, and a preview shows the commands
    /// it ran and the generated configuration.
    func test01bPreviewShowsTheEngineWork() throws {
        openTenant(Self.tenant)
        for term in ["Terraform: the jamf", "Terraform: one module block per building block",
                     "Terraform: resources in the state", "Terraform: the last apply"] {
            XCTAssertTrue(anyContaining(term).waitForExistence(timeout: 10), "The tenant page does not show \"\(term)\"")
        }
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        XCTAssertTrue(anyContaining("Behind this preview").waitForExistence(timeout: 300), "The preview shows no engine details")
        XCTAssertTrue(anyContaining("tofu plan -input=false -out=plan.bin -json").exists, "The plan command is not shown")
        XCTAssertTrue(anyContaining("tofu apply -input=false -json").exists, "The deploy command is not shown")
        XCTAssertTrue(app.buttons["Show Workspace in Finder"].exists)
        tap(app.sheets.buttons["Close"])
    }

    func test02ExportForReview() throws {
        openExportSheet()
        chooseTenantAndFolder(Self.tenant, try env("EXPORT_REVIEW_DIR"))
        tap(app.sheets.buttons["Export"])
        XCTAssertTrue(anyContaining("Exported 1 tenant").waitForExistence(timeout: 300), "The export did not finish")
        tap(app.sheets.buttons["Done"])
    }

    func test03MoveToRepository() throws {
        openExportSheet()
        chooseTenantAndFolder(Self.tenant, try env("EXPORT_MOVE_DIR"))
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
        // Ends with the outcome, or with the sheet's error (shown in the failure).
        let moved = anyContaining("Moved 1 tenant")
        let failure = app.sheets.descendants(matching: .any)["exportError"]
        let deadline = Date.now.addingTimeInterval(600)
        while !moved.exists, !failure.exists, Date.now < deadline { sleep(2) }
        if !moved.exists {
            let texts = app.sheets.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
            XCTFail("The move did not finish: \(failure.exists ? failure.label : "timed out") | \(texts.joined(separator: " | "))")
        }
        tap(app.sheets.buttons["Done"])
        openTenant(Self.tenant)
        XCTAssertTrue(anyContaining("moved to the Terraform repository").waitForExistence(timeout: 10),
                      "The tenant is not shown as moved")
        XCTAssertTrue(app.links["Open Repository"].exists || app.buttons["Open Repository"].exists,
                      "The moved tenant has no Open Repository link")
    }

    func test04RemoveTenantAndCatalog() throws {
        removeTenant(Self.tenant)
        removeCatalogSources(named: Self.catalogName)
    }

    // MARK: Helpers

    /// Settings open one block at a time: opens each selected block's
    /// settings until `element` shows.
    private func openSettings(until element: XCUIElement) {
        let toggles = app.buttons.matching(NSPredicate(format: "label IN {'Show Settings', 'Hide Settings'}"))
        for index in 0..<toggles.count where !element.exists {
            let toggle = toggles.element(boundBy: index)
            if toggle.label == "Show Settings" {
                toggle.click()
                sleep(1)
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) is not in any block's settings")
    }

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
}
