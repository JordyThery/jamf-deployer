import Foundation

/// Maps known engine and provider errors to plain language. The raw text
/// stays available behind "Show details". The table grows as new provider
/// errors are met in the field.
public nonisolated enum ErrorTranslation {
    public struct Translation: Sendable {
        public var message: String
        public var hint: String?
    }

    static let table: [(pattern: String, message: String, hint: String?)] = [
        (
            "401",
            "Jamf did not accept the stored credentials.",
            "The API integration may have been rotated or disabled. Update the client secret in the tenant's settings."
        ),
        (
            "403",
            "The API integration is missing a permission for this object.",
            "Open the integration in Jamf Account and grant the permissions listed on the building block."
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
            "429",
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
            // Captured live: [DUPLICATE_FIELD] name: duplicate name
            "DUPLICATE_FIELD",
            "An object with this name already exists in Jamf.",
            "Another building block, an adopted object or something created by hand already uses the name. If these objects were captured from this tenant, use Adopt instead of re-deploying the captured block — or set a different name prefix."
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
            "Missing required argument",
            "A building block is missing a required setting.",
            "Open the block's settings and fill in the highlighted fields."
        ),
        (
            "Invalid combination of arguments",
            "Two settings on a building block contradict each other.",
            "Review the block's settings; the technical details name the exact fields."
        ),
    ]

    public static func translate(_ raw: String) -> Translation {
        for entry in table where raw.localizedCaseInsensitiveContains(entry.pattern) {
            return Translation(message: entry.message, hint: entry.hint)
        }
        return Translation(
            message: "Something went wrong while talking to Jamf.",
            hint: "Open the technical details to see the exact error, or create a support bundle."
        )
    }
}
