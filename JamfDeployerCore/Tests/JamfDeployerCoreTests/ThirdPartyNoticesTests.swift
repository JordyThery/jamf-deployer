import Foundation
import Testing
@testable import JamfDeployerCore

/// About is built from `ThirdPartyComponent.all`; THIRD-PARTY-NOTICES.md must
/// say the same thing word for word, and the licence texts must be the ones
/// that ship next to the bundled copies.
@Suite("Third-party notices")
struct ThirdPartyNoticesTests {
    /// The Jamf Deployer folder, four levels up from this file
    /// (JamfDeployerCore/Tests/JamfDeployerCoreTests/).
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// One section of THIRD-PARTY-NOTICES.md, after its "## ".
    private static func section(for component: ThirdPartyComponent) -> String {
        var text = "\(component.heading)\n\n\(component.summary)\n\n"
        for link in component.links {
            text += "- [\(link.title)](\(link.address))\n"
        }
        if let licence = component.licence, let name = component.licenceName {
            text += "\nLicence: \(name)\n\n```text\n\(licence)\n```\n"
        }
        return text
    }

    private static func noticeSections() throws -> [String] {
        let notices = try String(contentsOf: repository.appending(path: "THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        return Array(notices.components(separatedBy: "\n## ").dropFirst())
    }

    @Test func noticesListTheSameComponentsInTheSameOrder() throws {
        let headings = try Self.noticeSections().map { String($0.prefix { $0 != "\n" }) }
        #expect(headings == ThirdPartyComponent.all.map(\.heading))
    }

    @Test(arguments: ThirdPartyComponent.all)
    func noticeMatchesAboutWordForWord(component: ThirdPartyComponent) throws {
        let section = try #require(try Self.noticeSections().first { $0.hasPrefix(component.heading + "\n") })
        #expect(section == Self.section(for: component))
    }

    @Test(arguments: ThirdPartyComponent.all.filter { $0.licenceFile != nil })
    func everyBundledLicenceIsInTheApp(component: ThirdPartyComponent) throws {
        let licence = try #require(component.licence)
        #expect(!licence.isEmpty)
        #expect(component.licenceName != nil)
    }

    /// Terraform is downloaded with consent, never bundled, so there is no text.
    @Test func terraformHasNoLicenceText() throws {
        let terraform = try #require(ThirdPartyComponent.all.first { $0.name == "HashiCorp Terraform" })
        #expect(terraform.licence == nil)
        #expect(terraform.summary.contains("only after you agree"))
        #expect(terraform.summary.contains("never bundled"))
    }

    @Test func jamformerIsCreditedToJamfSoftware() throws {
        let jamformer = try #require(ThirdPartyComponent.all.first { $0.name == "jamformer" })
        #expect(jamformer.licence?.hasPrefix("MIT License\n\nCopyright (c) 2026 Jamf Software LLC\n") == true)
        #expect(jamformer.links.map(\.address) == ["https://github.com/Jamf-Concepts/jamformer"])
    }

    // MARK: The copies next to the bundled tools

    /// Where `Vendor/fetch.sh` puts each licence. The providers' are inside their zips.
    private static let vendorLicences: [String: String] = [
        "opentofu": "Vendor/opentofu/bin/LICENSE",
        "terraform-backend-git": "Vendor/terraform-backend-git/LICENSE",
        "jamformer": "Vendor/jamformer/LICENSE",
        "jamfplatform-provider": "Vendor/providers/registry.opentofu.org/jamf/jamfplatform",
        "jamfprotect-provider": "Vendor/providers/registry.opentofu.org/jamf-concepts/jamfprotect",
        "jamfpro-provider": "Vendor/providers/registry.opentofu.org/deploymenttheory/jamfpro",
    ]

    /// Compares the app's text with the one fetched into Vendor/. Vendor/ is not
    /// in git, so a Mac that hasn't run fetch.sh skips this.
    @Test(arguments: vendorLicences.keys.sorted())
    func licenceMatchesTheBundledCopy(file: String) throws {
        let component = try #require(ThirdPartyComponent.all.first { $0.licenceFile == file })
        let inApp = try #require(component.licenceFileText)
        let relativePath = try #require(Self.vendorLicences[file])
        let path = Self.repository.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        let vendored: String
        if path.lastPathComponent == "LICENSE" {
            vendored = try String(contentsOf: path, encoding: .utf8)
        } else {
            let zips = try FileManager.default.contentsOfDirectory(atPath: path.path)
                .filter { $0.hasSuffix("_darwin_arm64.zip") }
            let zip = try #require(zips.first, "no darwin_arm64 zip in \(path.path)")
            vendored = try Self.unzipLicence(path.appending(path: zip))
        }
        #expect(inApp == vendored, "\(file): the text in Licences/ differs from \(path.path)")
    }

    private static func unzipLicence(_ zip: URL) throws -> String {
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-p", zip.path, "LICENSE"]
        let output = Pipe()
        unzip.standardOutput = output
        try unzip.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
