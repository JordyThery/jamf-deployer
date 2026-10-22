import SwiftUI

/// What an app concept is called in Terraform, shown under a section's title
/// while Settings → Show technical details is on: the vocabulary of
/// Graduating to Terraform, stage 0, where the concept is used.
struct TerraformTerm: View {
    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if showsTechnicalDetails {
            Text("Terraform: \(text)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A section title with its Terraform term underneath (when shown).
struct TermLabel: View {
    let title: String
    let term: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            TerraformTerm(term)
        }
    }
}
