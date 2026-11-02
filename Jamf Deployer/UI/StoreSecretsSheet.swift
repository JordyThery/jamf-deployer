import SwiftUI
import JTKit
import JamfDeployerCore

/// Possible secrets in the store: a commit they stopped, or the one-time
/// check of a store from before the check. Shows where each one is and the
/// rule that found it, never the value.
struct StoreSecretsSheet: View {
    @Environment(TenantDeployService.self) private var deployService
    @Environment(TenantStore.self) private var tenantStore

    let review: TenantDeployService.StoreSecretReview
    @State private var errorMessage: String?
    @State private var confirmsMarkAll = false

    var body: some View {
        SheetFrame(title: title, systemImage: "exclamationmark.lock") {
            VStack(alignment: .leading, spacing: 10) {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                }
                List(review.findings) { finding in
                    row(finding)
                }
                .listStyle(.inset)
            }
            .padding([.horizontal, .top])
        } footer: {
            footer
        }
        .frame(width: 640, height: 480)
        .interactiveDismissDisabled()
        .confirmationDialog(markAllTitle, isPresented: $confirmsMarkAll) {
            Button("Mark All as Not a Secret") { markAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(StoreSecretsSheet.markAllMessage(isTeamMode: deployService.isTeamMode))
        }
    }

    /// The bulk confirmation's text. In Team Mode, what it unblocks goes to
    /// the team repository with the next sync.
    static func markAllMessage(isTeamMode: Bool) -> String {
        let base = "Only do this when you’ve checked them: they’re no longer asked about. Only their locations and rules are saved, never the values."
        return isTeamMode
            ? base + " The files they’re in are then shared with your team on the next sync."
            : base
    }

    /// Current findings still waiting for a choice; earlier versions and
    /// deploy history never stop saving, so they need none.
    private var markable: [SecretFinding] {
        review.findings.map(\.finding).filter { finding in
            !review.findings.contains { $0.finding == finding && $0.inEarlierVersion }
                && GitStoreService.blocksCommit(finding)
                && !current.acknowledged.contains(finding)
        }
    }

    private var markAllTitle: String {
        markable.count == 1 ? "Mark this finding as not a secret?" : "Mark all \(markable.count) findings as not a secret?"
    }

    private func markAll() {
        let findings = markable
        Task {
            do {
                try await deployService.acknowledgeStoreFindings(findings)
            } catch {
                errorMessage = "The choice couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }

    private var current: TenantDeployService.StoreSecretReview {
        deployService.storeSecretReview ?? review
    }

    private var title: String {
        if case .existingStore = review.kind { return "Possible Secrets in Your Store" }
        return "Possible Secrets — Not Saved"
    }

    private var explanation: String {
        switch review.kind {
        case .existingStore:
            "These places in your store look like secrets. Git keeps every earlier version, so treat them as exposed: change each secret where it’s used, such as the Wi-Fi password or API client secret. Before the store can be saved again, fix each current file or mark it as not a secret. Deploy records never stop saving."
        case .commitBlocked, .commitStopped:
            "Nothing was saved or shared: these places in the store look like secrets. Remove each secret where it comes from (in Jamf, then adopt or capture again), or mark a finding as not a secret if it’s harmless. Only its location and rule are saved, never the value."
        }
    }

    @ViewBuilder
    private func row(_ finding: GitStoreService.StoreFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(location(finding.finding.path))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("Line \(finding.finding.line) · \(finding.finding.rule)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if finding.inEarlierVersion {
                StatusBadge("Earlier version", style: .warning)
                    .help("Only in an earlier version of the store. Git keeps it, so change this secret where it’s used.")
            } else if !GitStoreService.blocksCommit(finding.finding) {
                StatusBadge("Deploy record", style: .info)
                    .help("In this tenant’s deploy history. It doesn’t stop saving, previews or deploys; change the secret where it’s used.")
            } else if current.acknowledged.contains(finding.finding) {
                Label("Not a secret", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.caption)
            } else {
                Button("Not a Secret") {
                    Task {
                        do {
                            try await deployService.acknowledgeStoreFinding(finding.finding)
                        } catch {
                            errorMessage = "The choice couldn’t be saved: \(error.localizedDescription)"
                        }
                    }
                }
                .controlSize(.small)
                .help("Marks this finding as harmless. Only its location and rule are saved.")
            }
        }
    }

    /// "Tenant “Acme” › adopted/support_files/scripts/Bind.zsh" for a
    /// tenant's files; other paths as they are.
    private func location(_ path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "tenants", let id = UUID(uuidString: parts[1]),
              let tenant = tenantStore.tenant(id: id) else { return path }
        return "Tenant “\(tenant.name)” › \(parts[2])"
    }

    @ViewBuilder
    private var footer: some View {
        if markable.count > 1 {
            Button("Mark All as Not a Secret…") { confirmsMarkAll = true }
                .help("Marks every finding still listed as harmless, after you’ve checked them.")
        }
        Spacer()
        switch review.kind {
        case .commitBlocked:
            Button("Not Now") {
                Task { await deployService.closeStoreSecretReview(retry: false) }
            }
            .keyboardShortcut(.cancelAction)
            Button("Try Again") {
                Task { await deployService.closeStoreSecretReview(retry: true) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        case .commitStopped, .existingStore:
            Button("Done") {
                Task { await deployService.closeStoreSecretReview(retry: false) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }
}
