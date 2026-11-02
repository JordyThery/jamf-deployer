import XCTest
import JTKitLiveCheck
import JTKitUITestSupport

/// The release check's live UI tests (`Scripts/release-check.sh`, stage 4):
/// the real app under JTKit's live-check switch, with the run's connections
/// only. About 15 minutes together.
///
/// 1. Connect a Tenant over the Jamf Platform API (jamf-test-b): wizard,
///    preflight, add, then Remove Tenant….
/// 2. jamf-test-b: the demo catalog's Categories block deployed together
///    with a category the test made and the app adopts; Check for Changes
///    clean; the test changes the adopted category in Jamf, the app finds
///    it, Restore Baseline puts it back (read back by the test); a second
///    change is kept with Keep This Change; then Remove from Tenant deletes
///    the block's categories and the test deletes its own.
/// 3. Capture from the production read role, preview on jamf-test-b: a
///    building block captured from a few production categories, previewed
///    on jamf-test-b and closed. Nothing is deployed; production is only read.
final class LiveUITests: LiveDeployerUITestCase {

    // MARK: 1. Connect and remove

    func testConnect() throws {
        let gateway = try liveGateway()
        let role = Self.testB
        let platform = try connection(role, "jamfPlatform")
        guard let secret = try gateway.secretNow(role: role, item: "client-secret"), !secret.isEmpty else {
            return XCTFail("\(role) has no client secret in this run")
        }
        try launchDeployer(roles: [role], seed: false)
        // the name is only used inside the app
        let name = "\(runPrefix) Connect Test"
        connectPlatform(name: name, region: platform.region, clientID: platform.clientID, secret: secret,
                        environmentID: platform.environmentID)
        waitForNetwork()
        record(step(role, "Connect a Tenant over the Jamf Platform API: preflight, Add Tenant"),
               app.outlines.staticTexts[name].exists)

        openTenant(name)
        let preflight = anyContaining("Last preflight").waitForExistence(timeout: 30)
        record(step(role, "the preflight is saved with the tenant"), preflight)

        removeTenant(name)
        record(step(role, "Remove Tenant… takes it out of the sidebar"), !app.outlines.staticTexts[name].exists)
        finishLiveTest(step: step(role, "connect and remove: nothing made")) {}
    }

    // MARK: 2. Deploy, drift, restore, keep, remove

    func testDeployDriftKeepRestore() throws {
        let gateway = try liveGateway()
        let role = Self.testB
        let api = try LiveJamfPlatformAPI(gateway: gateway, role: role)
        let tenant = try tenantName(role)
        let categoryName = "\(objectPrefix)Live Adopt Category"
        let path = "pro/v1/categories"

        // 1. The test's own category, which the app adopts.
        let categoryID = try liveCall { try await api.create(path, json: ["name": categoryName, "priority": 9]) }
        defer {
            finishLiveTest(step: step(role, "delete the test's category; nothing left")) {
                _ = try liveCall { try await api.send("DELETE", "\(path)/\(categoryID)", accepting: [404]) }
            }
        }
        recordLive(step: step(role, "create a category to adopt"), passed: true)

        try launchDeployer(roles: [role])
        ensureDemoCatalog()
        ensureTerraform(on: tenant)

        // 2. The Categories block and the adopted category in one deploy.
        openTenant(tenant)
        tick("Categories")
        adopt(categoryName, resourceType: "category", on: tenant)
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        let creates = plannedCount("create"), adopts = plannedCount("adopt")
        record(step(role, "Preview Changes: the block's categories created, the test's category adopted"),
               creates >= 4 && adopts == 1, note: "\(creates) create, \(adopts) adopt")
        deployCurrentPreview()
        record(step(role, "Deploy"), finishDeploy())
        record(step(role, "the tenant lists 1 adopted object"), anyContaining("1 adopted object").waitForExistence(timeout: 30))

        try checkForChanges(on: tenant, expectingChanges: false)
        recordLive(step: step(role, "Check for Changes after the deploy: in sync"), passed: true)

        // 3. A change made in Jamf, found and restored.
        _ = try liveCall { try await api.send("PUT", "\(path)/\(categoryID)", json: ["name": categoryName, "priority": 15]) }
        try checkForChanges(on: tenant, expectingChanges: true)
        record(step(role, "Check for Changes finds the change made in Jamf"), anyContaining(categoryName).exists)
        tap(app.buttons["Restore Baseline…"], timeout: 30)
        deployCurrentPreview()
        record(step(role, "Restore Baseline: deploy"), finishDeploy())
        waitForNetwork()
        let restored = try liveCall { try await api.object("\(path)/\(categoryID)") }
        record(step(role, "read back: the category's priority is the baseline's again"), categoryPriority(restored) == 9,
               note: "priority \(categoryPriority(restored).map(String.init) ?? "?")")

        // 4. Another change, kept.
        _ = try liveCall { try await api.send("PUT", "\(path)/\(categoryID)", json: ["name": categoryName, "priority": 16]) }
        try checkForChanges(on: tenant, expectingChanges: true)
        record(step(role, "Keep This Change"), keepFirstChange())

        // 5. Remove from Tenant deletes the block's categories.
        openTenant(tenant)
        untick("Categories")
        openPreview()
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        let removes = plannedCount("remove")
        record(step(role, "Remove from Tenant: the block's categories planned as removals"), removes >= 4, note: "\(removes) remove")
        deployCurrentPreview()
        record(step(role, "Remove from Tenant: deploy"), finishDeploy())
    }

    // MARK: 3. Capture from production, preview on jamf-test-b

    func testCaptureFromProductionPreviewOnTestB() throws {
        let gateway = try liveGateway()
        guard gateway.launch.connections.contains(where: { $0.role == Self.production && $0.connection.service == "jamfPlatform" }) else {
            throw XCTSkip("\(Self.production) isn't part of this run")
        }
        let source = try tenantName(Self.production)
        let destination = try tenantName(Self.testB)
        let name = { (step: String) in "\(Self.production) → \(Self.testB): live UI: \(step)" }
        defer { finishLiveTest(step: name("nothing made, nothing deployed")) {} }

        try launchDeployer(roles: [Self.production, Self.testB])
        ensureTerraform(on: source)

        // A building block from a few of production's categories (read only).
        export(kind: "Building block", resourceType: "category", from: source)
        XCTAssertTrue(anyContaining("selected)").waitForExistence(timeout: 900), "The export did not finish")
        // the object list's None (the first belongs to the type list)
        tap(app.buttons.matching(NSPredicate(format: "identifier == 'None'")).element(boundBy: 1), timeout: 10)
        let objects = exportedObjectCheckboxes(limit: 3)
        for object in objects { object.click() }
        record(name("export categories from production"), !objects.isEmpty, note: "\(objects.count) selected")
        captureBlock(id: "jtktest-captured-categories", name: "JTKTEST Captured Categories",
                     folder: testFolder.appending(path: "JTKTEST Captured", directoryHint: .isDirectory))
        recordLive(step: name("capture as a building block"), passed: true)

        // Previewed on jamf-test-b, then closed: no deploy.
        openTenant(destination)
        tick("JTKTEST Captured Categories")
        openPreview()
        XCTAssertTrue(reachReview(), "The preview didn't finish")
        let creates = plannedCount("create")
        record(name("capture from production, preview on jamf-test-b, no apply"), creates == objects.count,
               note: "\(creates) create for \(objects.count) captured")
        closePreview()
        untick("JTKTEST Captured Categories")
    }
}
