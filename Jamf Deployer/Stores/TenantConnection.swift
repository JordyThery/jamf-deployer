import Foundation
import JTKit

/// One tenant as the shared Connections tab in Settings sees it.
///
/// The tenant's connection fields are mapped to JTKit's `Connection`; its
/// deployment data stays with the tenant. Only the name, the client ID or
/// username and the Jamf Protect fields can be edited. URL, region, scope
/// and connection kind are fixed when the tenant is connected.
nonisolated struct TenantConnection: ConnectionRecord {
    /// The tenant as it was read. Edits are applied onto the file on disk,
    /// never onto this copy, so deployment data is never taken from it.
    let tenant: Tenant
    /// Team Mode: this Mac signs in with its own client ID or username
    /// (Update Client Secret… in the tenant view), so the record's own one
    /// is read-only here.
    let usesOwnSignIn: Bool
    /// The connection as it was read, to tell which fields were edited.
    let original: Connection
    var connection: Connection

    var id: UUID { tenant.id }

    /// - Parameter signInID: in Team Mode, the client ID or username this
    ///   Mac signs in with; nil outside Team Mode.
    init(tenant: Tenant, signInID: String? = nil) {
        self.tenant = tenant
        usesOwnSignIn = signInID != nil
        original = Self.connection(of: tenant, signInID: signInID)
        connection = original
    }

    static func connection(of tenant: Tenant, signInID: String?) -> Connection {
        let usesPassword = tenant.isJamfPro && tenant.jamfProAuth == .userAccount
        let signInName = signInID ?? tenant.clientID
        let protect = tenant.protectURL == nil && tenant.protectClientID == nil
            ? nil
            : JamfProtectSettings(url: tenant.protectURL ?? "", clientID: tenant.protectClientID ?? "")
        return Connection(
            id: tenant.id,
            name: tenant.name,
            service: tenant.isJamfPro ? .jamfPro : .jamfPlatform,
            signIn: usesPassword ? .usernamePassword : .apiClient,
            serverURL: tenant.jamfProURL ?? "",
            region: JamfRegion(rawValue: tenant.region.rawValue) ?? .us,
            environmentID: tenant.environmentID ?? "",
            clientID: usesPassword ? "" : signInName,
            username: usesPassword ? signInName : "",
            protect: protect
        )
    }

    /// The fields that stay as they were when the tenant was connected.
    var readOnlyFields: Set<ConnectionField> {
        var fields: Set<ConnectionField> = [.signIn, .region, .serverURL, .environmentID]
        if usesOwnSignIn {
            fields.formUnion([.clientID, .username])
        }
        return fields
    }

    var hasChanges: Bool { connection != original }

    /// `target` (the tenant as it is on disk now) with the fields edited
    /// in Settings. Only fields that differ from `original` are written, so
    /// a change a teammate synced in the meantime is kept. Every other field
    /// stays exactly as in `target`.
    func applyingEdits(to target: Tenant) -> Tenant {
        var result = target
        let edited = connection
        if edited.name != original.name {
            result.name = Self.trimmed(edited.name)
        }
        if !usesOwnSignIn {
            // a user account's username is kept in `clientID`
            let usesPassword = original.signIn == .usernamePassword
            let editedID = usesPassword ? edited.username : edited.clientID
            let originalID = usesPassword ? original.username : original.clientID
            if editedID != originalID {
                result.clientID = Self.trimmed(editedID)
            }
        }
        if !target.isJamfPro {
            // Protect is part of Platform connections only, as in the wizard
            if edited.protect?.url != original.protect?.url {
                result.protectURL = Self.nonEmpty(edited.protect?.url)
            }
            if edited.protect?.clientID != original.protect?.clientID {
                result.protectClientID = Self.nonEmpty(edited.protect?.clientID)
            }
        }
        return result
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil for a missing or empty value, as the wizard stores it.
    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}

/// Why a tenant's connection was not saved, in plain language.
nonisolated enum TenantConnectionError: LocalizedError, Equatable {
    case notFound(String)
    case unreadable(String)
    case notThisFormat(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            "“\(name)” is no longer in the store. It may have been removed on another Mac."
        case .unreadable(let name):
            "The record of “\(name)” could not be read, so it was not changed."
        case .notThisFormat(let name):
            "The record of “\(name)” contains something this version of Jamf Deployer doesn’t write, for example from a newer version on a teammate’s Mac. Nothing was changed. Update Jamf Deployer, then try again."
        }
    }
}

/// Reads and writes the tenants for JTKit's Connections tab, in
/// `store/tenants/<id>/tenant.json`: the Git repository a team shares.
///
/// Every file stays byte for byte as the app writes it. A save:
/// - writes only tenants whose connection fields were edited;
/// - starts from the file on disk, not the copy in the list, and changes
///   only the edited fields (`TenantConnection.applyingEdits`);
/// - first checks that the file on disk is exactly what this version would
///   write for it, and otherwise writes nothing, so a field this version
///   doesn't know (or a hand edit) is never dropped;
/// - writes through `TenantStore`, with the same `JSONFile` format as always.
///
/// Nothing is ever written into the repository besides the edited
/// tenant.json: the one-time backup goes outside it, and unreadable files
/// are left in place, not copied.
@MainActor
final class TenantConnectionStorage: ConnectionStorage {
    typealias Record = TenantConnection

    private let tenantStore: TenantStore
    private let signInID: (Tenant) -> String?
    /// The one-time backup of every tenant.json, outside the Git store.
    let backupURL: URL

    /// - Parameter signInID: in Team Mode, the client ID or username this
    ///   Mac signs in with for a tenant; nil outside Team Mode.
    init(tenantStore: TenantStore, backupURL: URL, signInID: @escaping (Tenant) -> String?) {
        self.tenantStore = tenantStore
        self.backupURL = backupURL
        self.signInID = signInID
    }

    /// Outside the store, so it is never committed or pushed to the team.
    static var defaultBackupURL: URL {
        GitStoreService.storeURL.deletingLastPathComponent().appending(path: "connection-backup")
    }

    func load() throws -> [TenantConnection] {
        tenantStore.tenants.map { TenantConnection(tenant: $0, signInID: signInID($0)) }
    }

    func save(_ records: [TenantConnection]) throws {
        for record in records where record.hasChanges {
            try write(record)
        }
    }

    private func write(_ record: TenantConnection) throws {
        let name = record.original.name
        guard tenantStore.tenant(id: record.id) != nil else { throw TenantConnectionError.notFound(name) }
        let file = tenantStore.recordURL(for: record.id)
        let data: Data
        let onDisk: Tenant
        do {
            data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            onDisk = try decoder.decode(Tenant.self, from: data)
        } catch {
            throw TenantConnectionError.unreadable(name)
        }
        guard (try? JSONFile.encode(onDisk)) == data else {
            throw TenantConnectionError.notThisFormat(name)
        }
        let updated = record.applyingEdits(to: onDisk)
        guard updated != onDisk else { return }
        try tenantStore.write(updated)
    }

    /// Copies every tenant.json to `backupURL/<id>/tenant.json`, once.
    func backUpOnce() throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: backupURL.path) else { return }
        let records = tenantStore.tenants.map { tenantStore.recordURL(for: $0.id) }
            + tenantStore.unreadableFiles
        let existing = records.filter { files.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        // a partial backup is removed, so the next save tries again
        let partial = backupURL.appendingPathExtension("partial")
        try? files.removeItem(at: partial)
        do {
            for file in existing {
                let folder = partial.appending(path: file.deletingLastPathComponent().lastPathComponent)
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                try files.copyItem(at: file, to: folder.appending(path: file.lastPathComponent))
            }
            try files.moveItem(at: partial, to: backupURL)
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
    }

    /// Unreadable files stay where they are: a copy next to them would be
    /// pushed to the whole team. The Connections tab names them instead.
    func keepUnreadableCopy() -> String? {
        nil
    }
}
