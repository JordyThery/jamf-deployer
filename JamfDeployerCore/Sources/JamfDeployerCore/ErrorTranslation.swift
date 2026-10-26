import Foundation

/// Maps known engine and provider errors to plain language. The raw text
/// stays available behind "Show details". The table grows as new provider
/// errors are met in the field.
public nonisolated enum ErrorTranslation {
    public struct Translation: Sendable {
        public var message: String
        public var hint: String?
    }

    /// How the tenant signs in, for the entries whose fix depends on it: a
    /// direct Jamf Pro tenant has no region and no Jamf Account, and a user
    /// account has no client secret.
    public enum Connection: Sendable {
        case platform
        case jamfProAPIClient
        case jamfProUser
    }

    /// The wording for direct Jamf Pro tenants, by `table` pattern: API
    /// client, then user account. Patterns not listed read the same for
    /// every connection.
    static let jamfProWording: [String: (apiClient: Translation, user: Translation)] = [
        "status 401": (
            Translation(
                message: "Jamf Pro did not accept the stored credentials.",
                hint: "The client secret may have been rotated or the API client disabled. Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients."
            ),
            Translation(
                message: "Jamf Pro did not accept the stored credentials.",
                hint: "The password may have changed. Check the username and password, and update the password on the tenant page."
            )
        ),
        "status 403": (
            Translation(
                message: "The API client is missing a privilege for this object.",
                hint: "Add the privileges listed on the building block to the API role in Jamf Pro under Settings › API Roles and Clients."
            ),
            Translation(
                message: "The user account is missing a privilege for this object.",
                hint: "Add the privileges listed on the building block to the user account in Jamf Pro under Settings › User Accounts and Groups."
            )
        ),
        "no such host": (
            Translation(message: "The Jamf Pro address could not be found.", hint: "Check the tenant's Jamf Pro URL."),
            Translation(message: "The Jamf Pro address could not be found.", hint: "Check the tenant's Jamf Pro URL.")
        ),
    ]

    static let table: [(pattern: String, message: String, hint: String?)] = [
        (
            "status 401",
            "Jamf did not accept the stored credentials.",
            "The API integration may have been rotated or disabled. Update the client secret in the tenant's settings."
        ),
        (
            "status 403",
            "The API integration is missing a permission for this object.",
            "Open the integration in Jamf Account and grant the permissions listed on the building block."
        ),
        (
            // jamformer wraps the failure as "terraform query failed: …" or
            // "Pipeline failed: terraform query: … exit status 1".
            "terraform query",
            "The exporter could not read one of the selected object types from this tenant.",
            "Settings-style types can be unavailable on some tenants. Deselect the type that fails and export again."
        ),
        (
            "undeclared input variable",
            "The block's configuration references a variable it does not declare.",
            "Usually a block captured by an older app version — re-capture it, or declare the variable in the block folder (Reveal in Finder from its detail view)."
        ),
        (
            "Failed to resolve provider packages",
            "The deployment engine could not load its built-in Jamf support.",
            "Reinstall the app, then try again. If it keeps happening, create a support bundle."
        ),
        (
            "connection refused",
            "Jamf could not be reached.",
            "Check your internet connection and whether Jamf reports an outage, then try again."
        ),
        (
            "no such host",
            "The Jamf address could not be found.",
            "Check the tenant's region setting."
        ),
        (
            "context deadline exceeded",
            "Jamf took too long to answer and the step timed out.",
            "Try again. Large tenants can need a second attempt."
        ),
        (
            "status 429",
            "Jamf is rate-limiting requests right now.",
            "Wait a minute and try again; the engine already paces itself."
        ),
        (
            "state snapshot was created by OpenTofu",
            "This tenant record was written by a newer version of the app.",
            "Update Jamf Deployer to its latest version and try again."
        ),
        (
            "JAMFPROTECT_URL",
            "The Jamf Protect connection details are missing or wrong.",
            "Check the Protect console URL and API client under the tenant's Day 0 Setup tab."
        ),
        (
            // Captured live: jamfplatform 1.5.0 on profile creates.
            "invalid result object after apply",
            "Jamf created the object, but the provider reported an incomplete result — a provider bug, not a tenant problem.",
            "The object is saved in the tenant record. Run Check for Changes; if nothing shows for it, everything is in order."
        ),
        (
            // Captured live: [DUPLICATE_FIELD] name: duplicate name
            "DUPLICATE_FIELD",
            "An object with this name already exists in Jamf.",
            "Another building block, an adopted object or something created by hand already uses the name. If these objects were captured from this tenant, use Adopt instead of re-deploying the captured block — or set a different name prefix."
        ),
        (
            // Captured live: jamfplatform 1.5.0 creating UEM Connect where one exists.
            "A UEM Connect integration already exists",
            "Jamf Security Cloud is already connected to Jamf Pro, and it holds one UEM Connect integration per tenant.",
            "In the Security Cloud block's settings, set UEM Connect to \u{201C}Use the existing connection\u{201D}. The block then creates only the activation profile and leaves the connection as it is."
        ),
        (
            // Captured live: the Security Cloud block reading a connection that is not there.
            "No UEM Connect integration on this tenant",
            "Jamf Security Cloud is not connected to Jamf Pro yet.",
            "In the Security Cloud block's settings, set UEM Connect to \u{201C}Connect this Jamf Pro tenant\u{201D}, so the block makes the connection."
        ),
        (
            // Captured live: [TENANT_NOT_FOUND] No tenant found for environment '…'
            "TENANT_NOT_FOUND",
            "This environment does not include Jamf Security Cloud.",
            "Remove the Security Cloud blocks from the baseline, or talk to Jamf about adding the entitlement. Nothing else in the baseline is affected."
        ),
        (
            "securitycloud",
            "Jamf Security Cloud rejected the request — the environment may not be entitled.",
            "Remove the Security Cloud blocks from the baseline, or talk to Jamf about the entitlement."
        ),
        (
            // Captured live: 409 when the location holds no licenses.
            "not available for device assignment",
            "The tenant has no Apps and Books licenses for this app.",
            "Get the app for the tenant's location in Apple Business Manager (free apps too), wait for Jamf to sync the licenses, then preview again."
        ),
        (
            "Missing required argument",
            "A building block is missing a required setting.",
            "Open the block's settings and fill in the highlighted fields."
        ),
        (
            "Invalid combination of arguments",
            "Two settings on a building block contradict each other.",
            "Review the block's settings; the technical details name the exact fields."
        ),
        (
            // Captured live: Jamf answers some creates with 500/502/503/504
            // under load, sometimes after creating the object. Last, so the
            // specific entries above win when their text carries a status.
            "status 50",
            "Jamf had a temporary server problem with this object.",
            "Preview Changes again. Policies, configuration profiles, patch titles and App Installers that Jamf created despite the error are adopted rather than created twice."
        ),
    ]

    public static func translate(_ raw: String, for connection: Connection = .platform) -> Translation {
        translateIfKnown(raw, for: connection) ?? Translation(
            message: "Something went wrong while talking to Jamf.",
            hint: "Open the technical details to see the exact error, or create a support bundle."
        )
    }

    /// The table match alone — nil when the error is unrecognized, so
    /// callers can keep their own context-specific fallback.
    public static func translateIfKnown(_ raw: String, for connection: Connection = .platform) -> Translation? {
        for entry in table where raw.localizedCaseInsensitiveContains(entry.pattern) {
            switch (connection, jamfProWording[entry.pattern]) {
            case (.jamfProAPIClient, let wording?): return wording.apiClient
            case (.jamfProUser, let wording?): return wording.user
            default: return Translation(message: entry.message, hint: entry.hint)
            }
        }
        return nil
    }
}
