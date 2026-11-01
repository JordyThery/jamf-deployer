import SwiftUI
import UniformTypeIdentifiers
import JTKit

/// The tenant's Day 0 groundwork: APNs, Apple Business connections,
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
    /// A write waiting for its confirmation (production tenants).
    @State private var pendingWrite: Day0Write?

    /// Busy with a step, or checking the tenant again after one: a second
    /// click could create a second branding or location while the first
    /// result is unknown.
    private var isBlocked: Bool {
        isWorking || (service?.isDetecting ?? false)
    }

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
                .disabled(isBlocked)
            }

            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.tintedIcon(.yellow))
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
        .confirmationDialog(
            pendingWrite?.title(tenantName: tenant.name) ?? "",
            isPresented: Binding(get: { pendingWrite != nil }, set: { if !$0 { pendingWrite = nil } }),
            titleVisibility: .visible,
            presenting: pendingWrite
        ) { write in
            Button(write.confirmTitle) { perform(write) }
            Button("Cancel", role: .cancel) {}
        } message: { write in
            Text(write.message)
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
                Link("Open Apple Business", destination: URL(string: "https://business.apple.com")!)
                Button("Upload Server Token (.p7m)…", systemImage: "square.and.arrow.up") {
                    isImportingADEToken = true
                }
            }
            .controlSize(.small)
            .disabled(isBlocked)

        case "vpp":
            HStack(spacing: 10) {
                Link("Open Apple Business", destination: URL(string: "https://business.apple.com")!)
                Button("Upload Location Token (.vpptoken)…", systemImage: "square.and.arrow.up") {
                    isImportingVPPToken = true
                }
            }
            .controlSize(.small)
            .disabled(isBlocked)

        case "branding":
            HStack(spacing: 10) {
                TextField("Organization name", text: $brandingName, prompt: Text("Shown in Self Service"))
                    .frame(maxWidth: 260)
                Button("Create Branding") {
                    request(.branding(brandingName.trimmingCharacters(in: .whitespaces)))
                }
                .disabled(brandingName.trimmingCharacters(in: .whitespaces).isEmpty || isBlocked)
            }
            .controlSize(.small)

        case "protect":
            VStack(alignment: .leading, spacing: 6) {
                TextField("Protect console URL", text: $protectURL, prompt: Text("https://yourorg.protect.jamfcloud.com"))
                    .onAppear {
                        // The stored secret is read only here, where it can
                        // be edited — not on every Day 0 visit.
                        if protectSecret.isEmpty {
                            protectSecret = TenantSecrets(tenantID: tenant.id).protectClientSecret.load() ?? ""
                        }
                    }
                HStack {
                    TextField("API client ID", text: $protectClientID)
                        .font(.callout.monospaced())
                    SecureField("API client secret", text: $protectSecret)
                }
                Button("Link Jamf Protect") {
                    request(.protect(url: protectURL))
                }
                .disabled(protectURL.isEmpty || protectClientID.isEmpty || protectSecret.isEmpty || isBlocked)
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

    /// Runs a step, then checks the tenant again whether it worked or not:
    /// a call that failed (a timeout, say) may still have written to Jamf.
    /// The buttons stay disabled until that check is done.
    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        let service = service ?? Day0Service(activityLog: activityLog)
        self.service = service
        isWorking = true
        actionError = nil
        Task {
            defer { isWorking = false }
            let failure = await ScreenWork.shared.tracking("Day 0: \(label)") {
                await Day0Action.perform(work) {
                    await service.detect(tenant: tenantStore.tenant(id: tenant.id) ?? tenant)
                }
            }
            if let failure {
                actionError = "\(label): \((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)"
            }
        }
    }

    /// Asks first on a production tenant: Day 0 steps write straight away,
    /// without a preview.
    private func request(_ write: Day0Write) {
        if Day0Action.needsConfirmation(isProduction: tenant.isProduction) {
            pendingWrite = write
        } else {
            perform(write)
        }
    }

    private func perform(_ write: Day0Write) {
        pendingWrite = nil
        switch write {
        case .adeToken(let url): uploadADEToken(url)
        case .vppToken(let url): uploadVPPToken(url)
        case .branding(let name): createBranding(name)
        case .protect: registerProtect()
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
        guard case .success(let url) = result else { return }
        request(.adeToken(url))
    }

    private func uploadADEToken(_ url: URL) {
        guard let service else { return }
        run("Server token") {
            let gained = url.startAccessingSecurityScopedResource()
            defer { if gained { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try await service.uploadADEToken(tenant: tenant, tokenFile: data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func handleVPPImport(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        request(.vppToken(url))
    }

    private func uploadVPPToken(_ url: URL) {
        guard let service else { return }
        run("Location token") {
            let gained = url.startAccessingSecurityScopedResource()
            defer { if gained { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try await service.uploadVPPToken(tenant: tenant, tokenFile: data, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func createBranding(_ name: String) {
        guard let service, !name.isEmpty else { return }
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

/// A Day 0 step that writes to the tenant.
enum Day0Write: Equatable {
    case adeToken(URL)
    case vppToken(URL)
    case branding(String)
    case protect(url: String)

    func title(tenantName: String) -> String {
        switch self {
        case .adeToken: "Upload Server Token to “\(tenantName)”?"
        case .vppToken: "Upload Location Token to “\(tenantName)”?"
        case .branding: "Create Branding on “\(tenantName)”?"
        case .protect: "Link Jamf Protect to “\(tenantName)”?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .adeToken: "Upload Server Token"
        case .vppToken: "Upload Location Token"
        case .branding: "Create Branding"
        case .protect: "Link Jamf Protect"
        }
    }

    var message: String {
        let what = switch self {
        case .adeToken: "Jamf Pro adds an Automated Device Enrollment instance for this token."
        case .vppToken: "Jamf Pro adds an Apps and Books location for this token."
        case .branding(let name): "Jamf Pro adds a Self Service branding named “\(name)”."
        case .protect(let url): "Jamf Pro connects to Jamf Protect at \(url)."
        }
        return "\(what) This is a production tenant, and Day 0 steps are written straight away, without a preview."
    }
}

/// How a Day 0 step runs.
enum Day0Action {
    static func needsConfirmation(isProduction: Bool) -> Bool {
        isProduction
    }

    /// Runs `work`, then `detect`, also after a failure. Returns the failure.
    static func perform(_ work: () async throws -> Void, thenDetect detect: () async -> Void) async -> Error? {
        var failure: Error?
        do {
            try await work()
        } catch {
            failure = error
        }
        await detect()
        return failure
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
            "The Keychain refused to save the secret, so Jamf Protect is linked without its client secret. Enter it again in Day 0 Setup."
        }
    }
}
