import Foundation
import JTKit
import JamfDeployerCore

/// What the About window shows (JTKit's `AboutWindow`).
extension AboutConfiguration {
    static let jamfDeployer = AboutConfiguration(
        appName: "Jamf Deployer",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Spins up, exports and maintains Jamf tenants from versioned configuration.",
        links: [
            AboutLink("github.com/JordyThery/jamf-deployer", address: "https://github.com/JordyThery/jamf-deployer"),
        ].compactMap { $0 },
        acknowledgements: ThirdPartyComponent.all.map(Acknowledgement.init),
        disclaimer: "An independent project, not affiliated with or endorsed by Jamf."
    )
}

extension Acknowledgement {
    /// The credit as written in THIRD-PARTY-NOTICES.md; JamfDeployerCore's
    /// tests keep the two the same.
    nonisolated init(_ component: ThirdPartyComponent) {
        self.init(
            name: component.name,
            author: component.author,
            summary: component.summary,
            links: component.links.compactMap { AboutLink($0.title, address: $0.address) },
            licence: component.licence,
            licenceName: component.licenceName
        )
    }
}
