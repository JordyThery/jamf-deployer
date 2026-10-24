import XCTest

/// A catalog release that renames a group another block scopes to. The
/// engine deletes the old group before it updates the policy that still uses
/// it; the deploy must still finish without failures. Steps run in name
/// order; Scripts/run-rename-ui-tests.sh prepares the two-release catalog,
/// runs them and cleans up.
final class RenameUITests: DeployerUITestCase {
    static let tenant = "UI Rename"
    static let catalogName = "UI Rename Catalog"
    static let prefix = "UIT RN - "

    func test1ConnectAndSetPrefix() throws {
        try connect(name: Self.tenant, prefix: "RNM")
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
        tap(app.menuItems["v1.0.0"])
        tap(app.sheets.buttons["Add Catalog"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 60), "Catalog was not added")
    }

    func test3DeployFirstRelease() throws {
        openTenant(Self.tenant)
        for name in ["Rename Groups", "Rename Policy"] {
            let block = blockCheckbox(name)
            XCTAssertTrue(block.waitForExistence(timeout: 30), "\(name) not in the baseline editor")
            if (block.value as? Int) != 1 { block.click() }
        }
        previewAndDeployExpectingNoFailures()
    }

    func test4DeployRenamingRelease() throws {
        openTenant(Self.tenant)
        tap(app.buttons["Baseline Updates…"], timeout: 10)
        XCTAssertTrue(anyContaining("v1.0.1").waitForExistence(timeout: 60), "The renaming release is not offered")
        tap(app.sheets.buttons["Stage Selected Updates"], timeout: 10)
        previewAndDeployExpectingNoFailures()
    }

    func test5RemoveTenantAndCatalog() throws {
        removeTenant(Self.tenant)
        removeCatalogSources(named: Self.catalogName)
    }

    private func previewAndDeployExpectingNoFailures(file: StaticString = #filePath, line: UInt = #line) {
        tap(app.toolbars.buttons["Preview Changes"], timeout: 10)
        deployCurrentPreview()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 300), "Deploy did not finish", file: file, line: line)
        XCTAssertTrue(anyContaining(" 0 failed").exists, "The deploy reported failures", file: file, line: line)
        tap(app.buttons["Done"])
    }
}
