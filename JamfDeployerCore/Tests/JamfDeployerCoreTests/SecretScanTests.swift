import Foundation
import Testing
@testable import JamfDeployerCore

/// Built from a real jamformer 0.6.1 run against a test tenant with
/// obviously fake secrets in one script and one Wi-Fi profile.
@Suite("Secret scan")
struct SecretScanTests {
    static let fakeScriptSecret = "FAKE-NotARealSecret-123"
    static let fakeWifiSecret = "FAKE-NotARealWifi-456"
    static let scriptPath = "support_files/scripts/ZZ Secret Scan Test.zsh"
    static let profilePath = "support_files/macos_configuration_profiles/ZZ Secret Scan Test.mobileconfig"

    /// jamformer's output as the app reads it: terminal colours removed,
    /// blank lines kept.
    static func reportLines() throws -> [String] {
        let url = Bundle.module.url(forResource: "Fixtures/secret-scan/jamformer-output.txt", withExtension: nil)!
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[@-~]"#, with: "", options: .regularExpression)
        return text.components(separatedBy: "\n")
    }

    static func copyExport() throws -> URL {
        let source = Bundle.module.url(forResource: "Fixtures/secret-scan/export", withExtension: nil)!
        let copy = FileManager.default.temporaryDirectory.appending(path: "secret-export-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    @Test func readsJamformersReportWithBlankLinesInside() throws {
        let findings = SecretScan.parseJamformerReport(try Self.reportLines())
        #expect(findings.map(\.location) == [
            SecretFinding(path: Self.profilePath, line: 18, rule: "Password or secret in plist/XML configuration"),
            SecretFinding(path: Self.scriptPath, line: 3, rule: "Password value in HCL attribute"),
        ])
    }

    @Test func stopsAtTheEndOfTheList() {
        let lines = [
            "!  Secret scan found 1 potential secret(s):", "", "  In support files:", "",
            "    support_files/scripts/a.zsh", "      Line 3    FAKE***-123  (Password value in HCL attribute)", "", "",
            "  Review these findings before committing to version control.", "",
            "✓ 2 resources across 2 types in 2 files", "  Output: /tmp/x", "Next steps:",
        ]
        let findings = SecretScan.parseJamformerReport(lines)
        #expect(findings.count == 1)
        #expect(SecretScan.parseJamformerReport(["  No secrets detected in generated output"]).isEmpty)
    }

    @Test func linesShownOrLoggedNeverCarryTheScannedText() throws {
        let shown = try Self.reportLines().map(SecretScan.withoutScannedText)
        #expect(!shown.joined().contains("FAKE"))
        #expect(!shown.joined().contains("***"))
        #expect(shown.contains("      Line 3  (Password value in HCL attribute)"))
    }

    @Test func tiesFindingsToObjects() throws {
        let export = try Self.copyExport()
        defer { try? FileManager.default.removeItem(at: export) }
        let findings = SecretScan.parseJamformerReport(try Self.reportLines())
        let objects = SecretScan.objectFindings(findings.map(\.location), in: export)
        #expect(objects.map(\.objectDescription) == [
            "macOS configuration profile “ZZ Secret Scan Test”",
            "Script “ZZ Secret Scan Test”",
        ])
        #expect(Set(objects.compactMap(\.address)) == [
            "jamfplatform_pro_macos_configuration_profile.zz_secret_scan_test",
            "jamfplatform_pro_script.zz_secret_scan_test",
        ])
    }

    @Test func findsTheValueBehindAMaskedFinding() throws {
        let export = try Self.copyExport()
        defer { try? FileManager.default.removeItem(at: export) }
        let findings = SecretScan.parseJamformerReport(try Self.reportLines())
        #expect(findings.map { SecretScan.value(of: $0, in: export) } == [Self.fakeWifiSecret, Self.fakeScriptSecret])
    }

    @Test func ownScanFindsWhatJamformerFound() throws {
        let export = try Self.copyExport()
        defer { try? FileManager.default.removeItem(at: export) }
        let findings = SecretScan.scanExport(export).sorted { $0.path < $1.path }
        #expect(findings == [
            SecretFinding(path: Self.profilePath, line: 18, rule: "Password or secret in plist/XML configuration"),
            SecretFinding(path: Self.scriptPath, line: 3, rule: "Password value in HCL attribute"),
        ])
    }

    @Test(arguments: [
        #"password = var.wifi_password"#,
        #"password = "${var.wifi_password}""#,
        #"{"password":"<redacted>"}"#,
        #"password_policy = "complex123""#,
        #"<key>PasswordHint</key><string>Ask the help desk</string>"#,
        #"token_type = "Bearer""#,
        #"client_secret = "********""#,
        #"PASSWORD="$1""#,
    ])
    func ignoresReferencesAndPlaceholders(_ text: String) {
        #expect(SecretScan.scan(text: text, path: "x").isEmpty)
    }

    @Test(arguments: [
        #"password = "FAKE-NotARealSecret-123""#,
        "export API_TOKEN=FAKEtokenValue123",
        // A history log line: engine output stored as JSON, quotes escaped.
        #"{"message":"client_secret = \"FAKE-NotARealSecret-123\""}"#,
        "<key>Password</key>\n<string>FAKE-NotARealWifi-456</string>",
        "-----BEGIN RSA PRIVATE KEY-----",
        // A README captured before this check, listing jamformer's findings.
        "- Line 3    FAKE***************-123  (Password value in HCL attribute)",
    ])
    func findsSecrets(_ text: String) {
        #expect(SecretScan.scan(text: text, path: "x").count == 1)
    }

    @Test func templatesEscapeExistingInterpolation() {
        let script = #"echo "${HOME}" %{x}; PASSWORD="FAKE-NotARealSecret-123""#
        let templated = SecretScan.templated(script, replacing: [(Self.fakeScriptSecret, "secret_x")])
        #expect(templated == #"echo "$${HOME}" %%{x}; PASSWORD="${secret_x}""#)
    }

    @Test func pruningRemovesTheFilesOfObjectsLeftOut() throws {
        let export = try Self.copyExport()
        defer { try? FileManager.default.removeItem(at: export) }
        try ExportedObjectInventory.prune(directory: export, keeping: ["jamfplatform_pro_macos_configuration_profile.zz_secret_scan_test"])
        #expect(!FileManager.default.fileExists(atPath: export.appending(path: Self.scriptPath).path))
        #expect(FileManager.default.fileExists(atPath: export.appending(path: Self.profilePath).path))
        try ExportedObjectInventory.prune(directory: export, keeping: [])
        #expect(SecretScan.scanExport(export).isEmpty)
    }

    // MARK: Sensitive variables

    @Test func sensitiveVariablesAreNeverInlined() throws {
        let export = try Self.copyExport()
        defer { try? FileManager.default.removeItem(at: export) }
        try Data("""
        variable "wifi_password" {
          type      = string
          sensitive = true
        }

        variable "ssid" {
          type = string
        }
        """.utf8).write(to: export.appending(path: "variables.tf"))
        try Data("wifi_password = \"\(Self.fakeWifiSecret)\"\nssid = \"ZZ-Fake-Test-SSID\"\n".utf8)
            .write(to: export.appending(path: "terraform.tfvars"))
        try Data("resource \"jamfplatform_pro_script\" \"wifi\" {\n  name = var.ssid\n  info = var.wifi_password\n}\n".utf8)
            .write(to: export.appending(path: "wifi.tf"))

        try ExportedObjectInventory.inlineVariables(directory: export)
        let text = try String(contentsOf: export.appending(path: "wifi.tf"), encoding: .utf8)
        #expect(text.contains("name = \"ZZ-Fake-Test-SSID\""))
        #expect(text.contains("info = var.wifi_password"))
        #expect(!text.contains("FAKE"))

        let sensitive = ExportedObjectInventory.sensitiveVariables(directory: export)
        #expect(sensitive.map(\.name) == ["wifi_password"])
        #expect(sensitive.first?.value == Self.fakeWifiSecret)
        #expect(sensitive.first?.declaration.contains("default") == false)

        let declarations = export.appending(path: "adopted_sensitive_variables.tf")
        try ExportedObjectInventory.mergeSensitiveDeclarations(sensitive, into: declarations)
        try ExportedObjectInventory.mergeSensitiveDeclarations(sensitive, into: declarations)
        #expect(ExportedObjectInventory.declaredVariableNames(in: declarations) == ["wifi_password"])
        #expect(!(try String(contentsOf: declarations, encoding: .utf8)).contains("FAKE"))
    }

    // MARK: Capture

    static func capture(
        export: URL, findings: [JamformerSecretFinding], root: URL, id: String = "captured-secrets"
    ) throws -> BlockCapture.Result {
        try BlockCapture.capture(BlockCapture.Request(
            blockID: id, name: "Captured secrets", summary: "Captured.", namePrefix: "",
            sourceDirectory: export, catalogRootDirectory: root, secretFindings: findings))
    }

    /// Every file of a folder, as one text.
    static func allText(in folder: URL) -> String {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var text = ""
        while let url = enumerator?.nextObject() as? URL {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
    }

    @Test func captureTurnsFindingsIntoSecretSettings() throws {
        let export = try Self.copyExport()
        let root = FileManager.default.temporaryDirectory.appending(path: "secret-catalog-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: export)
            try? FileManager.default.removeItem(at: root)
        }
        let findings = SecretScan.parseJamformerReport(try Self.reportLines())
        let result = try Self.capture(export: export, findings: findings, root: root)
        let block = result.blockFolderURL

        // Nothing in the block holds a value or the scanned text.
        let everything = Self.allText(in: block)
        #expect(!everything.contains("FAKE"))
        #expect(!everything.contains("***"))

        #expect(result.secretSettings.map(\.objectDescription) == [
            "Script “ZZ Secret Scan Test”",
            "macOS configuration profile “ZZ Secret Scan Test”",
        ] || result.secretSettings.map(\.objectDescription) == [
            "macOS configuration profile “ZZ Secret Scan Test”",
            "Script “ZZ Secret Scan Test”",
        ])

        // The block's settings: secret, required, no default.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: block.appending(path: "block.json"))) as? [String: Any]
        let settings = (json?["settings"] as? [[String: Any]]) ?? []
        let secrets = settings.filter { $0["type"] as? String == "secret" }
        #expect(secrets.count == 2)
        #expect(secrets.allSatisfy { $0["required"] as? Bool == true && ($0["default"] as? String)?.isEmpty == true })

        // Each value is a sensitive variable, filled in through templatefile().
        let variables = try String(contentsOf: block.appending(path: "variables.tf"), encoding: .utf8)
        for setting in result.secretSettings {
            #expect(variables.contains("variable \"\(setting.key)\""))
        }
        #expect(variables.components(separatedBy: "sensitive   = true").count - 1 == 2)
        let scripts = try String(contentsOf: block.appending(path: "pro_script.tf"), encoding: .utf8)
        #expect(scripts.contains("templatefile(\"${path.module}/files/scripts/ZZ Secret Scan Test.zsh\", { secret_zz_secret_scan_test"))
        let script = try String(contentsOf: block.appending(path: "files/scripts/ZZ Secret Scan Test.zsh"), encoding: .utf8)
        #expect(script.contains("PASSWORD=\"${secret_zz_secret_scan_test"))

        // The README names the objects and rules only.
        let readme = try String(contentsOf: block.appending(path: "README.md"), encoding: .utf8)
        #expect(readme.contains("Script “ZZ Secret Scan Test”: Password value in HCL attribute"))
        #expect(readme.contains("macOS configuration profile “ZZ Secret Scan Test”: Password or secret in plist/XML configuration"))
        #expect(!readme.contains("Line "))

        // The block's own text passes the store check.
        #expect(SecretScan.scan(text: everything, path: "block").isEmpty)
    }

    @Test func captureIgnoresFindingsOfObjectsLeftOut() throws {
        let export = try Self.copyExport()
        let root = FileManager.default.temporaryDirectory.appending(path: "secret-catalog-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: export)
            try? FileManager.default.removeItem(at: root)
        }
        let original = try Self.copyExport()
        defer { try? FileManager.default.removeItem(at: original) }
        try ExportedObjectInventory.prune(directory: export, keeping: ["jamfplatform_pro_script.zz_secret_scan_test"])
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "only-script", name: "Only the script", summary: "Captured.", namePrefix: "",
            sourceDirectory: export, catalogRootDirectory: root,
            secretFindings: SecretScan.parseJamformerReport(try Self.reportLines()),
            resolutionDirectory: original))
        #expect(result.secretSettings.map(\.objectDescription) == ["Script “ZZ Secret Scan Test”"])
        let readme = try String(contentsOf: result.blockFolderURL.appending(path: "README.md"), encoding: .utf8)
        #expect(!readme.contains("profile"))
    }

    @Test func captureStopsWhenAValueCannotBeFound() throws {
        let export = try Self.copyExport()
        let root = FileManager.default.temporaryDirectory.appending(path: "secret-catalog-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: export)
            try? FileManager.default.removeItem(at: root)
        }
        let lost = JamformerSecretFinding(
            location: SecretFinding(path: Self.scriptPath, line: 3, rule: "Password value in HCL attribute"),
            maskedText: "NOPE*****-999")
        #expect(throws: BlockCapture.CaptureError.self) {
            try Self.capture(export: export, findings: [lost], root: root)
        }
    }

    @Test func captureNeverGivesASensitiveVariableADefault() throws {
        let export = try Self.copyExport()
        let root = FileManager.default.temporaryDirectory.appending(path: "secret-catalog-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: export)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("""
        variable "wifi_password" {
          type      = string
          sensitive = true
        }
        """.utf8).write(to: export.appending(path: "variables.tf"))
        try Data("wifi_password = \"\(Self.fakeWifiSecret)\"\n".utf8).write(to: export.appending(path: "terraform.tfvars"))
        try Data("resource \"jamfplatform_pro_script\" \"wifi\" {\n  name = \"Wifi\"\n  info = var.wifi_password\n}\n".utf8)
            .write(to: export.appending(path: "wifi.tf"))
        let result = try Self.capture(export: export, findings: [], root: root)
        #expect(!Self.allText(in: result.blockFolderURL).contains("FAKE"))
        #expect(result.secretSettings.contains { $0.key == "wifi_password" })
        let variables = try String(contentsOf: result.blockFolderURL.appending(path: "variables.tf"), encoding: .utf8)
        let declaration = try #require(BlockCapture.parseVariableDeclarations(
            at: result.blockFolderURL.appending(path: "variables.tf"))["wifi_password"])
        #expect(!declaration.contains("default"))
        #expect(variables.contains("variable \"wifi_password\""))
    }
}
