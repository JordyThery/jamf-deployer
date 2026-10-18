import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Rolls a change out to several tenants, ring by ring. Every tenant still
/// gets its own preview and its own Deploy click; the rollout only orders
/// them, stages catalog releases, and stops when something goes wrong.
struct RolloutView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(CatalogSourceStore.self) private var catalogSources
    @Environment(\.dismiss) private var dismiss

    enum Change: Hashable {
        /// Whatever each tenant's baseline already contains.
        case currentBaselines
        /// The latest release of one Git catalog source.
        case catalogRelease(UUID)
    }

    struct Entry: Identifiable {
        var id: UUID
        var include: Bool
        var ring: Int
    }

    enum Outcome {
        case deployed(succeeded: Int)
        case failed(String)
        case noChanges
        case skipped
        /// Previewed, then the rollout was stopped here.
        case notDeployed
    }

    enum Stage: Equatable {
        case setup
        case running(Int)
        case deciding(Int)
        case ringPause(next: Int)
        case finished
    }

    @State private var change: Change = .currentBaselines
    @State private var entries: [Entry] = []
    @State private var pauseBetweenRings = true
    @State private var stage: Stage = .setup
    @State private var outcomes: [UUID: Outcome] = [:]
    /// The tenant whose preview is ready to show (after staging a release).
    @State private var readyIndex: Int?
    @State private var prepareError: String?
    /// Baseline before a staged release, restored when it is not deployed.
    @State private var stagedBaseline: (tenantID: UUID, selections: [BlockSelection], pins: [String: String])?

    private var gitSources: [CatalogSourceStore.CustomSource] {
        catalogSources.customSources.filter { $0.kind == .gitRepository }
    }

    /// Included tenants in rollout order: ring, then name.
    private var queue: [Entry] {
        entries.filter(\.include).sorted { lhs, rhs in
            if lhs.ring != rhs.ring { return lhs.ring < rhs.ring }
            return name(lhs.id).localizedStandardCompare(name(rhs.id)) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            switch stage {
            case .running(let index) where readyIndex == index:
                let entry = queue[index]
                PreviewDeploySheet(
                    tenantID: entry.id,
                    context: "Ring \(entry.ring) · \(index + 1) of \(queue.count)",
                    onClose: { reason in finish(index, reason) }
                )
                .id(entry.id)
            default:
                frame
            }
        }
        .onAppear(perform: prepareEntries)
    }

    // MARK: Frame (everything but the per-tenant preview)

    private var frame: some View {
        SheetFrame(title: "Roll Out", systemImage: "square.stack.3d.forward.dottedline", isBusy: isPreparing) {
            switch stage {
            case .setup: setup
            case .running: preparing
            case .deciding(let index): deciding(index)
            case .ringPause(let next): ringPause(next)
            case .finished: summary
            }
        } footer: {
            footer
        }
        .frame(width: 640, height: 540)
    }

    private var isPreparing: Bool {
        if case .running = stage, prepareError == nil { return true }
        return false
    }

    private var setup: some View {
        Form {
            Section("What to roll out") {
                Picker("Change", selection: $change) {
                    Text("Each tenant's current baseline").tag(Change.currentBaselines)
                    ForEach(gitSources) { source in
                        Text("The latest release of \(source.name)").tag(Change.catalogRelease(source.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(change == .currentBaselines
                    ? "Deploys what each tenant's baseline already contains — edit baselines first, then roll the changes out."
                    : "Moves each tenant's blocks from this catalog to its latest release, one tenant at a time. A tenant you skip keeps its current release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach($entries) { $entry in
                    HStack {
                        Toggle(isOn: $entry.include) {
                            HStack(spacing: 6) {
                                Text(name(entry.id))
                                if let tenant = tenantStore.tenant(id: entry.id) {
                                    StatusBadge(tenant.isProduction ? "Production" : "Test",
                                                style: tenant.isProduction ? .tinted : .neutral)
                                }
                            }
                        }
                        Spacer()
                        Picker("Ring", selection: $entry.ring) {
                            ForEach(1...3, id: \.self) { Text("Ring \($0)").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!entry.include)
                    }
                }
                Toggle("Pause before each new ring", isOn: $pauseBetweenRings)
            } header: {
                Text("Tenants")
            } footer: {
                Text("Ring 1 goes first — start with test tenants. Every tenant still shows its preview and waits for you to deploy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var preparing: some View {
        VStack(spacing: 12) {
            if let prepareError {
                ContentUnavailableView(
                    "Couldn't Stage the Release",
                    systemImage: "exclamationmark.triangle",
                    description: Text(prepareError)
                )
            } else {
                ProgressView("Staging the catalog release…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deciding(_ index: Int) -> some View {
        ContentUnavailableView(
            "\(name(queue[index].id)) Was Not Deployed",
            systemImage: "pause.circle",
            description: Text("Skip it and continue with the next tenant, or stop the rollout here.")
        )
    }

    private func ringPause(_ next: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ring \(queue[next - 1].ring) is done.", systemImage: "checkmark.circle")
                .font(.title3.bold())
            outcomeList
            Text("Check the tenants above, then continue with ring \(queue[next].ring).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rollout finished")
                .font(.title3.bold())
            outcomeList
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var outcomeList: some View {
        List(queue) { entry in
            HStack {
                Text(name(entry.id))
                Text("Ring \(entry.ring)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                outcomeLabel(outcomes[entry.id])
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func outcomeLabel(_ outcome: Outcome?) -> some View {
        switch outcome {
        case .deployed(let succeeded):
            Label("Deployed (\(succeeded))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label("Deployed with problems", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .noChanges:
            Label("Nothing to deploy", systemImage: "equal.circle").foregroundStyle(.secondary)
        case .skipped:
            Label("Skipped", systemImage: "forward.circle").foregroundStyle(.secondary)
        case .notDeployed:
            Label("Not deployed", systemImage: "stop.circle").foregroundStyle(.secondary)
        case nil:
            Label("Not reached", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch stage {
        case .setup:
            Text("\(queue.count) tenant\(queue.count == 1 ? "" : "s") in \(Set(queue.map(\.ring)).count) ring\(Set(queue.map(\.ring)).count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Start Rollout") { start(0) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(queue.isEmpty || deployService.isBusy)
        case .running:
            Spacer()
            if prepareError != nil {
                Button("Stop Rollout") { stage = .finished }
            }
        case .deciding(let index):
            Spacer()
            Button("Stop Rollout") {
                outcomes[queue[index].id] = .notDeployed
                stage = .finished
            }
            Button("Skip and Continue") {
                outcomes[queue[index].id] = .skipped
                advance(from: index)
            }
            .buttonStyle(.borderedProminent)
        case .ringPause(let next):
            Spacer()
            Button("Stop Rollout") { stage = .finished }
            Button("Continue with Ring \(queue[next].ring)") { start(next) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .finished:
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Flow

    private func prepareEntries() {
        guard entries.isEmpty else { return }
        entries = tenantStore.tenants
            .filter(deployService.canRollOut)
            .map { Entry(id: $0.id, include: true, ring: $0.isProduction ? 2 : 1) }
    }

    private func start(_ index: Int) {
        stage = .running(index)
        readyIndex = nil
        prepareError = nil
        Task { await prepare(index) }
    }

    /// Stages a catalog release on the tenant before its preview; a tenant
    /// already on the latest release has nothing to deploy.
    private func prepare(_ index: Int) async {
        let entry = queue[index]
        guard case .catalogRelease(let sourceID) = change else {
            readyIndex = index
            return
        }
        guard let tenant = tenantStore.tenant(id: entry.id) else { return }
        do {
            let available = try await deployService.availableBaselineUpdates(for: tenant)
            guard let release = available.first(where: { $0.source.id == sourceID }) else {
                outcomes[entry.id] = .noChanges
                advance(from: index)
                return
            }
            stagedBaseline = (tenant.id, tenant.blockSelections, tenant.catalogPins)
            deployService.applyBaselineUpdate(
                tenant: tenant, source: release.source, tag: release.tag,
                blockIDs: Set(release.updates.map(\.blockID)))
            readyIndex = index
        } catch {
            prepareError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finish(_ index: Int, _ reason: PreviewDeploySheet.CloseReason) {
        let id = queue[index].id
        switch reason {
        case .deployed(let outcome):
            stagedBaseline = nil
            if outcome.failed == 0 {
                outcomes[id] = .deployed(succeeded: outcome.succeeded)
                advance(from: index)
            } else {
                outcomes[id] = .failed(outcome.errors.first ?? "")
                stage = .finished
            }
        case .nothingToDeploy:
            // Already matches the release: keep the new pin.
            stagedBaseline = nil
            outcomes[id] = .noChanges
            advance(from: index)
        case .closedWithoutDeploying:
            restoreStagedBaseline()
            stage = .deciding(index)
        }
    }

    private func advance(from index: Int) {
        let next = index + 1
        guard next < queue.count else {
            stage = .finished
            return
        }
        if pauseBetweenRings && queue[next].ring != queue[index].ring {
            stage = .ringPause(next: next)
        } else {
            start(next)
        }
    }

    private func restoreStagedBaseline() {
        guard let staged = stagedBaseline, var tenant = tenantStore.tenant(id: staged.tenantID) else { return }
        tenant.blockSelections = staged.selections
        tenant.catalogPins = staged.pins
        tenantStore.update(tenant)
        stagedBaseline = nil
    }

    private func name(_ id: UUID) -> String {
        tenantStore.tenant(id: id)?.name ?? "Tenant"
    }
}
