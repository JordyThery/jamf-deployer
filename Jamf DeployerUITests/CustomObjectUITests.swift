import XCTest

/// Custom objects beyond categories, through both connections to the same
/// test instance: a script and a computer extension attribute are staged
/// from the schema-built form, deployed, checked, changed in Jamf, detected
/// and restored. Steps run in name order; Scripts/run-custom-object-ui-tests.sh
/// checks the objects in Jamf, changes them between steps and cleans up.
final class CustomObjectUITests: DeployerUITestCase {
    static let platform = "CO Platform"
    static let jamfPro = "CO Jamf Pro"

    func test01Connect() throws {
        try connect(name: Self.platform, prefix: "SBX")
        try connectJamfPro(name: Self.jamfPro, prefix: "JPSBX")
    }

    func test02DeployThroughThePlatformAPI() throws {
        stageCustomObject(on: Self.platform, type: "jamfplatform_pro_script", objectName: "co_script", values: [
            "name": "UIT - CO Platform Script",
            "priority": "AFTER",
            "script_contents": "echo UIT",
        ])
        stageCustomObject(on: Self.platform, type: "jamfplatform_pro_computer_extension_attribute", objectName: "co_attribute", values: [
            "name": "UIT - CO Platform Attribute",
            "data_type": "STRING",
            "input_type": "TEXT",
            "inventory_display": "GENERAL",
        ])
        previewAndDeploy()
        XCTAssertTrue(anyContaining("2 succeeded").waitForExistence(timeout: 15), "The objects did not deploy")
    }

    func test03DeployThroughTheJamfProAPI() throws {
        stageCustomObject(on: Self.jamfPro, type: "jamfpro_script", objectName: "co_script", values: [
            "name": "UIT - CO Jamf Pro Script",
            "priority": "AFTER",
            "script_contents": "echo UIT",
        ])
        stageCustomObject(on: Self.jamfPro, type: "jamfpro_computer_extension_attribute", objectName: "co_attribute", values: [
            "name": "UIT - CO Jamf Pro Attribute",
            "data_type": "STRING",
            "input_type": "TEXT",
            "inventory_display_type": "GENERAL",
        ], toggles: ["enabled"])
        previewAndDeploy()
        XCTAssertTrue(anyContaining("2 succeeded").waitForExistence(timeout: 15), "The objects did not deploy")
    }

    func test04NoChangesAfterDeploy() throws {
        try checkForChanges(on: Self.platform, expectingChanges: false)
        try checkForChanges(on: Self.jamfPro, expectingChanges: false)
    }

    /// Precondition (set by the script): every object changed in Jamf.
    func test05DetectAndRestore() throws {
        for tenant in [Self.platform, Self.jamfPro] {
            try checkForChanges(on: tenant, expectingChanges: true)
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value == 'Changed in Jamf' OR label == 'Changed in Jamf'")).count, 2,
                           "Not every changed object was reported on \(tenant)")
            tap(app.buttons["Restore Baseline…"], timeout: 30)
            deployCurrentPreview()
            tap(app.buttons["Done"], timeout: 600)
            try checkForChanges(on: tenant, expectingChanges: false)
        }
    }

    func test06RemoveTenants() throws {
        removeTenant(Self.platform)
        removeTenant(Self.jamfPro)
    }

    // MARK: Helpers

    /// Stages an object through Add a Custom Object, filling the form's
    /// fields by attribute name.
    private func stageCustomObject(on tenantName: String, type typeName: String, objectName: String,
                                   values: [String: String], toggles: [String] = []) {
        openTenant(tenantName)
        tap(app.buttons["Add a Custom Object…"], timeout: 30)
        let filter = field("Filter object types")
        XCTAssertTrue(filter.waitForExistence(timeout: 180), "Object types did not load")
        filter.click()
        filter.typeText(typeName)
        tap(app.sheets.staticTexts.matching(NSPredicate(format: "value == %@", typeName)).firstMatch, timeout: 30)
        type(objectName, into: field("my_custom_object"))
        for (attribute, value) in values.sorted(by: { $0.key < $1.key }) {
            let input = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == %@", attribute)).firstMatch
            scrollIntoView(input)
            type(value, into: input)
        }
        for attribute in toggles {
            let toggle = app.sheets.checkBoxes[attribute]
            scrollIntoView(toggle)
            if (toggle.value as? Int) != 1 { toggle.click() }
        }
        tap(app.buttons["Stage Object"])
    }

    /// The form scrolls; fields further down are scrolled to before use.
    private func scrollIntoView(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element) is not in the form")
        let form = app.sheets.scrollViews.firstMatch
        var attempts = 0
        while !element.isHittable, attempts < 30 {
            form.scroll(byDeltaX: 0, deltaY: -120)
            attempts += 1
        }
    }

    private func checkForChanges(on tenant: String, expectingChanges: Bool) throws {
        openTenant(tenant)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 60)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: check)
        waitForExpectations(timeout: 600)
        sleep(2)
        let failure = anyContaining("The last check for changes failed")
        if failure.exists {
            XCTFail("The check failed on \(tenant): \(failure.label.isEmpty ? (failure.value as? String ?? "") : failure.label)")
            return
        }
        let changed = any("Changed in Jamf")
        if expectingChanges {
            XCTAssertTrue(changed.waitForExistence(timeout: 30), "No changes were detected on \(tenant)")
        } else {
            XCTAssertFalse(changed.waitForExistence(timeout: 5), "Changes were reported on unchanged \(tenant)")
        }
    }
}
