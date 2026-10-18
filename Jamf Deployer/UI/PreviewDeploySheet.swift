import SwiftUI
import UniformTypeIdentifiers
import DeployerKit
import JamfDeployerCore

/// Preview changes → confirm → Deploy with live progress → results.
/// Nothing is written to the tenant except the exact saved plan shown here.
struct PreviewDeploySheet: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(\.dismiss) private var dismiss

    let tenantID: UUID
    /// Shown under the title, e.g. the rollout position.
    var context: String? = nil
    /// Set when embedded (in a rollout): called instead of dismissing.
    var onClose: ((CloseReason) -> Void)? = nil

    enum CloseReason {
        case deployed(TenantDeployService.DeployOutcome)
        /// The preview found nothing to change.
        case nothingToDeploy
        /// Closed before deploying, or the preview failed.
        case closedWithoutDeploying
        /// The deploy itself failed; the tenant may be partly changed.
        case deployFailed(String)
    }

    enum Stage {
        case previewing
        case reviewing(PreviewSession)
        case needsRecovery(PreviewSession)
        case confirmingProduction(PreviewSession)
        case deploying(PreviewSession)
        case finished(TenantDeployService.DeployOutcome)
        case failed(String, detail: String)
        case deployFailed(String, detail: String)
    }

    @State private var stage: Stage = .previewing
    @State private var typedName = ""
    @State private var isExportingRecovery = false
    /// Built when the user saves the sheet, never during rendering.
    @State private var recoveryText = ""
    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false

    private var tenant: Tenant? {
        tenantStore.tenant(id: tenantID)
    }

    var body: some View {
        SheetFrame(
            title: "Preview Changes — \(tenant?.name ?? "")\(context.map { " · \($0)" } ?? "")",
            systemImage: "list.bullet.clipboard",
            isBusy: isBusy
        ) {
            content
        } footer: {
            footer
        }
        .frame(width: 700, height: 580)
        .task {
            await runPreview()
        }
        .onDisappear {
            // A preview holds the tenant's team lock; closing without
            // deploying releases it.
            if case .finished = stage {} else if let tenant {
                deployService.abandonPreview(tenant: tenant)
            }
        }
        .fileExporter(
            isPresented: $isExportingRecovery,
            document: TextExportDocument(text: recoveryText),
            contentType: .plainText,
            defaultFilename: "Jamf Deployer Recovery — \(tenant?.name ?? "tenant").txt"
        ) { result in
            if case .success = result, let tenant {
                deployService.markRecoverySaved(for: tenant)
                if case .needsRecovery(let session) = stage {
                    stage = .reviewing(session)
                }
            }
        }
    }

    private var isDeployFailure: Bool {
        if case .deployFailed = stage { return true }
        return false
    }

    private var isBusy: Bool {
        switch stage {
        case .previewing, .deploying: true
        default: false
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .previewing:
            VStack(spacing: 12) {
                ProgressView(progressText)
                Text("Nothing is changed during a preview.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .reviewing(let session), .confirmingProduction(let session), .needsRecovery(let session):
            previewList(session)

        case .deploying(let session):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(deployService.progress.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "checkmark.circle")
                        .font(.callout.monospaced())
                }
                let total = session.summary.counts.filter { $0.key != .unchanged }.values.reduce(0, +)
                ProgressView(value: Double(deployService.progress.count), total: Double(max(total, 1)))
                    .padding(.top, 4)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .finished(let outcome):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    (outcome.failed == 0 ? StatusIndicator.success : .warning).icon
                        .font(.system(size: 28))
                    VStack(alignment: .leading) {
                        Text(outcome.failed == 0 ? "Deployed" : "Deployed with problems")
                            .font(.title3.bold())
                        Text("\(outcome.succeeded) succeeded · \(outcome.failed) failed")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if outcome.recovered > 0 {
                    Label(
                        "Jamf reported an error for \(outcome.recovered) object\(outcome.recovered == 1 ? "" : "s") but created \(outcome.recovered == 1 ? "it" : "them") anyway. Preview Changes again: the preview adopts \(outcome.recovered == 1 ? "it" : "them") instead of creating duplicates.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(outcome.errors.enumerated()), id: \.offset) { _, raw in
                            let translated = ErrorTranslation.translate(raw)
                            VStack(alignment: .leading, spacing: 4) {
                                Label(translated.message, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                if let hint = translated.hint {
                                    Text(hint)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                if showsTechnicalDetails {
                                    DisclosureGroup("Show details") {
                                        Text(raw)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    .font(.caption)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Text("The result is recorded in History, and the tenant record was backed up automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .failed(let message, let detail), .deployFailed(let message, let detail):
            VStack(alignment: .leading, spacing: 10) {
                ContentUnavailableView(
                    isDeployFailure ? "Deploy Failed" : "Preview Failed",
                    systemImage: "xmark.octagon",
                    description: Text(isDeployFailure
                        ? "\(message)\nSome changes may have been applied. Check History, then run a new preview."
                        : message)
                )
                if showsTechnicalDetails, !detail.isEmpty {
                    ScrollView {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            .padding()
        }
    }

    private var progressText: String {
        switch deployService.phase {
        case .generating: "Assembling the configuration…"
        case .initializing: "Preparing the deployment engine…"
        case .planning: "Asking Jamf what would change…"
        default: "Working…"
        }
    }

    @ViewBuilder
    private func previewList(_ session: PreviewSession) -> some View {
        List {
            if session.summary.isEmpty {
                ContentUnavailableView(
                    "Nothing to Change",
                    systemImage: "checkmark.circle",
                    description: Text("The tenant already matches the selected baseline.")
                )
            }
            ForEach(session.summary.groups) { group in
                Section(group.blockName) {
                    ForEach(group.changes) { change in
                        changeRow(change)
                    }
                }
            }
            if !session.summary.generalNotes.isEmpty {
                Section("Notes") {
                    ForEach(session.summary.generalNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func changeRow(_ change: ObjectChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusBadge(change.kind.rawValue, style: badgeStyle(change.kind))
                Text(change.displayName)
                    .font(.body.weight(.medium))
                Spacer()
                if showsTechnicalDetails {
                    Text(change.resourceType)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(change.notes, id: \.self) { note in
                Label(note, systemImage: "person.3")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !change.fieldDiffs.isEmpty {
                DisclosureGroup("\(change.fieldDiffs.count) field change\(change.fieldDiffs.count == 1 ? "" : "s")") {
                    ForEach(change.fieldDiffs) { diff in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(diff.path)
                                .font(.caption.bold().monospaced())
                            Text("− \(diff.before)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                            Text("+ \(diff.after)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func badgeStyle(_ kind: ChangeKind) -> StatusBadge.Style {
        switch kind {
        case .create, .adopt: .tinted
        case .remove, .replace: .warning
        default: .neutral
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch stage {
        case .reviewing(let session):
            summaryText(session)
            Spacer()
            Button("Close") { close(session.summary.isEmpty ? .nothingToDeploy : .closedWithoutDeploying) }
                .keyboardShortcut(.cancelAction)
            Button("Deploy") { startDeploy(session) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.summary.isEmpty)
                .help(session.summary.isEmpty ? "There is nothing to deploy" : "Write these changes to the tenant")

        case .needsRecovery:
            Label("First deploy: save this tenant's recovery sheet before deploying.", systemImage: "key")
                .font(.callout)
            Spacer()
            Button("Close") { close(.closedWithoutDeploying) }
                .keyboardShortcut(.cancelAction)
            Button("Save Recovery Sheet…") {
                recoveryText = tenant.map { deployService.recoverySheetText(for: $0) } ?? ""
                isExportingRecovery = true
            }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

        case .confirmingProduction(let session):
            VStack(alignment: .leading, spacing: 2) {
                Text("This removes or replaces objects on a production tenant.")
                    .font(.callout)
                TextField("Type the tenant name to confirm", text: $typedName)
                    .frame(width: 260)
            }
            Spacer()
            Button("Back") {
                stage = .reviewing(session)
                typedName = ""
            }
            Button("Deploy") { confirmDeploy(session) }
                .buttonStyle(.borderedProminent)
                .disabled(typedName != tenant?.name)

        case .deploying:
            Text("Deploying… large baselines can take a few minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()

        case .finished(let outcome):
            Spacer()
            Button(onClose == nil ? "Done" : "Continue") { close(.deployed(outcome)) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

        case .deployFailed(let message, _):
            Spacer()
            Button("Close") { close(.deployFailed(message)) }
                .keyboardShortcut(.defaultAction)

        case .failed:
            Spacer()
            Button("Close") { close(.closedWithoutDeploying) }
                .keyboardShortcut(.cancelAction)
            Button("Try Again") {
                stage = .previewing
                Task { await runPreview() }
            }
            .buttonStyle(.borderedProminent)

        case .previewing:
            Spacer()
            Button("Cancel") {
                if let tenant {
                    deployService.cancel(tenant: tenant)
                }
                close(.closedWithoutDeploying)
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func summaryText(_ session: PreviewSession) -> some View {
        let counts = session.summary.counts
        Text(
            [
                counts[.create].map { "\($0) create" },
                counts[.update].map { "\($0) update" },
                counts[.replace].map { "\($0) replace" },
                counts[.remove].map { "\($0) remove" },
                counts[.adopt].map { "\($0) adopt" },
                counts[.stopManaging].map { "\($0) stop managing" },
            ].compactMap(\.self).joined(separator: " · ")
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func close(_ reason: CloseReason) {
        // Leaving the view releases an unused preview (onDisappear).
        if let onClose {
            onClose(reason)
        } else {
            dismiss()
        }
    }

    private func runPreview() async {
        guard let tenant else { return }
        stage = .previewing
        do {
            let session = try await deployService.preview(tenant: tenant)
            if deployService.needsRecoveryEscrow(for: tenant) {
                stage = .needsRecovery(session)
            } else {
                stage = .reviewing(session)
            }
        } catch {
            let raw = String(describing: error)
            // App-level errors describe themselves; the translation table is
            // for raw engine and provider output.
            if let described = (error as? LocalizedError)?.errorDescription {
                stage = .failed(described, detail: raw)
            } else {
                let translated = ErrorTranslation.translate(raw)
                stage = .failed(translated.message + (translated.hint.map { "\n\($0)" } ?? ""), detail: raw)
            }
        }
    }

    private func startDeploy(_ session: PreviewSession) {
        guard let tenant else { return }
        if tenant.isProduction && session.summary.hasDestructiveChanges {
            stage = .confirmingProduction(session)
        } else {
            confirmDeploy(session)
        }
    }

    private func confirmDeploy(_ session: PreviewSession) {
        guard let tenant else { return }
        stage = .deploying(session)
        typedName = ""
        Task {
            do {
                let outcome = try await deployService.deploy(tenant: tenant, session: session)
                stage = .finished(outcome)
            } catch {
                let raw = String(describing: error)
                if let described = (error as? LocalizedError)?.errorDescription {
                    stage = .deployFailed(described, detail: raw)
                } else {
                    let translated = ErrorTranslation.translate(raw)
                    stage = .deployFailed(translated.message + (translated.hint.map { "\n\($0)" } ?? ""), detail: raw)
                }
            }
        }
    }
}
