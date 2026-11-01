import Foundation

/// The rules and texts of Remove Tenant, shared by the sidebar and
/// Settings › Connections.
nonisolated enum TenantRemoval {
    /// Removing a managed tenant deletes its deployment state for good, so
    /// it asks for the tenant's name, like Hand Over and production deploys.
    static func needsTypedName(isManaged: Bool) -> Bool {
        isManaged
    }

    /// Whether the typed name confirms the removal.
    static func confirms(typed: String, tenantName: String) -> Bool {
        typed == tenantName
    }

    /// Why removing isn't possible now: engine work (a deploy, a preview,
    /// a check) would lose its folder and state halfway.
    static func refusal(isEngineBusy: Bool) -> String? {
        isEngineBusy ? busyText : nil
    }

    static let busyText = "Wait for the running deploy, preview or check to finish, then remove the tenant."

    /// Settings › Connections can't ask for the tenant's name, so a managed
    /// tenant is removed from the sidebar.
    static let managedFromSettingsText = "This tenant has objects the app manages. Remove it with Remove Tenant… in the sidebar, which asks you to type its name."

    /// The confirmation's text.
    static func message(isTeamMode: Bool, isManaged: Bool) -> String {
        switch (isTeamMode, isManaged) {
        case (true, false):
            "Nothing in Jamf is changed. The tenant record and its state are deleted from the team space for everyone, and its credentials from this Mac."
        case (true, true):
            "Nothing in Jamf is changed, but the tenant record and its deployment state are deleted from the team space for everyone, and its credentials from this Mac. The app then no longer knows which objects it manages there, and getting them back means adopting them again. To keep them managed elsewhere, use Hand Over Tenant… or Export as Terraform… instead. Type the tenant name to confirm."
        case (false, false):
            "Nothing in Jamf is changed. The tenant record kept by this app and its stored credentials are deleted."
        case (false, true):
            "Nothing in Jamf is changed, but the tenant’s deployment state and its passphrase are deleted for good, with its record and credentials. The app then no longer knows which objects it manages there, and getting them back means adopting them again. To keep them managed elsewhere, use Hand Over Tenant… or Export as Terraform… instead. Type the tenant name to confirm."
        }
    }
}
