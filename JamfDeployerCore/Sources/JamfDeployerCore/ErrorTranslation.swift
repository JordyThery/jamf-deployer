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
            // jamformer: Pipeline failed: terraform query: … exit status 1
            "terraform query failed",
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
        translateIfKnown(raw) ?? Translation(
            message: "Something went wrong while talking to Jamf.",
            hint: "Open the technical details to see the exact error, or create a support bundle."
        )
    }

    /// The table match alone — nil when the error is unrecognized, so
    /// callers can keep their own context-specific fallback.
    public static func translateIfKnown(_ raw: String) -> Translation? {
        for entry in table where raw.localizedCaseInsensitiveContains(entry.pattern) {
            return Translation(message: entry.message, hint: entry.hint)
        }
        return nil
    }
}
