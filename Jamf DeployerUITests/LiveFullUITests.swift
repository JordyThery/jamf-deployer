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
/// Left out: blocks that need an Automated Device Enrollment instance,
/// Jamf Protect or Security Cloud, and blocks that make objects the cleanup
/// can't sweep (extension attributes, disk encryption configurations, App
/// Installers, mobile profiles, tenant-wide settings); Team Mode and moving
/// an export to a repository (nothing is pushed in a live run; Team Mode
/// stays covered by unit tests). The App Store test runs only on a test
/// tenant with an Apps and Books location that holds a license.
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

        try adopt(categoryName, resourceType: "categories", on: tenant)
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

    // MARK: A catalog release that renames a group

    /// A local Git catalog with two releases: v1.0.0 has a static group
    /// and a policy scoped to it; v1.0.1 renames the group (new address,
    /// new name, new key). On jamf-test-b: v1.0.0 deployed; the catalog
    /// source removed and added again (the tenant's blocks must follow its
    /// new identity); Baseline Updates… offers v1.0.1, whose deploy must
    /// finish without failures even though the engine deletes the old
    /// group before it updates the policy; read back: one group with the
    /// new name, the policy scoped to it. Then both blocks are removed.
    func testRenamingCatalogRelease() throws {
        let gateway = try liveGateway()
        let role = Self.testB
        let api = try LiveJamfPlatformAPI(gateway: gateway, role: role)
        let tenant = try tenantName(role)
        let catalogName = "\(runPrefix) Rename Catalog"
        let catalogURL = try makeRenameCatalog(in: testFolder.appending(path: "rename-catalog", directoryHint: .isDirectory))
        defer { finishLiveTest(step: step(role, "rename: nothing left")) {} }
        try launchDeployer(roles: [role])

        addGitCatalog(name: catalogName, url: catalogURL.absoluteString, tag: "v1.0.0")
        openTenant(tenant)
        tick("Rename Groups")
        tick("Rename Policy")
        record(step(role, "rename: deploy v1.0.0"), previewAndDeploy())

        removeCatalogSources(named: catalogName)
        addGitCatalog(name: catalogName, url: catalogURL.absoluteString, tag: "v1.0.0")
        recordLive(step: step(role, "rename: the catalog source removed and added again"), passed: true)

        openTenant(tenant)
        tap(app.buttons["Baseline Updates…"], timeout: 15)
        record(step(role, "rename: Baseline Updates… offers v1.0.1"), anyContaining("v1.0.1").waitForExistence(timeout: 60))
        tap(app.sheets.buttons["Stage Selected Updates"], timeout: 10)
        record(step(role, "rename: deploy v1.0.1 without failures"), previewAndDeploy())

        waitForNetwork()
        let renamed = "\(objectPrefix)Rename Pilot Renamed"
        let groups = try liveCall { try await api.object("proclassic/computergroups") }
        let names = ((groups["computer_groups"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            .filter { $0.hasPrefix(objectPrefix + "Rename Pilot") }
        record(step(role, "rename: read back, only the renamed group"), names == [renamed], note: names.joined(separator: ", "))
        let policies = try liveCall { try await api.object("proclassic/policies") }
        let policyID = ((policies["policies"] as? [[String: Any]]) ?? [])
            .first { ($0["name"] as? String) == "\(objectPrefix)Rename Check" }?["id"]
        var scoped: [String] = []
        if let policyID {
            let detail = try liveCall { try await api.object("proclassic/policies/id/\(policyID)") }
            let scope = (detail["policy"] as? [String: Any])?["scope"] as? [String: Any]
            scoped = ((scope?["computer_groups"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }
        record(step(role, "rename: read back, the policy scoped to the renamed group"), scoped == [renamed],
               note: scoped.joined(separator: ", "))

        openTenant(tenant)
        untick("Rename Policy")
        untick("Rename Groups")
        record(step(role, "rename: both blocks removed"), previewAndDeploy())
        removeCatalogSources(named: catalogName)
    }

    /// Writes the two-release catalog and returns a bare clone's file URL.
    /// Its objects are a static computer group and a disabled policy with
    /// no trigger devices reach, both named with the tenant's prefix.
    private func makeRenameCatalog(in folder: URL) throws -> URL {
        let work = folder.appending(path: "work", directoryHint: .isDirectory)
        let bare = folder.appending(path: "catalog.git", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        for block in ["rename-groups", "rename-policy"] {
            try FileManager.default.createDirectory(at: work.appending(path: "blocks/\(block)"), withIntermediateDirectories: true)
        }
        func write(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: work.appending(path: path))
        }
        try write(#"{ "id": "jtktest-rename", "name": "JTKTEST Rename Catalog", "schemaVersion": 1 }"#, "catalog.json")
        let versions = """
        terraform {
          required_providers {
            jamfplatform = {
              source = "jamf/jamfplatform"
            }
          }
        }

        """
        let variables = """
        variable "name_prefix" {
          type = string
        }

        variable "managed_by_tag" {
          type = string
        }

        """
        let dependencies = ["ids", "names", "jamf_pro_ids"].map {
            "variable \"dep_device_group_\($0)\" {\n  type    = map(string)\n  default = {}\n}\n"
        }.joined(separator: "\n")
        for block in ["rename-groups", "rename-policy"] {
            try write(versions, "blocks/\(block)/versions.tf")
        }
        try write(variables, "blocks/rename-groups/variables.tf")
        try write(variables + dependencies, "blocks/rename-policy/variables.tf")

        func manifest(_ id: String, _ name: String, _ version: String, _ wiring: String) -> String {
            """
            {
              "acceptsCategory": false, "alwaysOn": false, "category": "Core", "conflicts": [],
              "id": "\(id)", "name": "\(name)", "summary": "Rename test block.", "version": "\(version)",
              "minJamfProVersion": "11.31.0", "objectsCreated": ["1 object"],
              "permissions": [], "products": ["jamf-pro", "jamf-platform"], "requires": [],
              "risk": "low", "scope": { "kind": "none" }, "settings": [], \(wiring)
            }

            """
        }
        func release(_ version: String, resource: String, group: String) throws {
            try write(manifest("rename-groups", "Rename Groups", version, #""provides": { "device_group": ["\#(group)"] }"#),
                      "blocks/rename-groups/block.json")
            try write(manifest("rename-policy", "Rename Policy", version, #""needs": { "device_group": ["\#(group)"] }"#),
                      "blocks/rename-policy/block.json")
            try write("""
            resource "jamfplatform_device_group" "\(resource)" {
              name        = "${var.name_prefix}\(group)"
              description = var.managed_by_tag
              device_type = "computer"
              group_type  = "static"
            }

            output "device_group_ids" {
              value = { "\(group)" = jamfplatform_device_group.\(resource).id }
            }

            output "device_group_names" {
              value = { "\(group)" = jamfplatform_device_group.\(resource).name }
            }

            output "device_group_jamf_pro_ids" {
              value = { "\(group)" = jamfplatform_device_group.\(resource).jamf_pro_id }
            }

            """, "blocks/rename-groups/main.tf")
            try write("""
            resource "jamfplatform_pro_policy" "check" {
              general = {
                name          = "${var.name_prefix}Rename Check"
                enabled       = false
                frequency     = "Ongoing"
                trigger_other = "jtktest-rename-check"
              }
              scope = {
                targets = {
                  computer_group_ids = [var.dep_device_group_jamf_pro_ids["\(group)"]]
                }
              }
            }

            """, "blocks/rename-policy/main.tf")
            try git(["add", "-A"], in: work)
            try git(["commit", "-qm", "v\(version)"], in: work)
            try git(["tag", "v\(version)"], in: work)
        }
        try git(["init", "-q", "-b", "main"], in: work)
        try release("1.0.0", resource: "pilot", group: "Rename Pilot")
        try release("1.0.1", resource: "pilot_renamed", group: "Rename Pilot Renamed")
        try git(["clone", "-q", "--bare", work.path, bare.path], in: folder)
        return bare
    }

    /// Runs git in the test runner (the catalog is the test's own, local).
    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=JTKTEST", "-c", "user.email=jtktest@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + arguments
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": testFolder.path, "GIT_CONFIG_NOSYSTEM": "1"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
    }

    /// Building Blocks › Add Git Catalog…, pinned to `tag`.
    private func addGitCatalog(name: String, url: String, tag: String, file: StaticString = #filePath, line: UInt = #line) {
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Add Git Catalog…"], timeout: 15, file: file, line: line)
        type(name, into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Shared Blocks'")).firstMatch)
        type(url, into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'https://github.com/org/blocks.git'")).firstMatch)
        tap(app.sheets.buttons["Fetch Release Tags"], file: file, line: line)
        let tags = app.sheets.popUpButtons.firstMatch
        XCTAssertTrue(tags.waitForExistence(timeout: 60), "No release tags fetched", file: file, line: line)
        if (tags.value as? String) != tag {
            tags.click()
            tap(app.menuItems[tag], timeout: 5, file: file, line: line)
        }
        tap(app.sheets.buttons["Add Catalog"], file: file, line: line)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 120), "The catalog wasn't added", file: file, line: line)
    }

    /// Building Blocks › Manage Sources…: removes every source with this name.
    private func removeCatalogSources(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        openSidebar("Building Blocks")
        tap(app.toolbars.buttons["Manage Sources…"], timeout: 15, file: file, line: line)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<5 {
            let label = app.sheets.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch
            guard label.waitForExistence(timeout: 2) else { break }
            let row = app.sheets.buttons.matching(NSPredicate(format: "label == 'Remove…'")).allElementsBoundByIndex
                .min { abs($0.frame.midY - label.frame.midY) < abs($1.frame.midY - label.frame.midY) }
            guard let remove = row, abs(remove.frame.midY - label.frame.midY) < 30 else { break }
            remove.click()
            tap(dialogButton("Remove Source"), timeout: 10, file: file, line: line)
            sleep(1)
        }
        tap(app.sheets.buttons["Close"], timeout: 5, file: file, line: line)
    }

    // MARK: Mac App Store Apps

    /// The built-in Mac App Store Apps block on jamf-test-b (Platform API):
    /// the first licensed app from the picker, scoped to the demo catalog's
    /// empty static Pilot group (so no device gets it), deployed, checked
    /// clean, and removed with the Pilot group. Skipped on a tenant without
    /// an Apps and Books location.
    func testMacAppStoreApps() throws {
        let gateway = try liveGateway()
        let role = Self.testB
        let api = try LiveJamfPlatformAPI(gateway: gateway, role: role)
        let locations = try liveCall { try await api.object("pro/v1/volume-purchasing-locations") }
        guard ((locations["totalCount"] as? NSNumber)?.intValue ?? 0) > 0 else {
            recordLive(step: step(role, "Mac App Store Apps: skipped, no Apps and Books location"), passed: true)
            throw XCTSkip("\(role) has no Apps and Books location")
        }
        let tenant = try tenantName(role)
        defer { finishLiveTest(step: step(role, "Mac App Store Apps: nothing left")) {} }
        try launchDeployer(roles: [role])
        ensureDemoCatalog()

        openTenant(tenant)
        tick("Device Groups")
        tick("Mac App Store Apps")
        openSettings(of: "Mac App Store Apps")
        chooseScope("Pilot", current: [])
        tap(app.buttons["Choose Apps…"].firstMatch, timeout: 15)
        let add = app.sheets.buttons["Add"].firstMatch
        record(step(role, "Mac App Store Apps: the picker lists a licensed app"), add.waitForExistence(timeout: 120))
        add.click()
        tap(app.sheets.buttons["Done"], timeout: 10)
        record(step(role, "Mac App Store Apps: 1 app selected"), anyContaining("1 app selected").waitForExistence(timeout: 10))
        XCTAssertFalse(anyContaining("needs a value before this block can deploy").waitForExistence(timeout: 3), "A required setting is empty")

        openPreview()
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        let creates = plannedCount("create")
        // the Pilot group and four smart groups, and the app
        record(step(role, "Mac App Store Apps: preview"), creates == 6, note: "\(creates) create")
        deployCurrentPreview()
        record(step(role, "Mac App Store Apps: deploy"), finishDeploy())
        try checkForChanges(on: tenant, expectingChanges: false)
        recordLive(step: step(role, "Mac App Store Apps: Check for Changes clean"), passed: true)

        openTenant(tenant)
        untick("Mac App Store Apps")
        untick("Device Groups")
        openPreview()
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        let removes = plannedCount("remove")
        record(step(role, "Mac App Store Apps: removal planned"), removes == creates, note: "\(removes) remove")
        deployCurrentPreview()
        record(step(role, "Mac App Store Apps: removed"), finishDeploy())
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
