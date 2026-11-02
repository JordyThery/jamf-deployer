import XCTest
import JTKitLiveCheck
import JTKitUITestSupport

/// The full live UI suite: the app's functions end to end against the
/// release check's two disposable tenants (jamf-test-a, jamf-test-b), under
/// JTKit's live-check switch. Long (an hour or more): run only when Jordy
/// asks for it, through the release check (see Scripts/release-check.sh,
/// `JD_LIVE_FULL=1`), one test at a time with `--only`.
///
/// Every object is named with the run's prefix and is one the release
/// check's cleanup can sweep (categories, scripts, policies, macOS
/// configuration profiles, computer groups). Each test removes what it
/// deployed through the app; a change "made in Jamf" is only ever made on
/// an object the test created itself, through the gateway.
///
/// Left out: blocks that need an Automated Device Enrollment instance, an
/// Apps and Books location, Jamf Protect or Security Cloud, and blocks that
/// make objects the cleanup can't sweep (extension attributes, disk
/// encryption configurations, App Installers, mobile profiles, tenant-wide
/// settings); the Rename suite (it needs a catalog with two locally built
/// releases); the App Store suite (it needs an Apps and Books location);
/// Team Mode (no private test repository; it stays covered by unit tests);
/// moving an export to a repository (exports for review only).
final class LiveFullUITests: LiveDeployerUITestCase {

    // MARK: Custom objects on both connections

    /// Add a Custom Object… on both connections: a category and a script
    /// through the Jamf Platform API (jamf-test-b) and the Jamf Pro API
    /// (jamf-test-a), deployed, checked clean, and removed again.
    func testCustomObjectsOnBothConnections() throws {
        let platform = try connection(Self.testB, "jamfPlatform")
        let jamfPro = try connection(Self.testA, "jamfPro")
        defer { finishLiveTest(step: "custom objects: live UI: nothing left") {} }
        try launchDeployer(roles: [Self.testA, Self.testB])

        let cases: [(role: String, tenant: LiveConnectionDescription, category: String, script: String)] = [
            (Self.testB, platform, "jamfplatform_pro_category", "jamfplatform_pro_script"),
            (Self.testA, jamfPro, "jamfpro_category", "jamfpro_script"),
        ]
        for item in cases {
            stageCustomObject(on: item.tenant.name, type: item.category, objectName: "jtk_custom_category",
                              values: ["name": "\(objectPrefix)Custom Category"], numbers: ["priority": "9"])
            stageCustomObject(on: item.tenant.name, type: item.script, objectName: "jtk_custom_script", values: [
                "name": "\(objectPrefix)Custom Script",
                "priority": "AFTER",
                // one line: a typed Return would submit the form
                "script_contents": "echo JTKTEST",
            ])
            openTenant(item.tenant.name)
            openPreview()
            XCTAssertTrue(reachReview(), "The preview didn't finish")
            let creates = plannedCount("create")
            record(step(item.role, "custom objects: preview creates the category and the script"), creates == 2, note: "\(creates) create")
            deployCurrentPreview()
            record(step(item.role, "custom objects: deploy"), finishDeploy())
            try checkForChanges(on: item.tenant.name, expectingChanges: false)
            recordLive(step: step(item.role, "custom objects: Check for Changes clean"), passed: true)

            // The app has no screen to drop a custom object: the test
            // removes its staged files, and the next deploy deletes both.
            for object in ["jtk_custom_category", "jtk_custom_script"] {
                try FileManager.default.removeItem(at: try customObjectFile(tenantID: item.tenant.id, objectName: object))
            }
            openTenant(item.tenant.name)
            openPreview()
            XCTAssertTrue(reachReview(), "The preview didn't finish")
            let removes = plannedCount("remove")
            record(step(item.role, "custom objects: removal planned"), removes == 2, note: "\(removes) remove")
            deployCurrentPreview()
            record(step(item.role, "custom objects: removed"), finishDeploy())
        }
    }

    /// A staged custom object's file in the run's store.
    private func customObjectFile(tenantID: UUID, objectName: String) throws -> URL {
        try runStoreURL().appending(path: "tenants/\(tenantID.uuidString)/adopted/override-\(objectName).tf")
    }

    // MARK: Demo catalog blocks on both connections

    /// The demo catalog's blocks that make only sweepable objects, on both
    /// connections: deployed together, checked clean, then all removed.
    /// Rosetta 2 and Self Service Maintenance are scoped to the empty static
    /// Pilot group, so their policies reach no device.
    func testCatalogBlocksOnBothConnections() throws {
        let tenants = [(Self.testB, try tenantName(Self.testB)), (Self.testA, try tenantName(Self.testA, "jamfPro"))]
        defer { finishLiveTest(step: "catalog blocks: live UI: nothing left") {} }
        try launchDeployer(roles: [Self.testA, Self.testB])
        ensureDemoCatalog()

        // in this order: the blocks that provide groups and categories first
        let blocks = ["Categories", "Device Groups", "macOS Version Groups", "Rosetta 2", "Self Service Maintenance"]
        let scoped = ["Rosetta 2": ["Apple Silicon Macs"], "Self Service Maintenance": ["All Managed Macs"]]
        for (role, tenant) in tenants {
            openTenant(tenant)
            for block in blocks { tick(block) }
            for (block, current) in scoped {
                openSettings(of: block)
                chooseScope("Pilot", current: current)
            }
            XCTAssertFalse(anyContaining("needs a value before this block can deploy").waitForExistence(timeout: 3), "A required setting is empty")
            XCTAssertFalse(anyContaining("Choose which group this block applies to").exists, "A block has no scope")
            openPreview()
            XCTAssertTrue(reachReview(), "The preview didn't finish")
            let creates = plannedCount("create")
            // 4 categories, 5 groups, 2 version groups, Rosetta's script and
            // policy, Self Service Maintenance's script and two policies
            record(step(role, "catalog blocks: preview"), creates >= 16, note: "\(creates) create")
            deployCurrentPreview()
            record(step(role, "catalog blocks: deploy"), finishDeploy(timeout: 1800))
            try checkForChanges(on: tenant, expectingChanges: false)
            recordLive(step: step(role, "catalog blocks: Check for Changes clean"), passed: true)

            openTenant(tenant)
            for block in blocks.reversed() { untick(block) }
            openPreview()
            XCTAssertTrue(reachReview(), "The preview didn't finish")
            let removes = plannedCount("remove")
            record(step(role, "catalog blocks: Remove from Tenant planned"), removes == creates, note: "\(removes) remove")
            deployCurrentPreview()
            record(step(role, "catalog blocks: removed"), finishDeploy(timeout: 1800))
        }
    }

    // MARK: Jamf Pro API flows

    /// jamf-test-a over the Jamf Pro API: preflight, adopt the test's own
    /// category, keep a change made in Jamf, save a snapshot (building
    /// blocks and clones aren't offered), the Day 0 tab, and Hand Over.
    func testJamfProAPIFlows() throws {
        let gateway = try liveGateway()
        let role = Self.testA
        let api = try LiveJamfProAPI(gateway: gateway, role: role)
        let tenant = try tenantName(role, "jamfPro")
        let categoryName = "\(objectPrefix)Live Jamf Pro Adopt"
        let path = "api/v1/categories"
        let categoryID = try liveCall { try await api.create(path, json: ["name": categoryName, "priority": 9]) }
        defer {
            finishLiveTest(step: step(role, "Jamf Pro API flows: delete the test's category; nothing left")) {
                _ = try liveCall { try await api.send("DELETE", "\(path)/\(categoryID)", accepting: [404]) }
            }
        }
        recordLive(step: step(role, "Jamf Pro API flows: create a category to adopt"), passed: true)

        try launchDeployer(roles: [role])
        openTenant(tenant)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Run Preflight'")).firstMatch, timeout: 30)
        record(step(role, "preflight signs in to the Jamf Pro API"),
               anyContaining("Signed in to the Jamf Pro API").waitForExistence(timeout: 120))
        ensureTerraform(on: tenant)

        adopt(categoryName, resourceType: "categories", on: tenant)
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        record(step(role, "adopt: preview"), plannedCount("adopt") == 1)
        deployCurrentPreview()
        record(step(role, "adopt: deploy"), finishDeploy())
        record(step(role, "adopt: 1 adopted object"), anyContaining("1 adopted object").waitForExistence(timeout: 30))

        _ = try liveCall { try await api.send("PUT", "\(path)/\(categoryID)", json: ["name": categoryName, "priority": 15]) }
        try checkForChanges(on: tenant, expectingChanges: true)
        record(step(role, "Keep This Change"), keepFirstChange())

        // Exports: a snapshot only (capture and clone need the Platform API).
        openTenant(tenant, tab: "Export")
        XCTAssertTrue(app.radioButtons["Full snapshot"].waitForExistence(timeout: 30))
        record(step(role, "Export tab offers no building block or clone"),
               !app.radioButtons["Building block"].exists && !app.radioButtons["Clone to tenant"].exists)
        export(kind: "Full snapshot", resourceType: "categories", from: tenant)
        tap(app.buttons["Save Snapshot…"], timeout: 900)
        saveInTestFolder()
        record(step(role, "Save Snapshot…"), waitForFile(in: testFolder) { $0.hasPrefix("Snapshot-") && $0.hasSuffix(".zip") })

        openTenant(tenant, tab: "Day 0 Setup")
        tap(app.buttons["Check Again"], timeout: 30)
        let day0 = app.buttons["Mark as Done"].waitForExistence(timeout: 120) || anyContaining("Organization name").exists
            || app.buttons["Create Branding"].exists
        record(step(role, "Day 0 Setup checks the tenant"), day0)

        // Hand Over: stops managing everything; the objects stay in Jamf.
        openTenant(tenant)
        scrollIntoView(app.buttons["Hand Over Tenant…"])
        tap(app.buttons["Hand Over Tenant…"], timeout: 15)
        let nameField = app.dialogs.textFields.firstMatch.exists ? app.dialogs.textFields.firstMatch : app.sheets.textFields.firstMatch
        type(tenant, into: nameField)
        tap(dialogButton("Prepare Hand-Over"))
        XCTAssertTrue(reachReview(), "The hand-over preview didn't finish")
        record(step(role, "Hand Over: preview stops managing"), plannedCount("stop managing") >= 1)
        deployCurrentPreview()
        record(step(role, "Hand Over: deploy"), finishDeploy())
        record(step(role, "Hand Over: the tenant is handed over"), anyContaining("was handed over").waitForExistence(timeout: 30))
        removeTenant(tenant)
    }

    // MARK: Functions across two Platform tenants

    /// jamf-test-b to jamf-test-a, both over the Jamf Platform API: History
    /// Roll Back, as-built documentation, a full snapshot, Clone to tenant
    /// (staged and previewed), and a captured block deployed on the other
    /// tenant and removed again.
    func testFunctionsAcrossTwoPlatformTenants() throws {
        let gateway = try liveGateway()
        guard let secret = try gateway.secretNow(role: Self.testA, item: "client-secret"), !secret.isEmpty else {
            throw XCTSkip("\(Self.testA) has no Jamf Platform API credentials in this run")
        }
        let source = try tenantName(Self.testB)
        let destination = try tenantName(Self.testA)
        let name = { (step: String) in "\(Self.testB) → \(Self.testA): live UI: \(step)" }
        defer { finishLiveTest(step: name("nothing left")) {} }
        try launchDeployer(roles: [Self.testA, Self.testB])
        ensureDemoCatalog()
        ensureTerraform(on: source)

        openTenant(source)
        tick("Categories")
        record(name("deploy the Categories block on the source"), previewAndDeploy())

        // History: roll back to that deploy (the same baseline: harmless).
        openSidebar("History")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Roll back \(source) to")).firstMatch, timeout: 30)
        tap(dialogButton("Roll Back"), timeout: 10)
        record(name("History: Roll Back"), anyContaining("Baseline Restored").waitForExistence(timeout: 15) || any("Baseline Restored").exists)
        tap(dialogButton("OK"), timeout: 10)

        export(kind: "As-built documentation", resourceType: "category", from: source)
        tap(app.buttons["Save As-Built Documentation…"], timeout: 900)
        saveInTestFolder()
        record(name("Save As-Built Documentation…"), waitForFile(in: testFolder) { $0.hasPrefix("AsBuilt-") && $0.hasSuffix(".md") })

        export(kind: "Full snapshot", resourceType: "category", from: source)
        tap(app.buttons["Save Snapshot…"], timeout: 900)
        saveInTestFolder()
        record(name("Save Snapshot…"), waitForFile(in: testFolder) { $0.hasPrefix("Snapshot-") && $0.hasSuffix(".zip") })

        // Clone to tenant: the block's four categories, staged and previewed.
        export(kind: "Clone to tenant", resourceType: "category", from: source)
        XCTAssertTrue(anyContaining("selected)").waitForExistence(timeout: 900), "The export did not finish")
        tap(app.buttons.matching(NSPredicate(format: "identifier == 'None'")).element(boundBy: 1), timeout: 10)
        for object in exportedObjects(beginningWith: objectPrefix) { object.click() }
        tap(app.popUpButtons.matching(NSPredicate(format: "value == 'Choose a tenant…'")).firstMatch, timeout: 10)
        tap(app.menuItems[destination], timeout: 5)
        tap(app.buttons["Stage Clone"])
        record(name("Clone to tenant: staged"), anyContaining("Staged 4 objects").waitForExistence(timeout: 60))
        openTenant(destination)
        openPreview()
        XCTAssertTrue(reachReview(), "The clone's preview didn't finish")
        let cloneCreates = plannedCount("create")
        record(name("Clone to tenant: preview, no deploy"), cloneCreates == 4, note: "\(cloneCreates) create")
        closePreview()
        let clone = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", "Clone of \(source)")).firstMatch
        if clone.waitForExistence(timeout: 10), (clone.value as? Int) == 1 { clone.click() }

        // A captured block deployed on the other tenant, then removed.
        export(kind: "Building block", resourceType: "category", from: source)
        XCTAssertTrue(anyContaining("selected)").waitForExistence(timeout: 900), "The export did not finish")
        tap(app.buttons.matching(NSPredicate(format: "identifier == 'None'")).element(boundBy: 1), timeout: 10)
        for object in exportedObjects(beginningWith: objectPrefix) { object.click() }
        captureBlock(id: "jtktest-captured-categories", name: "JTKTEST Captured Categories",
                     folder: testFolder.appending(path: "JTKTEST Captured", directoryHint: .isDirectory))
        openTenant(destination)
        tick("JTKTEST Captured Categories")
        openPreview()
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        record(name("captured block: preview on the other tenant"), plannedCount("create") == 4)
        deployCurrentPreview()
        record(name("captured block: deploy"), finishDeploy())
        untick("JTKTEST Captured Categories")
        record(name("captured block: removed"), previewAndDeploy())

        openTenant(source)
        untick("Categories")
        record(name("Categories block removed from the source"), previewAndDeploy())
    }

    // MARK: Rollout in two rings

    /// Roll Out… across both test tenants (jamf-test-b over the Platform
    /// API in ring 1, jamf-test-a over the Jamf Pro API in ring 2), each
    /// deploying the Categories block; then both remove it again.
    func testRolloutInTwoRings() throws {
        let ring1 = try tenantName(Self.testB)
        let ring2 = try tenantName(Self.testA, "jamfPro")
        defer { finishLiveTest(step: "rollout: live UI: nothing left") {} }
        try launchDeployer(roles: [Self.testA, Self.testB])
        ensureDemoCatalog()
        for tenant in [ring1, ring2] {
            openTenant(tenant)
            tick("Categories")
        }

        startRollout(rings: [ring1: 1, ring2: 2])
        deployCurrentPreview()
        record("rollout: live UI: ring 1 deploys", finishDeploy())
        tap(app.sheets.buttons["Continue"], timeout: 30)
        tap(app.buttons["Continue with Ring 2"], timeout: 60)
        deployCurrentPreview()
        record("rollout: live UI: ring 2 deploys", finishDeploy())
        tap(app.sheets.buttons["Continue"], timeout: 30)
        let finished = app.staticTexts["Rollout finished"].waitForExistence(timeout: 60)
        let deployed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Deployed ('")).count
        record("rollout: live UI: finished, both deployed", finished && deployed >= 2, note: "\(deployed) deployed")
        tap(app.buttons["Done"])

        for tenant in [ring1, ring2] {
            openTenant(tenant)
            untick("Categories")
            record("rollout: live UI: \(tenant == ring1 ? Self.testB : Self.testA) removes the block", previewAndDeploy())
        }
    }

    // MARK: Presets and conflicts

    /// The Fleet preset applied without deploying, and FileVault next to
    /// Mac Security flagged as a conflict. Nothing is deployed.
    func testFleetPresetConflictIsFlagged() throws {
        let tenant = try tenantName(Self.testB)
        defer { finishLiveTest(step: step(Self.testB, "Fleet preset: nothing deployed")) {} }
        try launchDeployer(roles: [Self.testB])
        ensureDemoCatalog()
        openTenant(tenant)
        tap(app.menuButtons["Apply a Preset"].firstMatch, timeout: 30)
        tap(app.menuItems["Fleet"], timeout: 5)
        if dialogButton("Apply Preset").waitForExistence(timeout: 3) { dialogButton("Apply Preset").click() }
        let selected = ["Fleet Foundation", "Mac Security", "Saved Searches"].allSatisfy { blockCheckbox($0).value as? Int == 1 }
        record(step(Self.testB, "the Fleet preset selects its blocks"), selected)
        tick("FileVault")
        record(step(Self.testB, "FileVault next to Mac Security is flagged"),
               anyContaining("Can’t be used together with").waitForExistence(timeout: 10))
        untick("FileVault")
    }

    // MARK: Export as Terraform

    /// Export as Terraform for review into the test's own folder; the
    /// tenant stays managed here (never moved to a repository).
    func testExportAsTerraformForReview() throws {
        let tenant = try tenantName(Self.testB)
        defer { finishLiveTest(step: step(Self.testB, "Export as Terraform: nothing left")) {} }
        try launchDeployer(roles: [Self.testB])
        ensureDemoCatalog()
        openTenant(tenant)
        tick("Categories")
        record(step(Self.testB, "Export as Terraform: deploy the Categories block"), previewAndDeploy())

        let folder = testFolder.appending(path: "review", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        openExportSheet()
        chooseTenantAndFolder(tenant, folder.path)
        tap(app.sheets.buttons["Export"])
        let exported = anyContaining("Exported 1 tenant").waitForExistence(timeout: 600)
        tap(app.sheets.buttons["Done"], timeout: 10)
        let readme = FileManager.default.fileExists(atPath: folder.appending(path: "README.md").path)
        record(step(Self.testB, "Export as Terraform for review"), exported && readme)

        openTenant(tenant)
        untick("Categories")
        record(step(Self.testB, "Export as Terraform: the block removed"), previewAndDeploy())
    }

    // MARK: Helpers

    /// Waits until the folder holds a file whose name passes `matches`.
    private func waitForFile(in folder: URL, timeout: TimeInterval = 30, _ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if names.contains(where: matches) { return true }
            sleep(1)
        }
        return false
    }
}
