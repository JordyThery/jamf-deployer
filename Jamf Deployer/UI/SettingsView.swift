import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeployerKit

/// Versions of the tools that ship inside the app. They only change with app
/// updates, never silently.
nonisolated enum EngineInfo {
    static let openTofuVersion = "1.13.1"
    static let jamfPlatformProviderVersion = "1.5.0"
    static let jamfProtectProviderVersion = "0.12.0"
    static let jamfProProviderVersion = "0.42.0"
    static let jamformerVersion = "0.6.0"
    static let stateBackendVersion = "0.1.12"
}

struct SettingsView: View {
    @Environment(ComponentUpdateChecker.self) private var componentUpdates
    @AppStorage("checksForUpdates") private var checksForUpdates = true
    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false
    @AppStorage("engineerName") private var engineerName = ""

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for app updates automatically", isOn: $checksForUpdates)
            }

            TeamSettingsView()

            Section {
                TextField("Engineer name", text: $engineerName, prompt: Text(NSFullUserName()))
            } header: {
                Text("History")
            } footer: {
                Text("Recorded with every deploy, so a team can see who changed what.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show technical details", isOn: $showsTechnicalDetails)
            } header: {
                Text("Interface")
            } footer: {
                Text("Reveals generated configuration, raw change plans and engine logs for troubleshooting and support. Everyday use never needs them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                SupportBundleButton()
            }

            Section {
                ForEach(componentUpdates.components) { component in
                    LabeledContent(component.name) {
                        HStack(spacing: 6) {
                            Text(component.pinned)
                            if component.hasUpdate, let latest = component.latest {
                                Text("· \(latest) available")
                                    .foregroundStyle(.orange)
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
        }
        .formStyle(.grouped)
        .frame(width: 520)
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
            Text("Contains app and tool versions, team-sync status and the activity log. Secrets, tenant records and tenant state are never included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func createBundle() {
        do {
            let staging = FileManager.default.temporaryDirectory
                .appending(path: "jd-support-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let versions = """
            Jamf Deployer \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            OpenTofu \(EngineInfo.openTofuVersion)
            jamfplatform provider \(EngineInfo.jamfPlatformProviderVersion)
            jamfprotect provider \(EngineInfo.jamfProtectProviderVersion)
            jamfpro provider \(EngineInfo.jamfProProviderVersion)
            jamformer \(EngineInfo.jamformerVersion)
            terraform-backend-git \(EngineInfo.stateBackendVersion)
            Team mode: \(deployService.isTeamMode ? "on" : "off")
            Last sync: \(deployService.lastSync?.formatted(.iso8601) ?? "-")
            Sync message: \(deployService.syncMessage ?? "-")
            """
            try Data(versions.utf8).write(to: staging.appending(path: "versions.txt"))

            let log = activityLog.entries.map {
                "\($0.date.formatted(.iso8601)) [\($0.category)] \($0.operation) \($0.detail) \($0.status.map(String.init) ?? "-") \($0.note ?? "")"
            }.joined(separator: "\n")
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
            try? FileManager.default.removeItem(at: staging)
            message = ditto.terminationStatus == 0
                ? "Saved \(destination.lastPathComponent)."
                : "The support bundle could not be written."
        } catch {
            message = error.localizedDescription
        }
    }
}
