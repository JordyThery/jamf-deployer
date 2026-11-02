import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// the same answers every run, no tenant, nothing saved. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
final class DemoSmokeUITests: DeployerUITestCase {
    private let contoso = "Contoso (Demo)"

    override func launchApp() {
        launchInDemo()
    }

    func test1Launch() {
        let main = app.windows["main"].firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        XCTAssertTrue(app.outlines.staticTexts[contoso].waitForExistence(timeout: 20), "The demo fleet isn't in the sidebar")
        XCTAssertTrue(app.outlines.staticTexts["Contoso Lab (Demo)"].exists, "Contoso Lab is missing")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Team", "Advanced", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Jamf Deployer's + opens the Connect wizard (it checks a real
        // tenant), so the editor is opened and the wizard cancelled.
        checkConnectionsEditorOpens()
    }

    /// Contoso: Check for Changes finds the Teams change, Preview shows the
    /// fixed plan, Deploy is dimmed.
    func test5MainTask() {
        checkForChangesOnContoso()

        tap(app.toolbars.buttons["Preview Changes…"], timeout: 10)
        let unavailable = anyContaining("Deploying isn’t available in Demo Mode.")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 60), "The preview didn't reach its review step")
        XCTAssertTrue(anyContaining("Reverts the change found in Jamf").exists, "The Teams update isn't in the plan")
        let deploy = app.sheets.buttons["Deploy"].firstMatch
        XCTAssertTrue(deploy.exists, "No Deploy button")
        XCTAssertFalse(deploy.isEnabled, "Deploy must be dimmed in Demo Mode")
        tap(app.sheets.buttons["Close"].firstMatch)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "The preview did not close")
    }

    func test6ActivityLog() {
        checkForChangesOnContoso()
        checkActivityLog()
    }

    func test7DemoTitles() {
        XCTAssertTrue(app.windows["main"].firstMatch.waitForExistence(timeout: 20))
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    // MARK: Drift on a tenant

    /// Contoso: Keep This Change on the Teams change takes it off the list
    /// and says what happened to it.
    func test8KeepThisChange() {
        checkForChangesOnContoso()
        tap(mainWindow.buttons["Keep This Change"], timeout: 10)
        let kept = anyContaining("kept — the baseline setting now uses this value.")
        let noted = anyContaining("noted — a future deploy would still restore the baseline value.")
        XCTAssertTrue(wait(forEither: kept, noted, timeout: 10), "Keep This Change left no note")
        XCTAssertTrue(any("Changed in Jamf").waitForNonExistence(timeout: 10), "The kept change is still listed")
    }

    /// Contoso: Restore Baseline… opens the preview with the demo plan, which
    /// reverts the Teams change and stops before deploying.
    func test9RestoreBaseline() {
        checkForChangesOnContoso()
        let restore = mainWindow.buttons["Restore Baseline…"]
        scrollIntoView(restore)
        tap(restore, timeout: 10)
        checkDemoPreviewAndClose()
    }

    // MARK: Fleet

    /// Tenant › Check All Tenants: both tenants are checked, Contoso shows
    /// its change, the lab is in sync, and the token columns show the expiry
    /// dates the check read (none within 30 days in the demo data).
    func test10CheckAllTenantsAndTokenColumns() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20))
        openSidebar("Dashboard")
        XCTAssertTrue(any("ADE token").waitForExistence(timeout: 10), "No ADE token column")
        XCTAssertTrue(any("Apps and Books token").exists, "No Apps and Books token column")
        XCTAssertTrue(any("Not checked yet").waitForExistence(timeout: 10), "The demo tenants start unchecked")

        tap(app.menuBars.menuBarItems["Tenant"])
        tap(app.menuBars.menuItems["Check All Tenants"], timeout: 10)

        XCTAssertTrue(any("In sync").waitForExistence(timeout: 60), "Contoso Lab isn’t shown in sync")
        XCTAssertTrue(any("1 change made in Jamf").waitForExistence(timeout: 30), "Contoso’s change isn’t shown")
        XCTAssertFalse(any("Not checked yet").exists, "A tenant wasn’t checked")
        XCTAssertFalse(any("Check failed").exists, "A check failed")
        let checkAll = app.toolbars.buttons["Check All Tenants"]
        XCTAssertTrue(checkAll.waitForExistence(timeout: 20), "The fleet check didn’t finish")

        // ADE: "2027-06-30" on both demo servers (a plain date, read in local time).
        let ade = Calendar.current.date(from: DateComponents(year: 2027, month: 6, day: 30)) ?? .now
        XCTAssertTrue(any(shortDate(ade)).waitForExistence(timeout: 20), "The ADE token expiry isn’t shown")
        // Apps and Books: a year from today at midnight UTC, so the local day may differ by one.
        let inAYear = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: .now) ?? .now
        let vppDays = [-1, 0, 1].compactMap { Calendar.current.date(byAdding: .day, value: $0, to: inAYear) }
        XCTAssertTrue(vppDays.contains { any(shortDate($0)).exists }, "The Apps and Books token expiry isn’t shown")
        // A warning only for a token that expires within 30 days.
        XCTAssertFalse(anyContaining("renew it soon").exists, "A token more than 30 days out is flagged")
        XCTAssertFalse(anyContaining("renew it in Jamf Pro").exists, "A valid token is shown as expired")
    }

    /// Contoso's Overview: Run Preflight signs in and every permission row passes.
    func test11RunPreflight() {
        openDemoTenant(contoso)
        let run = mainWindow.buttons["Run Preflight"]
        scrollIntoView(run)
        tap(run, timeout: 10)
        XCTAssertTrue(any("Signed in to the Jamf Platform API.").waitForExistence(timeout: 30), "Credentials didn’t pass")
        // The button reads "Checking…" while the checks run.
        XCTAssertTrue(waitEnabled(mainWindow.buttons["Run Preflight"], timeout: 30), "The preflight didn’t finish")
        for title in ["Credentials", "Read categories", "Read scripts", "Read Automated Device Enrollment", "Read Apps and Books"] {
            XCTAssertTrue(any(title).exists, "No preflight row \(title)")
        }
        let allowed = app.staticTexts.matching(NSPredicate(format: "value == 'Allowed.' OR label == 'Allowed.'")).count
        XCTAssertGreaterThanOrEqual(allowed, 4, "Not every permission row passed")
        XCTAssertFalse(anyContaining("Not allowed.").exists, "A permission row failed")
        XCTAssertFalse(anyContaining("Couldn’t check").exists, "A permission row couldn’t be checked")
    }

    // MARK: Tenants

    /// File › Connect a Tenant…: the wizard fills in the demo credentials,
    /// lists Contoso's environment, runs the preflight and adds the tenant;
    /// Tenant › Remove Tenant… removes it again.
    func test12ConnectAndRemoveTenant() {
        let name = "Smoke Test Tenant"
        XCTAssertTrue(app.outlines.staticTexts[contoso].waitForExistence(timeout: 20))
        tap(app.menuBars.menuBarItems["File"])
        tap(app.menuBars.menuItems["Connect a Tenant…"])
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "The wizard didn’t open")

        type(name, into: field("Contoso Production"))
        tap(app.sheets.buttons["Continue"])
        tap(app.sheets.buttons["Continue"], timeout: 10)
        XCTAssertTrue(anyContaining("Contoso’s demo credentials are filled in").waitForExistence(timeout: 10),
                      "No demo credentials note")
        XCTAssertEqual(field("d5e385c3").value as? String, "contoso-demo-client", "The demo client ID isn’t filled in")
        tap(app.sheets.buttons["Fetch Environments from Jamf Account"], timeout: 10)
        let environment = app.sheets.popUpButtons.matching(NSPredicate(format: "value == 'Contoso'")).firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 20), "Contoso’s environment isn’t listed")

        tap(app.sheets.buttons["Continue"], timeout: 10)
        tap(app.sheets.buttons["Run Preflight"], timeout: 10)
        XCTAssertTrue(any("Signed in to the Jamf Platform API.").waitForExistence(timeout: 30), "The wizard’s preflight didn’t sign in")
        tap(app.sheets.buttons["Add Tenant"], timeout: 30)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "The wizard didn’t close")
        let row = app.outlines.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The new tenant isn’t in the sidebar")

        openSidebar(name)
        XCTAssertTrue(window(titled: name).waitForExistence(timeout: 10), "The new tenant didn’t open")
        tap(app.menuBars.menuBarItems["Tenant"])
        tap(app.menuBars.menuItems["Remove Tenant…"], timeout: 10)
        tap(dialogButton("Remove Tenant"), timeout: 10)
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "The tenant wasn’t removed")
        XCTAssertTrue(app.outlines.staticTexts[contoso].exists, "Removing the new tenant removed Contoso")
    }

    /// Contoso Lab: Update Client Secret… saves, and opening it again shows no error.
    func test13UpdateClientSecret() {
        openDemoTenant(lab)
        let update = mainWindow.buttons["Update Client Secret…"]
        scrollIntoView(update)
        tap(update, timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "The sheet didn’t open")
        XCTAssertTrue(app.sheets.staticTexts["Update Client Secret"].exists, "Not the Update Client Secret sheet")
        let secret = app.sheets.secureTextFields.firstMatch
        type("demo-rotated-secret", into: secret)
        tap(app.sheets.buttons["Save"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "Save didn’t close the sheet")

        tap(update, timeout: 10)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "The sheet didn’t open again")
        XCTAssertFalse(anyContaining("The Keychain refused").exists, "The sheet shows an error")
        tap(app.sheets.buttons["Cancel"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
    }

    // MARK: Baseline

    /// Contoso's baseline: select a block, fill its string setting, pick an
    /// existing group loaded from the demo server, deselect it; a deployed
    /// block asks Remove from Tenant or Stop Managing; the preset menu.
    func test14BaselineEditor() {
        openDemoTenant(contoso)
        let store = blockCheckbox("Mac App Store Apps")
        scrollIntoView(store, timeout: 20)
        XCTAssertEqual(store.value as? Int, 0, "Mac App Store Apps starts unselected")
        store.click()
        XCTAssertTrue(waitValue(store, 1), "The block wasn’t selected")

        // Its scope has no group yet, so its settings open by themselves.
        let location = mainWindow.textFields.matching(NSPredicate(format: "placeholderValue == 'Required'")).firstMatch
        if !location.waitForExistence(timeout: 5) { openSettings(of: "Mac App Store Apps,") }
        scrollIntoView(location)
        let missing = anyContaining("“Apps and Books location” needs a value")
        XCTAssertTrue(missing.waitForExistence(timeout: 5), "No warning for the empty required setting")
        type("Contoso Apps and Books", into: location)
        XCTAssertTrue(missing.waitForNonExistence(timeout: 10), "The filled-in setting still reads as missing")

        let scope = mainWindow.popUpButtons.matching(NSPredicate(format: "value == 'Choose a group…'")).firstMatch
        scrollIntoView(scope)
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "No scope picker")
        XCTAssertFalse(anyContaining("Existing groups and categories couldn’t be loaded").waitForExistence(timeout: 2),
                       "The demo server’s groups didn’t load")
        scope.click()
        tap(app.menuItems["All Managed Clients"], timeout: 20)
        XCTAssertTrue(mainWindow.popUpButtons.matching(NSPredicate(format: "value == 'All Managed Clients'")).firstMatch
            .waitForExistence(timeout: 10), "The group wasn’t chosen")
        XCTAssertFalse(anyContaining("Choose which group this block applies to").exists, "The scope still reads as missing")

        scrollIntoView(store)
        store.click()
        XCTAssertTrue(waitValue(store, 0), "The block wasn’t deselected")
        XCTAssertTrue(location.waitForNonExistence(timeout: 10), "The deselected block still shows its settings")

        // App Catalog was deployed: deselecting asks how.
        let catalogBlock = blockCheckbox("App Catalog")
        scrollIntoView(catalogBlock)
        XCTAssertEqual(catalogBlock.value as? Int, 1, "App Catalog isn’t selected on Contoso")
        catalogBlock.click()
        XCTAssertTrue(anyContaining("Remove “App Catalog” from the Baseline?").waitForExistence(timeout: 10),
                      "Deselecting a deployed block didn’t ask")
        XCTAssertTrue(dialogButton("Stop Managing").exists, "No Stop Managing choice")
        XCTAssertTrue(dialogButton("Remove from Tenant").exists, "No Remove from Tenant choice")
        tap(dialogButton("Cancel"))
        XCTAssertTrue(waitValue(catalogBlock, 1), "Cancel changed the baseline")

        // The built-in catalog has no presets: the menu offers saving one.
        let presets = mainWindow.menuButtons["Apply a Preset"]
        scrollIntoView(presets)
        tap(presets, timeout: 10)
        tap(app.menuItems["Save Current Baseline as Preset…"], timeout: 10)
        XCTAssertTrue(anyContaining("Presets are saved in a folder catalog source").waitForExistence(timeout: 10),
                      "Save as Preset didn’t open")
        tap(app.sheets.buttons["Cancel"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
    }

    /// Contoso's App Catalog block: its category picker lists the demo
    /// server's categories, the App Catalog picker searches titles, and the
    /// Mac App Store picker opens on the tenant's Apps and Books location.
    func test15BlockSettingsAndAppPickers() {
        openDemoTenant(contoso)
        let catalogBlock = blockCheckbox("App Catalog")
        scrollIntoView(catalogBlock, timeout: 20)
        openSettings(of: "App Catalog,")
        let category = mainWindow.popUpButtons.matching(NSPredicate(format: "value == 'Contoso Apps'")).firstMatch
        scrollIntoView(category)
        XCTAssertTrue(category.waitForExistence(timeout: 10), "No category picker with Contoso’s category")
        sleep(1)
        category.click()
        XCTAssertTrue(app.menuItems["Contoso Utilities"].waitForExistence(timeout: 20), "The demo server’s categories aren’t listed")
        app.typeKey(.escape, modifierFlags: [])

        let chooseApps = mainWindow.buttons["Choose Apps…"]
        scrollIntoView(chooseApps)
        tap(chooseApps, timeout: 10)
        XCTAssertTrue(anyContaining("App Catalog — \(contoso)").waitForExistence(timeout: 10), "The App Catalog picker didn’t open")
        type("1Password", into: field("Search apps and publishers"))
        XCTAssertTrue(app.sheets.staticTexts["1Password"].waitForExistence(timeout: 20), "Search didn’t list the title")
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'AgileBits' OR label BEGINSWITH 'AgileBits'"))
            .firstMatch.exists, "The title’s publisher isn’t shown")
        tap(app.sheets.buttons["Done"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))

        // Mac App Store Apps: the picker loads the tenant's location.
        let store = blockCheckbox("Mac App Store Apps")
        scrollIntoView(store)
        store.click()
        XCTAssertTrue(waitValue(store, 1), "Mac App Store Apps wasn’t selected")
        // Its scope has no group yet, so its settings open by themselves,
        // and App Catalog's close: one Choose Apps… button, this block's.
        let location = mainWindow.textFields.matching(NSPredicate(format: "placeholderValue == 'Required'")).firstMatch
        if !location.waitForExistence(timeout: 5) { openSettings(of: "Mac App Store Apps,") }
        XCTAssertTrue(location.waitForExistence(timeout: 10), "Mac App Store Apps’ settings didn’t open")
        let pick = mainWindow.buttons["Choose Apps…"]
        scrollIntoView(pick)
        tap(pick, timeout: 10)
        XCTAssertTrue(anyContaining("Mac App Store Apps — \(contoso)").waitForExistence(timeout: 10), "The App Store picker didn’t open")
        XCTAssertTrue(field("Filter licensed apps").waitForExistence(timeout: 10), "No filter field")
        // The demo server holds a location but no licensed content.
        let settled = [any("Apps and Books Unavailable"), any("No Licensed Apps"), app.sheets.buttons["Add"]]
        XCTAssertTrue(wait(forAnyOf: settled, timeout: 20), "The licensed apps didn’t load")
        tap(app.sheets.buttons["Done"])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
    }

    // MARK: Day 0 Setup

    /// Contoso Lab's Day 0 Setup detects its steps; on production Contoso,
    /// a write step asks first, and Cancel leaves it undone.
    func test16Day0Setup() {
        openDemoTenant(lab, tab: "Day 0 Setup")
        XCTAssertTrue(anyContaining("“Contoso Apple Business” connected").waitForExistence(timeout: 30),
                      "Day 0 didn’t detect the ADE instance")
        for title in ["Apple Push Notification certificate", "Automated Device Enrollment", "Apps and Books",
                      "Self Service branding", "Jamf Protect link", "Cloud Services Connection"] {
            XCTAssertTrue(anyContaining(title).waitForExistence(timeout: 10), "No Day 0 row \(title)")
        }

        openDemoTenant(contoso, tab: "Day 0 Setup")
        XCTAssertTrue(anyContaining("Optional. Link Jamf Protect").waitForExistence(timeout: 30), "The Protect step isn’t pending")
        let url = mainWindow.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'https://yourorg.protect'")).firstMatch
        scrollIntoView(url)
        type("https://contoso.protect.jamfcloud.com", into: url)
        type("smoke-client", into: mainWindow.textFields.matching(NSPredicate(format: "placeholderValue == 'API client ID'")).firstMatch)
        type("smoke-secret", into: mainWindow.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'API client secret'")).firstMatch)
        tap(mainWindow.buttons["Link Jamf Protect"], timeout: 10)
        XCTAssertTrue(anyContaining("Link Jamf Protect to “\(contoso)”?").waitForExistence(timeout: 10),
                      "A Day 0 write on a production tenant didn’t ask first")
        XCTAssertTrue(anyContaining("This is a production tenant").exists, "The question doesn’t say why")
        tap(dialogButton("Cancel"))
        XCTAssertTrue(anyContaining("Link Jamf Protect to").waitForNonExistence(timeout: 10), "The question didn’t close")
        XCTAssertTrue(anyContaining("Optional. Link Jamf Protect").exists, "Cancel still linked Jamf Protect")
        XCTAssertFalse(anyContaining("Registered with").exists, "Cancel still linked Jamf Protect")
    }

    // MARK: Library

    /// Building Blocks: a block card is a button (so the keyboard and
    /// VoiceOver reach it), opens its details sheet, and Escape closes it.
    func test17CatalogCardKeyboard() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20))
        openSidebar("Building Blocks")
        XCTAssertTrue(waitTitle("Building Blocks"), "Building Blocks didn’t open")
        let byLabel = mainWindow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'App Catalog'")).firstMatch
        let card = byLabel.waitForExistence(timeout: 10)
            ? byLabel
            : mainWindow.buttons.containing(NSPredicate(format: "value == 'App Catalog' OR label == 'App Catalog'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "No App Catalog card")

        XCTAssertEqual(card.elementType, .button, "The card isn’t exposed as a button")
        card.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "The card didn’t open the block’s details")
        XCTAssertTrue(app.sheets.staticTexts["App Catalog"].exists, "The sheet isn’t App Catalog’s")
        XCTAssertTrue(app.sheets.buttons["Close"].exists, "No Close button")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "Escape didn’t close the details")
    }

    /// History: the deploys of both demo tenants, and Roll Back… asks first
    /// (canceled). The demo store may hold no history; then the empty state shows.
    func test18History() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20))
        openSidebar("History")
        XCTAssertTrue(waitTitle("History"), "History didn’t open")
        let empty = any("No History Yet")
        let rollBack = mainWindow.buttons["Roll Back…"]
        XCTAssertTrue(wait(forEither: empty, rollBack, timeout: 10), "History shows neither entries nor its empty state")
        guard rollBack.exists else {
            XCTContext.runActivity(named: "Demo Mode holds no deploy history; Roll Back… not checked") { _ in }
            return
        }
        XCTAssertTrue(mainWindow.tables.staticTexts[contoso].exists, "No history for Contoso")
        XCTAssertTrue(mainWindow.tables.staticTexts[lab].exists, "No history for Contoso Lab")
        tap(rollBack)
        XCTAssertTrue(anyContaining("Roll Back “").waitForExistence(timeout: 10), "Roll Back… didn’t ask first")
        tap(dialogButton("Cancel"))
        XCTAssertTrue(anyContaining("Roll Back “").waitForNonExistence(timeout: 10), "The question didn’t close")
        XCTAssertFalse(any("Baseline Restored").exists, "Cancel still rolled back")
    }

    // MARK: Demo Mode, tour, menus

    /// The sidebar's Demo Mode marker and the window subtitle; the Tenant
    /// menu's Demo Mode switch is dimmed while a check runs; Turn Off
    /// leaves demo mode.
    func test19DemoModeMarkerAndTurnOff() {
        XCTAssertTrue(app.outlines.staticTexts[contoso].waitForExistence(timeout: 20))
        let marker = app.outlines.staticTexts["Demo Mode"]
        let turnOff = app.outlines.buttons["Turn Off"]
        XCTAssertTrue(marker.exists, "No Demo Mode marker in the sidebar")
        XCTAssertTrue(turnOff.exists, "No Turn Off button in the sidebar")
        let outline = app.outlines.firstMatch.frame
        let subtitle = mainWindow.staticTexts.matching(NSPredicate(format: "value == 'Demo Mode' OR label == 'Demo Mode'"))
            .allElementsBoundByIndex.contains { !outline.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        XCTAssertTrue(subtitle || mainWindow.title.contains("Demo"), "The window doesn’t say Demo Mode")

        // Idle: the switch is available.
        tap(app.menuBars.menuBarItems["Tenant"])
        let toggle = app.menuBars.menuItems["Demo Mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "No Demo Mode switch in the Tenant menu")
        XCTAssertTrue(toggle.isEnabled, "The Demo Mode switch is dimmed while nothing runs")
        app.typeKey(.escape, modifierFlags: [])

        // While a check runs it is dimmed. Demo answers are quick, so the
        // check may be over by the time the menu opens; then it must be on again.
        openSidebar("Dashboard")
        tap(app.toolbars.buttons["Check All Tenants"], timeout: 10)
        tap(app.menuBars.menuBarItems["Tenant"])
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let enabledWhileOpen = toggle.isEnabled
        let checkFinished = app.toolbars.buttons["Check All Tenants"].exists
            && app.toolbars.buttons["Check All Tenants"].isEnabled
        if enabledWhileOpen {
            XCTAssertTrue(checkFinished, "The Demo Mode switch isn’t dimmed while a check runs")
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(any("In sync").waitForExistence(timeout: 60), "The fleet check didn’t finish")

        // Turn Off: the marker goes, and the real (here throwaway) store shows.
        tap(turnOff, timeout: 20)
        XCTAssertTrue(turnOff.waitForNonExistence(timeout: 20), "Turn Off didn’t leave Demo Mode")
        XCTAssertFalse(marker.exists, "The Demo Mode marker is still shown")
        let tryDemo = app.outlines.buttons["Try Demo Mode"]
        if tryDemo.waitForExistence(timeout: 5) {
            // An empty store offers demo mode again: back on, Contoso returns.
            tap(tryDemo)
            XCTAssertTrue(app.outlines.buttons["Turn Off"].waitForExistence(timeout: 20), "Try Demo Mode didn’t turn it on")
            XCTAssertTrue(app.outlines.staticTexts[contoso].waitForExistence(timeout: 20), "The demo fleet didn’t return")
        }
    }

    /// Help › Guided Tour shows its steps, moves on and back, and Skip Tour closes it.
    func test20GuidedTour() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20))
        tap(app.menuBars.menuBarItems["Help"])
        tap(app.menuBars.menuItems["Guided Tour"], timeout: 10)
        let welcome = any("Welcome to Jamf Deployer")
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), "The tour didn’t start")
        XCTAssertTrue(anyContaining("Step 1 of 8").exists || anyContaining("1 / 8").exists, "The tour doesn’t say which step")
        tap(mainWindow.buttons["Next"])
        XCTAssertTrue(anyContaining("The dashboard lists every connected tenant").waitForExistence(timeout: 10),
                      "Next didn’t move to the Fleet step")
        tap(mainWindow.buttons["Back"])
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), "Back didn’t return to the first step")
        tap(mainWindow.buttons["Skip Tour"])
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 10), "Skip Tour didn’t close the tour")
    }

    /// View › Dashboard / Building Blocks / History (⌘1–⌘3) navigate;
    /// Tenant › Preview Changes… (⌘P) opens the preview for the selected tenant.
    func test21ViewAndTenantMenus() {
        XCTAssertTrue(app.outlines.staticTexts[contoso].waitForExistence(timeout: 20))
        for (item, title) in [("Building Blocks", "Building Blocks"), ("History", "History"), ("Dashboard", "Fleet")] {
            tap(app.menuBars.menuBarItems["View"])
            tap(app.menuBars.menuItems[item], timeout: 10)
            XCTAssertTrue(waitTitle(title), "View › \(item) didn’t open it (title: \(mainWindow.title))")
        }
        // ⌘1–3 aren't pressed: on a keyboard where digits need Shift
        // (Belgian, French), XCTest's typed "2" doesn't arrive as ⌘2.

        openDemoTenant(contoso)
        // Deploys always start from Preview: there's no Deploy… item.
        tap(app.menuBars.menuBarItems["Tenant"])
        XCTAssertFalse(app.menuBars.menuItems["Deploy…"].exists, "Tenant › Deploy… is still there")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("p", modifierFlags: .command)
        // while the preview sheet is open, the menus are dimmed
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 20), "⌘P didn’t open the preview")
        tap(app.menuBars.menuBarItems["Tenant"])
        XCTAssertFalse(app.menuBars.menuItems["Preview Changes…"].isEnabled, "Preview Changes… isn’t dimmed under the sheet")
        app.typeKey(.escape, modifierFlags: [])
        checkDemoPreviewAndClose()
        tap(app.menuBars.menuBarItems["Tenant"])
        tap(app.menuBars.menuItems["Preview Changes…"], timeout: 10)
        checkDemoPreviewAndClose()
    }

    // MARK: Helpers

    private let lab = "Contoso Lab (Demo)"

    private var mainWindow: XCUIElement { app.windows["main"].firstMatch }

    /// Selects a demo tenant and one of its sections. Its page's title is the
    /// tenant's name (" — Demo" follows).
    private func openDemoTenant(_ name: String, tab: String = "Overview", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20), "The main window did not open", file: file, line: line)
        openSidebar(name)
        XCTAssertTrue(waitTitle(name), "\(name) didn’t open", file: file, line: line)
        let segment = app.radioButtons[tab].firstMatch
        tap(segment, timeout: 10, file: file, line: line)
    }

    /// The demo preview: the fixed plan, Deploy dimmed; then Close.
    private func checkDemoPreviewAndClose(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(anyContaining("Deploying isn’t available in Demo Mode.").waitForExistence(timeout: 60),
                      "The preview didn't reach its review step", file: file, line: line)
        XCTAssertTrue(anyContaining("Reverts the change found in Jamf").exists, "The Teams update isn't in the plan", file: file, line: line)
        let deploy = app.sheets.buttons["Deploy"].firstMatch
        XCTAssertTrue(deploy.exists && !deploy.isEnabled, "Deploy must be dimmed in Demo Mode", file: file, line: line)
        tap(app.sheets.buttons["Close"].firstMatch, file: file, line: line)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "The preview did not close", file: file, line: line)
    }

    /// Waits until the main window's title starts with `title`.
    private func waitTitle(_ title: String, timeout: TimeInterval = 15) -> Bool {
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title BEGINSWITH %@", title), object: mainWindow)
        return XCTWaiter.wait(for: [opened], timeout: timeout) == .completed
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    /// Waits until a checkbox reads `value` (1 on, 0 off).
    private func waitValue(_ checkbox: XCUIElement, _ value: Int, timeout: TimeInterval = 10) -> Bool {
        let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %d", value), object: checkbox)
        return XCTWaiter.wait(for: [reads], timeout: timeout) == .completed
    }

    private func wait(forEither first: XCUIElement, _ second: XCUIElement, timeout: TimeInterval) -> Bool {
        wait(forAnyOf: [first, second], timeout: timeout)
    }

    private func wait(forAnyOf elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if elements.contains(where: \.exists) { return true }
            usleep(300_000)
        } while Date() < deadline
        return false
    }

    /// A date as the dashboard's token columns show it.
    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().year())
    }

    private func checkForChangesOnContoso(file: StaticString = #filePath, line: UInt = #line) {
        openSidebar(contoso)
        let check = app.toolbars.buttons["Check for Changes"]
        tap(check, timeout: 20, file: file, line: line)
        // The button is dimmed while the check runs.
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: check)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 60), .completed, "The check didn't finish", file: file, line: line)
        XCTAssertTrue(any("Changed in Jamf").waitForExistence(timeout: 20), "The Teams change wasn't found", file: file, line: line)
    }
}
