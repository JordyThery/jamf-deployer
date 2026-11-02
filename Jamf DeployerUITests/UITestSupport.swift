import XCTest
import AppKit
import JTKitUITestSupport

/// Jamf Deployer's UI test helpers on top of JTKit's (launching the Debug
/// build, finding and driving elements, the failure dump and screenshot).
/// The demo smoke tests use the class as it is; the live UI tests
/// (`LiveDeployerUITestCase`) add the release check's gateway.
class DeployerUITestCase: JTKitUITestCase {
    override var appName: String { "Jamf Deployer" }

    // The guided tour would cover the window on a reset Mac.
    override var demoLaunchArguments: [String] { ["-hasSeenGuidedTour", "YES"] }

    override func didLaunch() {
        // A larger window keeps long forms on screen (clicks need a hit point).
        let window = app.windows["main"].firstMatch
        if window.waitForExistence(timeout: 10), window.frame.height < 800 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    // MARK: Navigation

    func openTenant(_ name: String, tab: String = "Overview") {
        // A click while a text field is editing only ends editing, and right
        // after connecting the page can take a few seconds to appear; retry
        // until it shows.
        let page = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        for _ in 0..<5 {
            openSidebar(name)
            if page.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(page.exists, "Tenant page \(name) did not open")
        let segment = app.radioButtons[tab].firstMatch
        if segment.waitForExistence(timeout: 5) { segment.click() }
    }

    // MARK: Connect a Tenant

    /// Connects a tenant over the Jamf Platform API through the wizard
    /// (File › Connect a Tenant…). The secret is pasted, never typed.
    func connectPlatform(name: String, region: String, clientID: String, secret: String, environmentID: String) {
        if app.outlines.staticTexts[name].exists { return }
        // File › Connect a Tenant… (⌘N), else the sidebar's button
        app.typeKey("n", modifierFlags: .command)
        if !field("Contoso Production").waitForExistence(timeout: 5) {
            tap(app.buttons["Connect a Tenant…"].firstMatch, timeout: 10)
        }
        type(name, into: field("Contoso Production"))
        // the region menu shows its display name; the wizard starts on Europe
        let regionMenu = app.sheets.popUpButtons
            .matching(NSPredicate(format: "value IN %@", ["Europe", "United States", "Asia-Pacific"])).firstMatch
        tap(regionMenu, timeout: 10)
        tap(app.menuItems[Self.regionName(region)], timeout: 5)
        tap(app.sheets.buttons["Continue"])
        tap(app.sheets.buttons["Continue"])

        paste(clientID, into: field("d5e385c3"))
        paste(secret, into: app.sheets.secureTextFields.firstMatch)
        paste(environmentID, into: field("e77c1408"))
        tap(app.sheets.buttons["Continue"])
        // the optional Jamf Protect step, then the preflight
        tap(app.sheets.buttons["Run Preflight"], timeout: 10)
        tap(app.sheets.buttons["Add Tenant"], timeout: 180)
        XCTAssertTrue(app.outlines.staticTexts[name].waitForExistence(timeout: 20), "\(name) isn't in the sidebar")
    }

    /// The wizard's name for a region code ("us", "eu", "apac").
    static func regionName(_ code: String) -> String {
        switch code.lowercased() {
        case "eu": "Europe"
        case "apac": "Asia-Pacific"
        default: "United States"
        }
    }

    /// Removes a tenant from the sidebar; a managed tenant asks for its name.
    func removeTenant(_ name: String) {
        let row = app.outlines.staticTexts[name].firstMatch
        guard row.waitForExistence(timeout: 5) else { return }
        row.rightClick()
        tap(app.menuItems["Remove Tenant…"])
        let nameField = app.dialogs.textFields.firstMatch.exists ? app.dialogs.textFields.firstMatch : app.sheets.textFields.firstMatch
        if nameField.waitForExistence(timeout: 3) {
            type(name, into: nameField)
            tap(dialogButton("Remove Tenant"), timeout: 10)
        } else {
            tap(dialogButton("Remove Tenant"), timeout: 10)
        }
        XCTAssertTrue(row.waitForNonExistence(timeout: 120), "\(name) is still in the sidebar")
    }

    // MARK: Building blocks

    /// The baseline editor's checkbox for a catalog block, by its full
    /// label ("Name, summary"), never by a name prefix alone.
    func blockCheckbox(_ name: String) -> XCUIElement {
        app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    /// Ticks a block on the open tenant page (if it isn't yet).
    func tick(_ block: String, file: StaticString = #filePath, line: UInt = #line) {
        let checkbox = blockCheckbox(block)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 60), "\(block) isn't in the baseline editor", file: file, line: line)
        scrollIntoView(checkbox)
        if (checkbox.value as? Int) != 1 { checkbox.click() }
    }

    /// Unticks a block; a deployed one asks, and `removeFromTenant` picks
    /// Remove from Tenant (its objects are deleted on the next deploy).
    func untick(_ block: String, removeFromTenant: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let checkbox = blockCheckbox(block)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 30), "\(block) isn't in the baseline editor", file: file, line: line)
        scrollIntoView(checkbox)
        guard (checkbox.value as? Int) == 1 else { return }
        checkbox.click()
        let choice = dialogButton(removeFromTenant ? "Remove from Tenant" : "Stop Managing")
        if choice.waitForExistence(timeout: 3) { choice.click() }
    }

    /// Opens a block's settings: the Show Settings button on the block's row.
    func openSettings(of blockLabelPrefix: String) {
        let checkbox = blockCheckbox(String(blockLabelPrefix.hasSuffix(",") ? blockLabelPrefix.dropLast() : Substring(blockLabelPrefix)))
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10), "\(blockLabelPrefix) not listed")
        let buttons = app.buttons.matching(NSPredicate(format: "identifier == 'Show Settings'")).allElementsBoundByIndex
        let row = buttons.min { abs($0.frame.midY - checkbox.frame.midY) < abs($1.frame.midY - checkbox.frame.midY) }
        guard let button = row, abs(button.frame.midY - checkbox.frame.midY) < 30 else {
            // already open
            if app.buttons.matching(NSPredicate(format: "identifier == 'Hide Settings'")).firstMatch.exists { return }
            XCTFail("No Show Settings button next to \(blockLabelPrefix)")
            return
        }
        button.click()
    }

    /// Points an open block's scope menu at `group` (e.g. the empty static
    /// "Pilot" group, so a policy reaches no device).
    func chooseScope(_ group: String, current: [String], file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.popUpButtons.matching(NSPredicate(format: "value IN %@", current + ["Choose a group…", group])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "No scope menu", file: file, line: line)
        if (menu.value as? String) == group { return }
        menu.click()
        tap(app.menuItems[group].firstMatch, timeout: 5, file: file, line: line)
    }

    /// Removes every catalog source with this name (Manage Sources rows are
    /// matched by the row that shows the name, never by position).
    func removeCatalogSources(named name: String) {
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Manage Sources…"], timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            let label = app.sheets.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch
            guard label.waitForExistence(timeout: 2) else { break }
            let row = app.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove…' OR identifier == 'Remove…'")).allElementsBoundByIndex
                .min { abs($0.frame.midY - label.frame.midY) < abs($1.frame.midY - label.frame.midY) }
            guard let remove = row, abs(remove.frame.midY - label.frame.midY) < 30 else { break }
            remove.click()
            tap(dialogButton("Remove Source"), timeout: 10)
            sleep(1)
        }
        tap(app.sheets.buttons["Done"].exists ? app.sheets.buttons["Done"] : app.sheets.buttons["Close"], timeout: 5)
    }

    /// Stages an object through Add a Custom Object, filling the form's
    /// fields by attribute name (number fields show "0").
    func stageCustomObject(on tenantName: String, type typeName: String, objectName: String,
                           values: [String: String], numbers: [String: String] = [:], toggles: [String] = []) {
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
            scrollSheet(to: input)
            type(value, into: input)
        }
        for (attribute, value) in numbers.sorted(by: { $0.key < $1.key }) {
            // number fields carry the attribute as their label and "0" as placeholder
            let input = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == '0' AND (label == %@ OR identifier == %@)", attribute, attribute)).firstMatch
            let fallback = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == '0'")).firstMatch
            let target = input.waitForExistence(timeout: 3) ? input : fallback
            scrollSheet(to: target)
            type(value, into: target)
        }
        for attribute in toggles {
            let toggle = app.sheets.checkBoxes[attribute]
            scrollSheet(to: toggle)
            if (toggle.value as? Int) != 1 { toggle.click() }
        }
        tap(app.sheets.buttons["Stage Object"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 15), "The custom object wasn't staged")
    }

    /// A sheet's form scrolls; fields further down are scrolled to before use.
    func scrollSheet(to element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element) is not in the sheet")
        let form = app.sheets.scrollViews.firstMatch
        var attempts = 0
        while !element.isHittable, attempts < 30 {
            form.scroll(byDeltaX: 0, deltaY: -120)
            attempts += 1
        }
    }

    // MARK: Preview and deploy

    /// Waits until a preview sheet reaches its review step (or failed).
    @discardableResult
    func waitForReview(timeout: TimeInterval = 600) -> Bool {
        let deploy = app.sheets.buttons["Deploy"]
        let save = app.sheets.buttons["Save Recovery Sheet…"]
        let failed = app.sheets.buttons["Try Again"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if save.exists || deploy.exists { return true }
            if failed.exists {
                XCTFail("The preview failed: \(previewTexts())")
                return false
            }
            sleep(2)
        }
        return false
    }

    /// The open sheet's texts, for a failure message (labels only, never field values).
    func previewTexts() -> String {
        app.sheets.staticTexts.allElementsBoundByIndex.prefix(40)
            .map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }
            .joined(separator: " | ")
    }

    /// The preview's planned count for a kind ("create", "update", "remove",
    /// "adopt"), read from its summary line ("4 create · 1 adopt"); 0 if none.
    func plannedCount(_ kind: String) -> Int {
        let summary = app.sheets.staticTexts.matching(NSPredicate(format: "value MATCHES %@ OR label MATCHES %@",
                                                                  "(^|.* · )[0-9]+ \(kind)( · .*|$)", "(^|.* · )[0-9]+ \(kind)( · .*|$)")).firstMatch
        guard summary.waitForExistence(timeout: 5) else { return 0 }
        let text = (summary.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? summary.label
        for part in text.components(separatedBy: " · ") where part.hasSuffix(" \(kind)") {
            return Int(part.dropLast(kind.count + 1)) ?? 0
        }
        return 0
    }

    /// Waits for the review step and saves the recovery sheet when asked
    /// (a tenant's first deploy) into the test's folder; then the summary
    /// line (`plannedCount`) and Deploy show.
    @discardableResult
    func reachReview(timeout: TimeInterval = 600) -> Bool {
        guard waitForReview(timeout: timeout) else { return false }
        let save = app.sheets.buttons["Save Recovery Sheet…"]
        if save.exists {
            tap(save, timeout: 10)
            saveInTestFolder()
            return app.sheets.buttons["Deploy"].waitForExistence(timeout: 30)
        }
        return true
    }

    /// Saves the recovery sheet when asked, then deploys.
    func deployCurrentPreview() {
        XCTAssertTrue(reachReview(), "Preview did not finish (or the recovery sheet wasn't saved)")
        tap(app.sheets.buttons["Deploy"], timeout: 15)
    }

    /// Confirms an open Save panel in the test's own folder.
    func saveInTestFolder() {
        let panel = app.buttons["OKButton"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "No save panel")
        goToFolder(testFolder.path)
        saveInChosenFolder()
    }

    /// Kept for older call sites: the folder is always the test's own.
    func saveInDocuments() {
        saveInTestFolder()
    }

    /// Waits for a deploy to finish and closes the sheet; returns whether
    /// it reported no failures.
    @discardableResult
    func finishDeploy(timeout: TimeInterval = 900, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let done = app.sheets.buttons["Done"]
        let next = app.sheets.buttons["Continue"]
        let failed = anyContaining("Deploy Failed")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done.exists, !next.exists, !failed.exists { sleep(2) }
        guard done.exists || next.exists else {
            XCTFail("The deploy didn't finish: \(previewTexts())", file: file, line: line)
            if app.sheets.buttons["Close"].exists { app.sheets.buttons["Close"].click() }
            return false
        }
        let clean = anyContaining(" 0 failed").exists
        if !clean { XCTFail("The deploy reported failures: \(previewTexts())", file: file, line: line) }
        if done.exists { done.click() }
        return clean
    }

    /// Opens Preview Changes… for the open tenant, deploys, and waits for Done.
    @discardableResult
    func previewAndDeploy(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        openPreview()
        deployCurrentPreview()
        return finishDeploy(file: file, line: line)
    }

    /// Opens Preview Changes… for the open tenant.
    func openPreview() {
        tap(app.toolbars.buttons["Preview Changes…"], timeout: 30)
    }

    /// Closes an open preview without deploying.
    func closePreview() {
        tap(app.sheets.buttons["Close"], timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 15), "The preview did not close")
    }

    // MARK: Check for Changes

    /// Runs Check for Changes on a tenant and checks whether it found any.
    func checkForChanges(on tenant: String, expectingChanges: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        openTenant(tenant)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 60, file: file, line: line)
        // The button is dimmed while the check runs.
        sleep(2)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: check)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 1200), .completed, "The check didn't finish", file: file, line: line)
        sleep(2)
        let failure = anyContaining("The last check for changes failed")
        if failure.exists {
            XCTFail("The check failed: \(failure.label.isEmpty ? (failure.value as? String ?? "") : failure.label)", file: file, line: line)
            return
        }
        let changed = any("Changed in Jamf")
        if expectingChanges {
            XCTAssertTrue(changed.waitForExistence(timeout: 30), "No changes were detected", file: file, line: line)
        } else {
            XCTAssertFalse(changed.waitForExistence(timeout: 5), "Changes were reported on an unchanged tenant", file: file, line: line)
        }
    }

    // MARK: Rollout

    /// Opens Roll Out…, optionally picks what to roll out, sets each listed
    /// tenant's ring (unlisted tenants are left out) and starts.
    func startRollout(rings: [String: Int], change: String? = nil) {
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Roll Out…"], timeout: 10)
        if let change {
            let radio = app.sheets.radioButtons.matching(NSPredicate(format: "label CONTAINS %@", change)).firstMatch
            XCTAssertTrue(radio.waitForExistence(timeout: 10), "No option \(change)")
            radio.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        }
        let popups = app.sheets.popUpButtons.matching(NSPredicate(format: "value BEGINSWITH 'Ring'"))
        XCTAssertTrue(popups.firstMatch.waitForExistence(timeout: 10))
        let toggles = app.sheets.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
                                                                                   XCUIElement.ElementType.switch.rawValue,
                                                                                   XCUIElement.ElementType.checkBox.rawValue))
            .allElementsBoundByIndex
        for popup in popups.allElementsBoundByIndex {
            // the row's tenant: the popup's label ("Ring for <name>"), else the text on its line
            let name = rings.keys.first { popup.label == "Ring for \($0)" }
                ?? rings.keys.first { name in
                    app.sheets.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name))
                        .allElementsBoundByIndex.contains { abs($0.frame.midY - popup.frame.midY) < 14 }
                }
            guard let include = toggles.first(where: { abs($0.frame.midY - popup.frame.midY) < 14 }) else { continue }
            let wanted = name != nil
            if ((include.value as? Int) == 1) != wanted { include.click() }
            if let name, let ring = rings[name], (popup.value as? String) != "Ring \(ring)" {
                popup.click()
                tap(app.menuItems["Ring \(ring)"])
            }
        }
        tap(app.sheets.buttons["Start Rollout"])
    }

    // MARK: Export as Terraform

    func openExportSheet() {
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Export as Terraform…"], timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10))
    }

    /// Ticks `tenant` (and only it) in the export sheet and picks the folder
    /// through the open panel's Go to Folder field.
    func chooseTenantAndFolder(_ tenant: String, _ path: String) {
        for checkbox in app.sheets.checkBoxes.allElementsBoundByIndex
        where !checkbox.label.hasPrefix(tenant) && checkbox.label != "Stop managing these tenants in this app"
            && checkbox.label != "I understand that the state on GitHub isn’t encrypted"
            && (checkbox.value as? Int) == 1 {
            checkbox.click()
        }
        let mine = app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", tenant)).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "The tenant is not offered")
        if (mine.value as? Int) != 1 { mine.click() }

        tap(app.sheets.buttons["Choose…"])
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The folder panel did not open")
        goToFolder(path)
        tap(app.dialogs.buttons["Choose"].firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining((path as NSString).lastPathComponent).waitForExistence(timeout: 10), "The folder was not chosen")
    }
}
