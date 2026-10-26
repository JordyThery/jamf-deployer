import SwiftUI
import JamfDeployerCore

/// Possible secrets in an export, one line per object and rule. Only where
/// each one is, never the scanned text.
struct SecretObjectsNotice: View {
    let findings: [SecretObjectFinding]
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            ForEach(findings) { finding in
                Text("\(finding.objectDescription) — \(finding.rule)")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
