import SwiftUI

/// The About window: author credit and acknowledgements for the open-source
/// projects the app builds on.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("Jamf Deployer")
                    .font(.title2.bold())
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Created by Jordy Thery")
                .font(.callout)

            Divider()
                .frame(width: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text("Built with")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                acknowledgement(
                    "OpenTofu",
                    detail: "the deployment engine (MPL-2.0)",
                    url: "https://opentofu.org"
                )
                acknowledgement(
                    "jamfplatform provider",
                    detail: "Jamf Platform resources (MPL-2.0)",
                    url: "https://github.com/jamf/terraform-provider-jamfplatform"
                )
                acknowledgement(
                    "jamfprotect provider",
                    detail: "Jamf Protect resources (MPL-2.0)",
                    url: "https://github.com/Jamf-Concepts/terraform-provider-jamfprotect"
                )
                acknowledgement(
                    "jamfpro provider",
                    detail: "Jamf Pro API resources, by Deployment Theory (MPL-2.0)",
                    url: "https://github.com/deploymenttheory/terraform-provider-jamfpro"
                )
                acknowledgement(
                    "jamformer",
                    detail: "tenant export tooling",
                    url: "https://github.com/Jamf-Concepts/jamformer"
                )
                acknowledgement(
                    "terraform-backend-git",
                    detail: "the Team Mode state backend, by plumber-cd (Apache-2.0)",
                    url: "https://github.com/plumber-cd/terraform-backend-git"
                )
                acknowledgement(
                    "HashiCorp Terraform",
                    detail: "optional, downloaded on demand for exports (BUSL-1.1)",
                    url: "https://developer.hashicorp.com/terraform"
                )
            }
            .frame(width: 360, alignment: .leading)

            Text("An independent project, not affiliated with or endorsed by Jamf.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func acknowledgement(_ name: String, detail: String, url: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let link = URL(string: url) {
                Link(name, destination: link)
                    .font(.caption)
            } else {
                Text(name)
                    .font(.caption)
            }
            Text("— \(detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    AboutView()
}
