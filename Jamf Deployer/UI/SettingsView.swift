import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JTKit

/// Settings › General. The daily update
/// check is in JTKit's Updates tab, under the same "checksForUpdates" key.
struct GeneralSettingsSections: View {
    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false
    @AppStorage("engineerName") private var engineerName = ""

    var body: some View {
        Section {
            Toggle("Show technical details", isOn: $showsTechnicalDetails)
        } header: {
            Text("Interface")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reveals generated configuration, raw change plans and engine logs. Previews then show the commands behind them, which is the first step to running Terraform yourself.")
                Link("Graduating to Terraform", destination: DocsLinks.stage(1))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
            TextField("Engineer name", text: $engineerName, prompt: Text(NSFullUserName()))
        } header: {
            Text("History")
        } footer: {
            Text("Recorded with every deploy, so a team can see who changed what.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Advanced: the bundled tools' versions and the support bundle,
/// for troubleshooting.
struct AdvancedSettingsSections: View {
    @Environment(ComponentUpdateChecker.self) private var componentUpdates

    var body: some View {
        Section {
            ForEach(componentUpdates.components) { component in
                LabeledContent(component.name) {
                    HStack(spacing: 6) {
                        Text(component.pinned)
                        if component.hasUpdate, let latest = component.latest {
                            Label("\(latest) available", systemImage: "arrow.up.circle.fill")
                                .labelStyle(.tintedIcon(.orange))
                        }
                    }
                }
            }
        } header: {
            Text("Built-in tools")
        } footer: {
            Text(componentUpdates.updatesAvailable.isEmpty
                ? "These components change only with app updates, never silently. Checked against their releases once a day."
                : "Newer releases exist upstream — they arrive with the next app update.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Diagnostics") {
            SupportBundleButton()
        }
    }
}


/// Zips a redacted diagnostics bundle: versions, sync status and the
/// activity log — never secrets, never tenant records or state.
struct SupportBundleButton: View {
    @Environment(ActivityLog.self) private var activityLog
    @Environment(TenantDeployService.self) private var deployService
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Create Support Bundle…", systemImage: "cross.case") {
                createBundle()
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Contains app and tool versions, team-sync status and the activity log, with device identifiers, usernames and IP addresses replaced by placeholders. Secrets, tenant records and tenant state are never included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func createBundle() {
        do {
            let staging = FileManager.default.temporaryDirectory
                .appending(path: "jd-support-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let entries = activityLog.entries
            let versions = SupportBundle.versionsText(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                isTeamMode: deployService.isTeamMode, lastSync: deployService.lastSync,
                syncMessage: deployService.syncMessage, entries: entries)
            try Data(versions.utf8).write(to: staging.appending(path: "versions.txt"))

            // masked, as the Activity Log window's Export for Bug Report…
            let log = SupportBundle.activityLogText(entries)
            try Data(log.utf8).write(to: staging.appending(path: "activity-log.txt"))

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "JamfDeployer-Support-\(Date.now.formatted(.iso8601.year().month().day())).zip"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let ditto = Process()
            ditto.standardInput = FileHandle.nullDevice
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", staging.path, destination.path]
            try ditto.run()
            ditto.waitUntilExit()
            message = ditto.terminationStatus == 0
                ? "Saved \(destination.lastPathComponent)."
                : "The support bundle couldn’t be written."
        } catch {
            message = error.localizedDescription
        }
    }
}
