import Foundation

/// Third-party software the app bundles or downloads, credited in About and in
/// THIRD-PARTY-NOTICES.md with the same words. The licence texts are kept in
/// `Licences/` exactly as each project publishes them.
public nonisolated struct ThirdPartyComponent: Sendable, Hashable, Identifiable {
    public nonisolated struct Link: Sendable, Hashable {
        public var title: String
        public var address: String
    }

    public var name: String
    public var author: String?
    /// What the app uses it for.
    public var summary: String
    public var links: [Link]
    /// The licence's name as shown in About, e.g. "Mozilla Public License 2.0".
    public var licenceName: String?
    /// The text's file in `Licences/`, without ".txt". Nil when nothing is bundled.
    public var licenceFile: String?

    public var id: String { name }

    /// "OpenTofu by the OpenTofu Authors".
    public var heading: String {
        author.map { "\(name) by \($0)" } ?? name
    }

    /// The licence file as published, byte for byte.
    public var licenceFileText: String? {
        guard let licenceFile,
              let url = Bundle.module.url(forResource: licenceFile, withExtension: "txt", subdirectory: "Licences")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The licence text for display: the file without its closing line break.
    public var licence: String? {
        licenceFileText.map { text in
            var text = text
            while text.hasSuffix("\n") { text.removeLast() }
            return text
        }
    }
}

nonisolated extension ThirdPartyComponent {
    private static let mpl = "Mozilla Public License 2.0"

    /// Everything credited, in the order About shows it.
    public static let all: [ThirdPartyComponent] = [
        ThirdPartyComponent(
            name: "OpenTofu",
            author: "the OpenTofu Authors",
            summary: "The deployment engine. It previews and deploys every change. Bundled with the app.",
            links: [
                Link(title: "opentofu.org", address: "https://opentofu.org"),
                Link(title: "github.com/opentofu/opentofu", address: "https://github.com/opentofu/opentofu"),
            ],
            licenceName: mpl,
            licenceFile: "opentofu"
        ),
        ThirdPartyComponent(
            name: "jamfplatform provider",
            author: "Jamf",
            summary: "Lets the engine manage Jamf Platform resources. Bundled with the app.",
            links: [Link(title: "github.com/jamf/terraform-provider-jamfplatform", address: "https://github.com/jamf/terraform-provider-jamfplatform")],
            licenceName: mpl,
            licenceFile: "jamfplatform-provider"
        ),
        ThirdPartyComponent(
            name: "jamfprotect provider",
            author: "Jamf Concepts",
            summary: "Lets the engine manage Jamf Protect resources. Bundled with the app.",
            links: [Link(title: "github.com/Jamf-Concepts/terraform-provider-jamfprotect", address: "https://github.com/Jamf-Concepts/terraform-provider-jamfprotect")],
            licenceName: mpl,
            licenceFile: "jamfprotect-provider"
        ),
        ThirdPartyComponent(
            name: "jamfpro provider",
            author: "Deployment Theory",
            summary: "Lets the engine manage Jamf Pro resources. Bundled with the app.",
            links: [Link(title: "github.com/deploymenttheory/terraform-provider-jamfpro", address: "https://github.com/deploymenttheory/terraform-provider-jamfpro")],
            licenceName: mpl,
            licenceFile: "jamfpro-provider"
        ),
        ThirdPartyComponent(
            name: "terraform-backend-git",
            author: "plumber-cd",
            summary: "In Team Mode, stores and locks each tenant's deployment state in the team space's Git repository. Bundled with the app.",
            links: [Link(title: "github.com/plumber-cd/terraform-backend-git", address: "https://github.com/plumber-cd/terraform-backend-git")],
            licenceName: "Apache License 2.0",
            licenceFile: "terraform-backend-git"
        ),
        ThirdPartyComponent(
            name: "jamformer",
            author: "Jamf Concepts",
            summary: "Exports a tenant's existing configuration. Bundled with the app.",
            links: [Link(title: "github.com/Jamf-Concepts/jamformer", address: "https://github.com/Jamf-Concepts/jamformer")],
            licenceName: "MIT License",
            licenceFile: "jamformer"
        ),
        ThirdPartyComponent(
            name: "HCL",
            author: "HashiCorp",
            summary: "Compiled into jamformer, which writes configuration with its hclwrite package.",
            links: [Link(title: "github.com/hashicorp/hcl", address: "https://github.com/hashicorp/hcl")],
            licenceName: mpl,
            licenceFile: "hcl"
        ),
        ThirdPartyComponent(
            name: "terraform-exec",
            author: "HashiCorp",
            summary: "Compiled into jamformer, which runs Terraform with its tfexec package.",
            links: [Link(title: "github.com/hashicorp/terraform-exec", address: "https://github.com/hashicorp/terraform-exec")],
            licenceName: mpl,
            licenceFile: "terraform-exec"
        ),
        ThirdPartyComponent(
            name: "go-api-sdk-jamfpro",
            author: "Deployment Theory",
            summary: "Compiled into jamformer, which reads Jamf Pro with it.",
            links: [Link(title: "github.com/deploymenttheory/go-api-sdk-jamfpro", address: "https://github.com/deploymenttheory/go-api-sdk-jamfpro")],
            licenceName: mpl,
            licenceFile: "go-api-sdk-jamfpro"
        ),
        ThirdPartyComponent(
            name: "Go",
            author: "the Go Authors",
            summary: "The Go runtime and standard library are compiled into OpenTofu, the providers, terraform-backend-git and jamformer.",
            links: [
                Link(title: "go.dev", address: "https://go.dev"),
                Link(title: "github.com/golang/go", address: "https://github.com/golang/go"),
            ],
            licenceName: "BSD 3-Clause License",
            licenceFile: "go"
        ),
        ThirdPartyComponent(
            name: "HashiCorp Terraform",
            summary: "Optional, for capturing blocks and adopting existing configuration. It is downloaded from HashiCorp only after you agree, kept outside the app and never bundled. Licensed under the Business Source License 1.1.",
            links: [Link(title: "developer.hashicorp.com/terraform", address: "https://developer.hashicorp.com/terraform")]
        ),
    ]
}
