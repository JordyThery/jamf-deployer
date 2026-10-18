import SwiftUI
import UniformTypeIdentifiers
import DeployerKit

/// The tenant's Day 0 groundwork: APNs, Apple Business Manager connections,
/// branding, SSO, Protect. Every step detects its own status, can be
/// skipped, and can be re-run any time.
struct Day0SetupView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(ActivityLog.self) private var activityLog

    let tenant: Tenant

    @State private var service: Day0Service?
    @State private var actionError: String?

    // APNs
    @State private var apnsDate: Date = .now
    // ADE
    @State private var isExportingPublicKey = false
    @State private var publicKey: Data?
    @State private var isImportingADEToken = false
    // VPP
    @State private var isImportingVPPToken = false
    // Branding
    @State private var brandingName = ""
    // Protect
    @State private var protectURL = ""
    @State private var protectClientID = ""
    @State private var protectSecret = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Groundwork every tenant needs once. Steps that talk to Apple renew yearly, so they live here instead of in building blocks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again", systemImage: "arrow.clockwise") {
                    detect()
                }
                .disabled(service?.isDetecting ?? false)
            }

            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.callout)
            }

            if let service, !service.steps.isEmpty {
                ForEach(service.steps) { step in
                    stepBox(step, service: service)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking the tenant…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: tenant.id) {
            detect()
        }
        .fileExporter(
            isPresented: $isExportingPublicKey,
            document: publicKey.map { PEMDocument(data: $0) },
            contentType: .data,
            defaultFilename: "jamf-ade-public-key.pem"
        ) { _ in }
        .fileImporter(isPresented: $isImportingADEToken, allowedContentTypes: [.data]) { result in
            handleADEImport(result)
        }
        .fileImporter(isPresented: $isImportingVPPToken, allowedContentTypes: [.data]) { result in
            handleVPPImport(result)
        }
    }

    // MARK: Step rendering

    @ViewBuilder
    private func stepBox(_ step: Day0Step, service: Day0Service) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    indicator(for: step.state).icon
                    Text(detailText(step.state))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if case .pending = step.state {
                    actions(for: step, service: service)
                } else if case .skipped = step.state {
                    Button("Undo Skip") { setSkipped(step.id, false) }
                        .controlSize(.small)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(step.title)
                Spacer()
                if case .pending = step.state {
                    Button("Skip for Now") { setSkipped(step.id, true) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for step: Day0Step, service: Day0Service) -> some View {
        switch step.id {
        case "apns":
            HStack(spacing: 10) {
                if let url = service.jamfProURL {
                    Link("Open Jamf Pro", destination: url)
                }
                DatePicker("Completed on", selection: $apnsDate, displayedComponents: .date)
                    .frame(maxWidth: 220)
                Button("Mark as Done") {
                    var updated = tenantStore.tenant(id: tenant.id) ?? tenant
                    updated.day0.apnsConfirmedDate = apnsDate
                    tenantStore.update(updated)
                    detect()
                }
            }
            .controlSize(.small)

        case "ade":
            HStack(spacing: 10) {
                Button("Download Public Key…", systemImage: "key") {
                    downloadPublicKey()
                }
                Link("Open Apple Business Manager", destination: URL(string: "https://business.apple.com")!)
                Button("Upload Server Token (.p7m)…", systemImage: "square.and.arrow.up") {
                    isImportingADEToken = true
                }
            }
            .controlSize(.small)
            .disabled(isWorking)

        case "vpp":
            HStack(spacing: 10) {
                Link("Open Apple Business Manager", destination: URL(string: "https://business.apple.com")!)
                Button("Upload Location Token (.vpptoken)…", systemImage: "square.and.arrow.up") {
                    isImportingVPPToken = true
                }
            }
            .controlSize(.small)
            .disabled(isWorking)

        case "branding":
            HStack(spacing: 10) {
                TextField("Organization name", text: $brandingName, prompt: Text("Shown in Self Service"))
                    .frame(maxWidth: 260)
                Button("Create Branding") {
                    createBranding()
                }
                .disabled(brandingName.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
            .controlSize(.small)

        case "protect":
            VStack(alignment: .leading, spacing: 6) {
                TextField("Protect console URL", text: $protectURL, prompt: Text("https://yourorg.protect.jamfcloud.com"))
                HStack {
                    TextField("API client ID", text: $protectClientID)
                        .font(.callout.monospaced())
                    SecureField("API client secret", text: $protectSecret)
                }
                Button("Link Jamf Protect") {
                    registerProtect()
                }
                .disabled(protectURL.isEmpty || protectClientID.isEmpty || protectSecret.isEmpty || isWorking)
            }
            .frame(maxWidth: 480)
            .controlSize(.small)

        case "csc":
            if let url = service.jamfProURL {
                Link("Open Jamf Pro", destination: url)
                    .font(.callout)
            }

        default:
            EmptyView()
        }
    }

    private func indicator(for state: Day0Step.State) -> StatusIndicator {
        switch state {
        case .done: .success
        case .pending: .warning
        case .info, .skipped: .neutral
        case .unknown: .neutral
        }
    }

    private func detailText(_ state: Day0Step.State) -> String {
        switch state {
        case .done(let detail), .pending(let detail), .info(let detail), .unknown(let detail):
            detail
        case .skipped:
            "Skipped — come back any time."
        }
    }

    // MARK: Actions

    private func detect() {
        let service = service ?? Day0Service(activityLog: activityLog)
        self.service = service
        if protectURL.isEmpty, let saved = tenant.protectURL {
            protectURL = saved
            protectClientID = tenant.protectClientID ?? ""
            protectSecret = TenantSecrets(tenantID: tenant.id).protectClientSecret.load() ?? ""
        }
        Task {
            await service.detect(tenant: tenantStore.tenant(id: tenant.id) ?? tenant)
        }
    }

    private func setSkipped(_ stepID: String, _ skipped: Bool) {
        var updated = tenantStore.tenant(id: tenant.id) ?? tenant
        if skipped {
            if !updated.day0.skippedSteps.contains(stepID) {
                updated.day0.skippedSteps.append(stepID)
            }
        } else {
            updated.day0.skippedSteps.removeAll { $0 == stepID }
        }
        tenantStore.update(updated)
        detect()
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        isWorking = true
        actionError = nil
        Task {
            defer { isWorking = false }
            do {
                try await work()
                detect()
            } catch {
                actionError = "\(label): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func downloadPublicKey() {
        guard let service else { return }
        run("Public key") {
            publicKey = try await service.downloadADEPublicKey(tenant: tenant)
            isExportingPublicKey = true
        }
    }

    private func handleADEImport(_ result: Result<URL, any Error>) {
        guard let service, case .success(let url) = result else { return }
        run("Server token") {
            let gained = url.startAccessingSecurityScopedResource()
            defer { if gained { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try await service.uploadADEToken(tenant: tenant, tokenFile: data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func handleVPPImport(_ result: Result<URL, any Error>) {
        guard let service, case .success(let url) = result else { return }
        run("Location token") {
            let gained = url.startAccessingSecurityScopedResource()
            defer { if gained { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try await service.uploadVPPToken(tenant: tenant, tokenFile: data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func createBranding() {
        guard let service else { return }
        let name = brandingName.trimmingCharacters(in: .whitespaces)
        run("Branding") {
            try await service.createBranding(tenant: tenant, brandingName: name)
        }
    }

    private func registerProtect() {
        guard let service else { return }
        run("Jamf Protect") {
            try await service.registerProtect(
                tenant: tenant,
                protectURL: protectURL,
                clientID: protectClientID,
                password: protectSecret
            )
            // Re-read after the network call so newer changes are kept.
            var updated = tenantStore.tenant(id: tenant.id) ?? tenant
            updated.protectURL = protectURL
            updated.protectClientID = protectClientID
            tenantStore.update(updated)
            guard TenantSecrets(tenantID: tenant.id).protectClientSecret.save(protectSecret) else {
                throw Day0Error.keychainSaveFailed
            }
        }
    }
}

/// A downloaded PEM held for export.
nonisolated struct PEMDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

nonisolated enum Day0Error: LocalizedError {
    case keychainSaveFailed

    var errorDescription: String? {
        switch self {
        case .keychainSaveFailed:
            "Jamf Protect is linked, but its client secret could not be saved to the Keychain. Enter it again in Day 0 Setup."
        }
    }
}
