import Foundation
import JTKit

/// The texts in a support bundle. The activity log is JTKit's bug-report
/// export: device identifiers, usernames and IP addresses are replaced with
/// placeholders, as in the Activity Log window's Export for Bug Report…
nonisolated enum SupportBundle {
    static func activityLogText(_ entries: [ActivityLogEntry], app: ActivityLogAppInfo = .current,
                                exported: Date = .now) -> String {
        ActivityLogExport.text(entries, masked: true, app: app, exported: exported)
    }

    /// Versions and team-sync status. The sync message can quote Git or a
    /// server, so it's masked like the log, with the same placeholders.
    static func versionsText(appVersion: String, system: String, isTeamMode: Bool, lastSync: Date?,
                             syncMessage: String?, entries: [ActivityLogEntry]) -> String {
        let message = syncMessage.map { text in
            IdentifierMasker(entries.flatMap(\.identifiers) + IdentifierMasker.identifiers(inText: text)).mask(text)
        }
        return """
        Jamf Deployer \(appVersion)
        \(system)
        OpenTofu \(EngineInfo.openTofuVersion)
        jamfplatform plugin \(EngineInfo.jamfPlatformProviderVersion)
        jamfprotect plugin \(EngineInfo.jamfProtectProviderVersion)
        jamfpro plugin \(EngineInfo.jamfProProviderVersion)
        jamformer \(EngineInfo.jamformerVersion)
        terraform-backend-git \(EngineInfo.stateBackendVersion)
        Team Mode: \(isTeamMode ? "on" : "off")
        Last sync: \(lastSync?.formatted(.iso8601) ?? "-")
        Sync message: \(message ?? "-")
        """
    }
}
