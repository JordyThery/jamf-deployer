import Foundation
import Testing
import JTKit
import JTKitTestSupport
@testable import Jamf_Deployer

/// Settings › Connections reads and writes the tenants' own tenant.json
/// files, which a team shares in Git. They must stay byte for byte as the
/// app writes them, with only the edited connection fields changed.
///
/// The fixtures are earlier tenant.json versions from a real store, with
/// every identifying value replaced by an obviously fake one (layout kept
/// byte for byte). Every test works on copies in a temporary folder.
@MainActor
@Suite("Tenant connections")
struct TenantConnectionTests {

    static let fixtureNames = [
        "platform-new", "platform-baseline", "platform-drift", "platform-handed-over",
        "jamfpro-api-client-drift", "jamfpro-user-new", "jamfpro-user-drift", "jamfpro-user-handed-over",
    ]

    static let fixturesURL = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/tenant-json")

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesURL.appending(path: "\(name).json"))
    }

    /// A store in a temporary folder holding copies of the given files.
    @MainActor
    struct Workspace {
        let folder: URL
        let tenants: TenantStore
        let storage: TenantConnectionStorage
        let store: ConnectionStore<TenantConnection>
        let secrets = InMemorySecretStore()
        let protectSecrets = InMemorySecretStore()

        init(files: [Data], signInID: String? = nil) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "jamf-deployer-tests/\(UUID().uuidString)")
            let root = folder.appending(path: "store/tenants")
            for data in files {
                let id = try Self.decode(data).id
                let tenantFolder = root.appending(path: id.uuidString)
                try FileManager.default.createDirectory(at: tenantFolder, withIntermediateDirectories: true)
                try data.write(to: tenantFolder.appending(path: "tenant.json"))
            }
            tenants = TenantStore(rootURL: root)
            storage = TenantConnectionStorage(tenantStore: tenants, backupURL: folder.appending(path: "connection-backup"),
                                              signInID: { _ in signInID })
            store = ConnectionStore(storage: storage, secrets: [
                .main: SecretLocation(store: secrets),
                .protect: SecretLocation(store: protectSecrets),
            ])
        }

        static func decode(_ data: Data) throws -> Tenant {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Tenant.self, from: data)
        }

        var record: TenantConnection {
            get throws { try #require(store.records.first) }
        }

        func file(_ id: UUID) throws -> Data {
            try Data(contentsOf: tenants.recordURL(for: id))
        }

        /// Every file in the temporary tenants folder, relative to it.
        func storeFiles() throws -> [String] {
            let root = tenants.rootURL
            let paths = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
            return paths.filter { !$0.hasSuffix("/") && $0.contains(".") }.sorted()
        }

        func clean() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The lines that differ between two files: (removed, added).
    static func changedLines(_ before: Data, _ after: Data) -> (removed: [String], added: [String]) {
        let old = String(decoding: before, as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: after, as: UTF8.self).components(separatedBy: "\n")
        let diff = new.difference(from: old)
        var removed = [String](), added = [String]()
        for change in diff {
            switch change {
            case .remove(_, let line, _): removed.append(line.trimmingCharacters(in: .whitespaces))
            case .insert(_, let line, _): added.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return (removed, added)
    }

    // MARK: Byte for byte

    @Test(arguments: fixtureNames)
    func todaysWriterKeepsEveryFixtureByteForByte(_ name: String) throws {
        let original = try Self.fixture(name)
        #expect(try JSONFile.encode(Workspace.decode(original)) == original)
    }

    /// The region is JTKit's since step 6; every saved value reads as before
    /// and is written back unchanged.
    @Test(arguments: [("us", JamfRegion.us), ("eu", .eu), ("apac", .apac)])
    func everySavedRegionReadsAndWritesAsBefore(raw: String, region: JamfRegion) throws {
        let text = String(decoding: try Self.fixture("platform-new"), as: UTF8.self)
            .replacingOccurrences(of: #""region" : "us""#, with: #""region" : "\#(raw)""#)
        let original = Data(text.utf8)
        let tenant = try Workspace.decode(original)
        #expect(tenant.region == region)
        #expect(try JSONFile.encode(tenant) == original)
    }

    @Test(arguments: fixtureNames)
    func savingWithoutChangesLeavesTheFileUntouched(_ name: String) throws {
        let original = try Self.fixture(name)
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        let record = try workspace.record
        try workspace.store.save(record)
        try workspace.storage.save(workspace.store.records)
        #expect(try workspace.file(record.id) == original)
    }

    @Test(arguments: fixtureNames)
    func renamingChangesOnlyTheNameLine(_ name: String) throws {
        let original = try Self.fixture(name)
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        let oldName = record.connection.name
        record.connection.name = "Renamed Tenant"
        try workspace.store.save(record)

        let lines = Self.changedLines(original, try workspace.file(record.id))
        #expect(lines.removed == ["\"name\" : \"\(oldName)\","])
        #expect(lines.added == ["\"name\" : \"Renamed Tenant\","])
        #expect(workspace.tenants.tenant(id: record.id)?.name == "Renamed Tenant")
    }

    @Test(arguments: fixtureNames)
    func changingTheClientIDOrUsernameChangesOnlyItsLine(_ name: String) throws {
        let original = try Self.fixture(name)
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        let oldID = workspace.tenants.tenant(id: record.id)?.clientID ?? ""
        if record.connection.signIn == .usernamePassword {
            record.connection.username = "new-admin"
        } else {
            record.connection.clientID = "new-admin"
        }
        try workspace.store.save(record)

        // a user account's username is kept in clientID, as today
        let lines = Self.changedLines(original, try workspace.file(record.id))
        #expect(lines.removed == ["\"clientID\" : \"\(oldID)\","])
        #expect(lines.added == ["\"clientID\" : \"new-admin\","])
    }

    @Test(arguments: fixtureNames)
    func readOnlyFieldsAreNeverWritten(_ name: String) throws {
        let original = try Self.fixture(name)
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        // even when changed without the editor, which shows them as text
        record.connection.service = record.connection.service == .jamfPro ? .jamfPlatform : .jamfPro
        record.connection.signIn = record.connection.signIn == .apiClient ? .usernamePassword : .apiClient
        record.connection.region = record.connection.region == .eu ? .us : .eu
        record.connection.serverURL = "https://elsewhere.example.com"
        record.connection.environmentID = "44444444-4444-4444-8444-444444444444"
        record.connection.hostOverride = "staging.example.com"
        record.connection.jamfProWebURL = "https://elsewhere.example.com"
        record.connection.tenantID = "contoso.example.com"
        record.connection.keyID = "KEY"
        try workspace.store.save(record)
        #expect(try workspace.file(record.id) == original)
    }

    @Test(arguments: fixtureNames)
    func readingAndSettingTheConnectionLeavesTheTenantUnchanged(_ name: String) throws {
        let tenant = try Workspace.decode(Self.fixture(name))
        var record = TenantConnection(tenant: tenant)
        let read = record.connection
        record.connection = read
        #expect(record.applyingEdits(to: tenant) == tenant)
        #expect(!record.hasChanges)
    }

    // MARK: Jamf Protect

    /// A Platform tenant with Protect, as the wizard writes it.
    static func protectedTenantFile() throws -> Data {
        var tenant = try Workspace.decode(fixture("platform-new"))
        tenant.protectURL = "https://protect.example.com"
        tenant.protectClientID = "55555555-5555-4555-8555-555555555555"
        return try JSONFile.encode(tenant)
    }

    @Test func turningProtectOnAddsOnlyItsLinesAndOffRestoresTheFile() throws {
        let original = try Self.fixture("platform-new")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        #expect(record.connection.protect == nil)
        record.connection.protect = JamfProtectSettings(url: "https://protect.example.com",
                                                        clientID: "55555555-5555-4555-8555-555555555555")
        try workspace.store.save(record)
        #expect(try workspace.file(record.id) == Self.protectedTenantFile())
        let lines = Self.changedLines(original, try workspace.file(record.id))
        #expect(lines.removed.isEmpty)
        #expect(lines.added == [
            "\"protectClientID\" : \"55555555-5555-4555-8555-555555555555\",",
            "\"protectURL\" : \"https:\\/\\/protect.example.com\",",
        ])

        var saved = try workspace.record
        saved.connection.protect = nil
        try workspace.store.save(saved)
        #expect(try workspace.file(record.id) == original)
    }

    @Test func changingTheProtectClientIDChangesOnlyItsLine() throws {
        let original = try Self.protectedTenantFile()
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        record.connection.protect?.clientID = "66666666-6666-4666-8666-666666666666"
        try workspace.store.save(record)
        let lines = Self.changedLines(original, try workspace.file(record.id))
        #expect(lines.removed == ["\"protectClientID\" : \"55555555-5555-4555-8555-555555555555\","])
        #expect(lines.added == ["\"protectClientID\" : \"66666666-6666-4666-8666-666666666666\","])
    }

    @Test func jamfProTenantsNeverGetProtectFields() throws {
        let original = try Self.fixture("jamfpro-user-new")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        record.connection.protect = JamfProtectSettings(url: "https://example.protect.example.com", clientID: "x")
        try workspace.store.save(record)
        #expect(try workspace.file(record.id) == original)
    }

    // MARK: Team Mode

    @Test func inTeamModeTheSharedClientIDIsShownReadOnlyAndNeverWritten() throws {
        let original = try Self.fixture("platform-baseline")
        let workspace = try Workspace(files: [original], signInID: "my-own-client")
        defer { workspace.clean() }
        var record = try workspace.record
        #expect(record.connection.clientID == "my-own-client")
        #expect(record.readOnlyFields.isSuperset(of: [.clientID, .username, .region, .environmentID, .serverURL, .signIn]))
        record.connection.clientID = "someone-else"
        try workspace.store.save(record)
        #expect(try workspace.file(record.id) == original)
    }

    @Test func outsideTeamModeOnlyTheConnectionIsReadOnly() throws {
        let workspace = try Workspace(files: [Self.fixture("platform-new")])
        defer { workspace.clean() }
        #expect(try workspace.record.readOnlyFields == [.signIn, .region, .serverURL, .environmentID])
    }

    // MARK: Safety

    @Test func aChangeMadeOnDiskMeanwhileIsKept() throws {
        let original = try Self.fixture("platform-baseline")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        // a teammate's change arrives through Git while Settings is open
        var teammate = try Workspace.decode(original)
        teammate.namePrefix = "TEAM - "
        try JSONFile.save(teammate, to: workspace.tenants.recordURL(for: record.id))

        record.connection.name = "Renamed Tenant"
        try workspace.store.save(record)
        let saved = try Workspace.decode(workspace.file(record.id))
        #expect(saved.name == "Renamed Tenant")
        #expect(saved.namePrefix == "TEAM - ")
    }

    @Test func aFileThisVersionDoesNotWriteIsNeverChanged() throws {
        let original = try Self.fixture("platform-baseline")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        // e.g. a field added by a newer version on a teammate's Mac
        let newer = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "{\n", with: "{\n  \"addedByNewerVersion\" : true,\n", options: [.anchored])
            .utf8)
        try newer.write(to: workspace.tenants.recordURL(for: record.id))

        record.connection.name = "Renamed Tenant"
        #expect(throws: ConnectionStoreError.self) { try workspace.store.save(record) }
        #expect(try workspace.file(record.id) == newer)
    }

    @Test func savingTwiceKeepsTheSecondChange() throws {
        let original = try Self.fixture("platform-new")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        var record = try workspace.record
        let oldName = record.connection.name
        record.connection.name = "Renamed Tenant"
        try workspace.store.save(record)
        // the editor continues from what the store read back
        var saved = try workspace.record
        #expect(!saved.hasChanges)
        saved.connection.name = oldName
        try workspace.store.save(saved)
        #expect(try workspace.file(record.id) == original)
    }

    @Test func onlyTheEditedTenantIsWritten() throws {
        let files = try ["platform-new", "jamfpro-user-new", "platform-drift"].map(Self.fixture)
        let workspace = try Workspace(files: files)
        defer { workspace.clean() }
        let others = workspace.store.records.dropFirst().map(\.id)
        let before = try others.map(workspace.file)
        var record = try workspace.record
        record.connection.name = "Renamed Tenant"
        try workspace.store.save(record)
        #expect(try others.map(workspace.file) == before)
    }

    @Test func theBackupIsMadeOnceAndOutsideTheStore() throws {
        let original = try Self.fixture("platform-baseline")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        let filesBefore = try workspace.storeFiles()
        var record = try workspace.record
        record.connection.name = "First"
        try workspace.store.save(record)
        record = try workspace.record
        record.connection.name = "Second"
        try workspace.store.save(record)

        let backup = workspace.storage.backupURL.appending(path: "\(record.id.uuidString)/tenant.json")
        #expect(try Data(contentsOf: backup) == original)
        #expect(!workspace.storage.backupURL.path.hasPrefix(workspace.tenants.rootURL.path))
        // nothing new inside the Git store
        #expect(try workspace.storeFiles() == filesBefore)
    }

    @Test func anUnreadableFileIsLeftAloneAndTheOthersStayEditable() throws {
        let workspace = try Workspace(files: [Self.fixture("platform-new")])
        defer { workspace.clean() }
        let brokenURL = workspace.tenants.rootURL.appending(path: "\(UUID().uuidString)/tenant.json")
        try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("{ \"name\" : ".utf8)
        try broken.write(to: brokenURL)
        workspace.tenants.reload()
        workspace.store.reload()
        let filesBefore = try workspace.storeFiles()

        #expect(workspace.tenants.unreadableFiles.map(\.lastPathComponent) == ["tenant.json"])
        #expect(workspace.store.problem == nil)
        var record = try workspace.record
        record.connection.name = "Renamed Tenant"
        try workspace.store.save(record)
        #expect(try Data(contentsOf: brokenURL) == broken)
        #expect(try workspace.storeFiles() == filesBefore)
        #expect(workspace.storage.keepUnreadableCopy() == nil)
    }

    // MARK: Keychain

    @Test func secretsUseTheKeychainItemsTheAppAlwaysUsed() throws {
        let locations = TenantSecrets.connectionSecrets
        #expect(Set(locations.keys) == [.main, .protect])
        // wrapped so a change made in Settings drops the tenant's API client
        let main = try #require(locations[.main]?.store as? ReportingSecretStore).base
        let protect = try #require(locations[.protect]?.store as? ReportingSecretStore).base
        #expect(main.service == "be.jordythery.jamf-deployer.platform-client-secret")
        #expect(protect.service == "be.jordythery.jamf-deployer.protect-client-secret")
        #expect(main.accessibility == .whenUnlocked && protect.accessibility == .whenUnlocked)
        #expect(main.label == nil && protect.label == nil)
        #expect(!main.movesItemsFromDataProtectionKeychain)

        let id = UUID()
        let connection = Connection(id: id, name: "Example", service: .jamfPlatform)
        #expect(locations[.main]?.account(connection) == id.uuidString)
        #expect(locations[.protect]?.account(connection) == id.uuidString)
        let secrets = TenantSecrets(tenantID: id)
        #expect(secrets.platformClientSecret.service == main.service)
        #expect(secrets.protectClientSecret.service == protect.service)
        #expect(secrets.platformClientSecret.account == id.uuidString)
    }

    @Test func anEditedSecretGoesToTheTenantsAccountAndNeverIntoTheFile() throws {
        let original = try Self.fixture("platform-new")
        let workspace = try Workspace(files: [original])
        defer { workspace.clean() }
        let record = try workspace.record
        try workspace.store.save(record, secrets: [.main: "new-secret", .protect: "new-protect-secret"])
        #expect(workspace.secrets.all == [record.id.uuidString: "new-secret"])
        #expect(workspace.protectSecrets.all == [record.id.uuidString: "new-protect-secret"])
        #expect(try workspace.file(record.id) == original)
    }
}
