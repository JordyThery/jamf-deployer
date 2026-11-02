import XCTest
import AppKit
import JTKitLiveCheck
import JTKitUITestSupport

/// The base of Jamf Deployer's live UI tests (JTKit's live-check switch):
/// the real app with the release check's connections only, every request
/// through its gateway. Run only by `Scripts/release-check.sh` in its live
/// stage; skipped anywhere else.
///
/// Rules the app keeps under the switch (`LiveRun`): OpenTofu and jamformer
/// reach only the run's tenants, apply only to jamf-test-a and jamf-test-b,
/// and a deploy touching an object not named with the run's prefix is
/// refused. The gateway sees only JTKit's requests (the app's and the
/// test's): objects OpenTofu creates aren't in the run's ledger, so the test
/// removes them through the app (and the release check's cleanup sweeps
/// what a failed test left). A change "made in Jamf" is always made by the
/// test, through the gateway, on an object the test created itself.
class LiveDeployerUITestCase: DeployerUITestCase {
    override var launchesLive: Bool { true }

    override func didLaunch() {
        let main = app.windows["main"].firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 30), "The main window did not open")
        let skip = app.buttons["Skip Tour"].firstMatch
        if skip.waitForExistence(timeout: 2) { skip.click() }
        super.didLaunch()
    }

    // MARK: Roles and tenants

    static let testA = "jamf-test-a"
    static let testB = "jamf-test-b"
    static let production = "jamfpro-production"

    /// The run's connection for a role and service ("jamfPlatform" or "jamfPro").
    func connection(_ role: String, _ service: String) throws -> LiveConnectionDescription {
        let gateway = try liveGateway()
        guard let entry = gateway.launch.connections.first(where: { $0.role == role && $0.connection.service == service }) else {
            throw XCTSkip("\(role) has no \(service) connection in this run")
        }
        return entry.connection
    }

    /// The seeded tenant's name in the sidebar: the gateway's connection
    /// name, e.g. "jamf-test-b (Jamf Platform API)".
    func tenantName(_ role: String, _ service: String = "jamfPlatform") throws -> String {
        try connection(role, service).name
    }

    /// Every object a live test makes starts with this.
    var runPrefix: String {
        let prefix = livePrefix
        return prefix.hasPrefix("JTKTEST") ? prefix : "JTKTEST"
    }

    /// The seeded tenants' name prefix ("<prefix> – "), which blocks put
    /// in front of every object name.
    var objectPrefix: String { runPrefix + " – " }

    // MARK: Launch

    /// The app's run store (throwaway, in the release check's live folder).
    func runStoreURL() throws -> URL {
        try liveGateway().appRunFolder.appending(path: "app-files/Jamf Deployer/store", directoryHint: .isDirectory)
    }

    /// Launches the app under the switch with these roles' connections.
    /// `seed` starts it with them as tenants. Each launch starts from an
    /// empty store: tenant secrets and state passphrases live in memory for
    /// one launch only, so a tenant record left by an earlier test of the
    /// run couldn't sign in or read its state.
    func launchDeployer(roles: [String], seed: Bool = true, freshStore: Bool = true) throws {
        if freshStore {
            let store = try runStoreURL()
            if FileManager.default.fileExists(atPath: store.path) {
                try FileManager.default.removeItem(at: store)
            }
        }
        var arguments = ["-hasSeenGuidedTour", "YES", "-JDLivePrefix", runPrefix, "-NSNavLastRootDirectory", testFolder.path]
        if seed { arguments += ["-JDLiveSeedTenants", "YES"] }
        try launchLive(roles: roles, arguments: arguments)
    }

    /// The step's name in the run's report.
    func step(_ role: String, _ name: String) -> String { "\(role): live UI: \(name)" }

    /// Records a step and fails the test when it didn't pass.
    func record(_ name: String, _ passed: Bool, note: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        recordLive(step: name, passed: passed, note: note)
        XCTAssertTrue(passed, "\(name)\(note.map { ": \($0)" } ?? "")", file: file, line: line)
    }

    // MARK: Catalog and Terraform

    /// Adds the public demo catalog (Building Blocks › Add Demo Catalog)
    /// unless its blocks are already there.
    func ensureDemoCatalog(file: StaticString = #filePath, line: UInt = #line) {
        openSidebar("Building Blocks")
        let add = app.buttons["Add Demo Catalog"].firstMatch
        guard add.waitForExistence(timeout: 10) else { return }
        add.click()
        // The button reads "Adding…" while it works; the banner goes once
        // the catalog is added, and the button comes back on an error.
        let adding = app.buttons["Adding…"].firstMatch
        sleep(2)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, adding.exists || add.exists {
            if !adding.exists, add.exists {
                sleep(2)
                if add.exists, !adding.exists { break }
            }
            sleep(1)
        }
        XCTAssertFalse(add.exists || adding.exists, "The demo catalog wasn't added", file: file, line: line)
    }

    /// After a Building block or Clone export: the object list's checkboxes,
    /// up to `limit` (never the type list's, nor the capture options).
    func exportedObjectCheckboxes(limit: Int) -> [XCUIElement] {
        let byType = app.checkBoxes.matching(NSPredicate(format: "label CONTAINS '_category' AND label != 'category'")).allElementsBoundByIndex
        if !byType.isEmpty { return Array(byType.prefix(limit)) }
        // below the object list's None button, above the capture form
        let objectsNone = app.buttons.matching(NSPredicate(format: "identifier == 'None'")).element(boundBy: 1)
        guard objectsNone.exists else { return [] }
        let options: Set<String> = ["Apply the tenant prefix to all object names", "Choose scope and category per tenant (portable block)"]
        let below = app.checkBoxes.allElementsBoundByIndex.filter {
            $0.frame.minY > objectsNone.frame.maxY && !options.contains($0.label) && $0.label != "category" && $0.isHittable
        }
        return Array(below.prefix(limit))
    }

    /// The Export tab's Terraform: reused when downloaded earlier,
    /// otherwise downloaded once (with the consent click).
    func ensureTerraform(on tenant: String, file: StaticString = #filePath, line: UInt = #line) {
        openTenant(tenant, tab: "Export")
        let ready = anyContaining("Discovery engine ready")
        if ready.waitForExistence(timeout: 10) { return }
        let download = app.buttons["Download Terraform"].firstMatch
        if download.waitForExistence(timeout: 10) { download.click() }
        XCTAssertTrue(ready.waitForExistence(timeout: 600), "Terraform isn't ready", file: file, line: line)
    }

    // MARK: Adopt

    /// Adopt Existing Configuration…: discovers `type` objects, stages the
    /// one named `name` and opens its preview from the sheet.
    func adopt(_ name: String, resourceType: String, on tenant: String, file: StaticString = #filePath, line: UInt = #line) {
        openTenant(tenant)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Adopt'")).firstMatch, timeout: 30, file: file, line: line)
        let filter = app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types' OR label == 'Filter types'")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 120), "The adopt sheet didn't list types", file: file, line: line)
        type(String(resourceType.prefix(7)), into: filter)
        tap(app.sheets.buttons["None"], timeout: 30, file: file, line: line)
        tap(app.sheets.checkBoxes.matching(NSPredicate(format: "label == %@", resourceType)).firstMatch, timeout: 60, file: file, line: line)
        tap(app.sheets.buttons["Discover Objects"], file: file, line: line)
        XCTAssertTrue(anyContaining("found — choose").waitForExistence(timeout: 900), "Discovery did not finish", file: file, line: line)
        tap(app.sheets.buttons["None"], file: file, line: line)
        type(name, into: app.sheets.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter objects'")).firstMatch)
        tap(app.sheets.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch, timeout: 30, file: file, line: line)
        tap(app.sheets.buttons["Stage 1 for Adoption"], timeout: 10, file: file, line: line)
        tap(app.sheets.buttons["Preview Changes…"], timeout: 120, file: file, line: line)
    }

    // MARK: Export tab

    /// Picks an export kind, selects only `type` and runs the export.
    func export(kind: String, resourceType: String, from tenant: String, file: StaticString = #filePath, line: UInt = #line) {
        openTenant(tenant, tab: "Export")
        tap(app.radioButtons[kind].firstMatch, timeout: 15, file: file, line: line)
        let filter = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter types'")).firstMatch
        XCTAssertTrue(textMatching("[0-9]+ of [1-9][0-9]* types").waitForExistence(timeout: 120), "Export types didn't load", file: file, line: line)
        type(String(resourceType.prefix(7)), into: filter)
        tap(app.buttons["None"].firstMatch, file: file, line: line)
        tap(app.checkBoxes.matching(NSPredicate(format: "label == %@", resourceType)).firstMatch, timeout: 30, file: file, line: line)
        tap(app.buttons.matching(NSPredicate(format: "label == 'Export'")).firstMatch, file: file, line: line)
    }

    /// A text whose whole value or label matches the regular expression.
    func textMatching(_ pattern: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value MATCHES %@ OR label MATCHES %@", pattern, pattern)).firstMatch
    }

    /// After a Building block or Clone export: the object list's checkboxes
    /// (not the type list's), by name prefix.
    func exportedObjects(beginningWith prefix: String) -> [XCUIElement] {
        app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex
    }

    /// Captures the export's selected objects as a block with the tenant
    /// prefix on every name, into the first folder source (or `folder`,
    /// added as one).
    func captureBlock(id: String, name: String, folder: URL, file: StaticString = #filePath, line: UInt = #line) {
        replaceText(with: id, in: app.textFields.matching(NSPredicate(format: "placeholderValue == 'Block ID (lowercase-with-dashes)'")).firstMatch)
        replaceText(with: name, in: app.textFields.matching(NSPredicate(format: "placeholderValue == 'Block name'")).firstMatch)
        let prefixAll = app.checkBoxes["Apply the tenant prefix to all object names"].firstMatch
        if prefixAll.waitForExistence(timeout: 5), (prefixAll.value as? Int) != 1 { prefixAll.click() }
        let choose = app.buttons["Choose a Folder for Your Blocks…"].firstMatch
        if choose.waitForExistence(timeout: 3) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            choose.click()
            XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 10), "The folder panel did not open", file: file, line: line)
            goToFolder(folder.path)
            tap(app.dialogs.buttons["Use Folder"].firstMatch, timeout: 10, file: file, line: line)
        }
        tap(app.buttons["Capture Building Block"], timeout: 15, file: file, line: line)
        XCTAssertTrue(anyContaining("find it in the Building Blocks library").waitForExistence(timeout: 120),
                      "The block was not captured", file: file, line: line)
    }

    /// Types into a field that already holds a suggested value.
    func replaceText(with text: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing \(field)")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    // MARK: Drift

    /// Keeps the first change listed ("Keep This Change") and checks the note.
    func keepFirstChange(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        tap(app.buttons["Keep This Change"].firstMatch, timeout: 30, file: file, line: line)
        return anyContaining("noted — a future deploy").waitForExistence(timeout: 10) || anyContaining("kept — the baseline").exists
    }

    // MARK: Clean-up

    /// Quits the app, runs `body` (the test's own deletes through the
    /// gateway), records the step and checks the run left nothing.
    func finishLiveTest(step name: String, _ body: () throws -> Void) {
        app?.terminate()
        var problems: [String] = []
        do { try body() } catch { problems.append("\(error)") }
        do { try requireRunObjectsGone() } catch { problems.append("\(error)") }
        recordLive(step: name, passed: problems.isEmpty, note: problems.isEmpty ? nil : problems.joined(separator: "; "))
        XCTAssertTrue(problems.isEmpty, "The test's own objects weren't all removed: \(problems)")
    }
}

// MARK: - The Jamf Pro API through the gateway

/// Jamf Pro API requests a live UI test makes on a role's direct Jamf Pro
/// connection (username and password): its own objects only, through the
/// release check's gateway, which decides each one and keeps the ledger.
/// The password comes from the gateway, never this runner's environment.
final class LiveJamfProAPI: @unchecked Sendable {
    private let gateway: LiveGatewayClient
    private let baseURL: URL
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var token: String?

    struct Failure: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { "HTTP \(status): \(body.prefix(300))" }
    }

    init(gateway: LiveGatewayClient, role: String) throws {
        guard let entry = gateway.launch.connections.first(where: { $0.role == role && $0.connection.service == "jamfPro" }),
              !entry.connection.username.isEmpty, let url = URL(string: entry.connection.serverURL),
              let secret = try gateway.secretNow(role: role, item: entry.secretItem ?? "jamfpro-password"), !secret.isEmpty else {
            throw Failure(status: 0, body: "\(role) has no Jamf Pro user account connection in this run")
        }
        self.gateway = gateway
        baseURL = url
        username = entry.connection.username
        password = secret
    }

    @discardableResult
    func send(_ method: String, _ path: String, json: Any? = nil, accepting: Set<Int> = []) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await gateway.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 && !accepting.contains(status) {
            throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (status, data)
    }

    func object(_ path: String) async throws -> [String: Any] {
        let body = try await send("GET", path).body
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    func create(_ path: String, json: [String: Any]) async throws -> String {
        let body = try await send("POST", path, json: json).body
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let id = (object?["id"] as? String) ?? (object?["id"] as? NSNumber)?.stringValue else {
            throw Failure(status: 0, body: "The create answered without an id")
        }
        return id
    }

    private func bearer() async throws -> String {
        if let token = lock.withLock({ token }) { return token }
        var request = URLRequest(url: baseURL.appending(path: "api/v1/auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await gateway.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["token"] as? String else {
            throw Failure(status: status, body: "The sign-in failed")
        }
        lock.withLock { token = value }
        return value
    }
}

/// A category's priority as a number, whatever JSON type Jamf answered with.
func categoryPriority(_ object: [String: Any]) -> Int? {
    (object["priority"] as? NSNumber)?.intValue ?? (object["priority"] as? String).flatMap(Int.init)
}
