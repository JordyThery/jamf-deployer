import Foundation
import Testing
@testable import JamfDeployerCore

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("HCL block splitting")
struct HCLSplittingTests {
    @Test func bracesInStringsInterpolationsAndHeredocsDontCount() {
        var scanner = HCLScanner()
        #expect(scanner.scan(#"  notes = "closes } early { maybe""#).braces == 0)
        #expect(scanner.scan(#"  name = "${var.dep_ids["Fleet } x"]}""#).braces == 0)
        #expect(scanner.scan(#"  value = "say \"}\" and $${not} %%{this}""#).braces == 0)
        #expect(scanner.scan("  scope = { # a comment with }").braces == 1)
        #expect(scanner.scan("  script = <<-EOT").braces == 0)
        #expect(scanner.isInHeredoc)
        #expect(scanner.scan("    if [ x ]; then echo }; fi").braces == 0)
        #expect(scanner.scan("  EOT").braces == 0)
        #expect(!scanner.isInHeredoc)
        #expect(scanner.scan("  }").braces == -1)
    }

    static let tricky = """
    resource "jamfplatform_pro_policy" "a" {
      general = {
        name  = "Policy A"
        notes = "Ends with a brace }"
      }
      scope = {
        all_computers = true
      }
    }

    resource "jamfplatform_pro_script" "b" {
      name            = "Script {B"
      script_contents = <<-EOT
        #!/bin/sh
        echo "}"
        }
      EOT
      priority = "AFTER"
    }

    import {
      to = jamfplatform_pro_policy.a
      id = "1"
    }
    """

    @Test func splitsAroundBracesInStringsAndHeredocs() throws {
        let blocks = try ExportedObjectInventory.checkedTopLevelBlocks(in: Self.tricky)
        #expect(blocks.count == 3)
        #expect(blocks[0].hasSuffix("    all_computers = true\n  }\n}"))
        #expect(blocks[1].contains(#"priority = "AFTER""#))
        #expect(blocks[1].hasSuffix("}"))
        #expect(blocks[2].hasPrefix("import {"))
    }

    @Test func refusesLinesItCannotPlace() {
        // An extra closing brace leaves the following body lines outside
        // every block: they must never be dropped silently.
        let broken = "resource \"t\" \"a\" {\n  name = \"A\"\n}\n}\n  scope = {}\n"
        #expect(throws: ExportedObjectInventory.SplitError.strayLine(4)) {
            try ExportedObjectInventory.checkedTopLevelBlocks(in: broken)
        }
        #expect(throws: ExportedObjectInventory.SplitError.unterminated(1)) {
            try ExportedObjectInventory.checkedTopLevelBlocks(in: "resource \"t\" \"a\" {\n  name = \"A\"\n")
        }
        // Comments between blocks are fine.
        #expect((try? ExportedObjectInventory.checkedTopLevelBlocks(in: "# header\n\nresource \"t\" \"a\" {}\n// end\n"))?.count == 1)
    }

    @Test func pruneKeepsEveryLineOfObjectsWithBracesInText() throws {
        let directory = try temporaryFolder("prune-braces")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.tricky.utf8).write(to: directory.appending(path: "main.tf"))
        try ExportedObjectInventory.prune(directory: directory, keeping: ["jamfplatform_pro_policy.a", "jamfplatform_pro_script.b"])
        let pruned = try String(contentsOf: directory.appending(path: "main.tf"), encoding: .utf8)
        #expect(pruned.contains("all_computers = true"))
        #expect(pruned.contains(#"priority = "AFTER""#))
        #expect(pruned.contains("to = jamfplatform_pro_policy.a"))

        try ExportedObjectInventory.prune(directory: directory, keeping: ["jamfplatform_pro_script.b"])
        let again = try String(contentsOf: directory.appending(path: "main.tf"), encoding: .utf8)
        #expect(!again.contains("Policy A"))
        #expect(again.contains("echo \"}\"") && again.contains(#"priority = "AFTER""#))
    }

    @Test func pruneStopsBeforeChangingAnything() throws {
        let directory = try temporaryFolder("prune-stray")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = "resource \"jamfplatform_pro_category\" \"c\" {\n  name = \"C\"\n}\n"
        try Data(good.utf8).write(to: directory.appending(path: "a.tf"))
        try Data("resource \"jamfplatform_pro_script\" \"s\" {\n  name = \"S\"\n}\n}\n  info = \"x\"\n".utf8)
            .write(to: directory.appending(path: "b.tf"))
        #expect(throws: ExportedObjectInventory.SplitError.self) {
            try ExportedObjectInventory.prune(directory: directory, keeping: [])
        }
        #expect(try String(contentsOf: directory.appending(path: "a.tf"), encoding: .utf8) == good)
    }

    @Test func removingAnAttributeSkipsBracesInsideIt() {
        let block = "resource \"t\" \"a\" {\n  ldap_panes = [{\n    title = \"Sign in }\"\n  }]\n  name = \"A\"\n}"
        #expect(BlockCapture.removingAttribute("ldap_panes", from: block) == "resource \"t\" \"a\" {\n  name = \"A\"\n}")
    }
}

@Suite("Prefix all names")
struct PrefixAllNamesTests {
    @Test func prefixesOnlyObjectNames() {
        let text = """
        resource "jamfplatform_pro_policy" "p" {
          general = {
            name = "Install Rosetta"
          }
          self_service = {
            name = "Not an object name"
          }
        }

        resource "jamfplatform_pro_advanced_computer_search" "s" {
          criteria = [
            {
              name  = "Computer Group"
              value = "Pilot"
            },
          ]
          name = "Managed Macs"
        }

        resource "jamfplatform_pro_package" "k" {
          display_name = "Office"
          notes        = <<-EOT
            name = "inside a heredoc"
          EOT
        }

        resource "jamfplatform_pro_category" "c" {
          name = "${var.name_prefix}Already"
        }

        data "jamfplatform_device_group" "g" {
          name = "All Managed Clients"
        }
        """
        let prefixed = BlockCapture.prefixingObjectNames(in: text)
        #expect(prefixed.contains(#"    name = "${var.name_prefix}Install Rosetta""#))
        #expect(prefixed.contains(#"    name = "Not an object name""#))
        #expect(prefixed.contains(#"      name  = "Computer Group""#))
        #expect(prefixed.contains(#"  name = "${var.name_prefix}Managed Macs""#))
        #expect(prefixed.contains(#"  display_name = "${var.name_prefix}Office""#))
        #expect(prefixed.contains(#"    name = "inside a heredoc""#))
        #expect(prefixed.contains(#"  name = "${var.name_prefix}Already""#))
        #expect(!prefixed.contains("${var.name_prefix}${var.name_prefix}"))
        #expect(prefixed.contains(#"  name = "All Managed Clients""#))
    }

    @Test func advancedSearchCriteriaKeepTheirFieldNames() throws {
        let export = try CaptureWiringTests.writeExport()
        let catalog = try temporaryFolder("prefix-all-dst")
        defer { try? FileManager.default.removeItem(at: export); try? FileManager.default.removeItem(at: catalog) }
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "prefixed", name: "Prefixed", summary: "", namePrefix: "Other - ",
            sourceDirectory: export, catalogRootDirectory: catalog, prefixAllNames: true))
        let search = try String(contentsOf: result.blockFolderURL.appending(path: "pro_advanced_computer_search.tf"), encoding: .utf8)
        #expect(search.contains(#"name        = "Computer Group""#))
        #expect(!search.contains("${var.name_prefix}Computer Group"))
        #expect(search.contains(#"name           = "${var.name_prefix}Fleet - Managed Macs""#))
        // The criterion still wires to the group it names.
        #expect(search.contains("jamfplatform_device_group.fleet_all_managed_computer.name"))
        let groups = try String(contentsOf: result.blockFolderURL.appending(path: "device_groups.tf"), encoding: .utf8)
        #expect(groups.contains(#"name        = "${var.name_prefix}Fleet - All Managed""#))
    }
}

@Suite("Capture safety")
struct CaptureSafetyTests {
    @Test func aStoppedCaptureLeavesNoFolderBehind() throws {
        let export = try SecretScanTests.copyExport()
        let root = try temporaryFolder("capture-cleanup")
        defer { try? FileManager.default.removeItem(at: export); try? FileManager.default.removeItem(at: root) }
        let lost = JamformerSecretFinding(
            location: SecretFinding(path: SecretScanTests.scriptPath, line: 3, rule: "Password value in HCL attribute"),
            maskedText: "NOPE*****-999")
        #expect(throws: BlockCapture.CaptureError.self) {
            try SecretScanTests.capture(export: export, findings: [lost], root: root, id: "retry-me")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "blocks/retry-me").path))
        // The same ID can be captured again.
        let result = try SecretScanTests.capture(export: export, findings: [], root: root, id: "retry-me")
        #expect(result.objectCount > 0)
    }

    @Test func aFileThatDoesntSplitStopsTheCapture() throws {
        let export = try temporaryFolder("capture-stray")
        let root = try temporaryFolder("capture-stray-dst")
        defer { try? FileManager.default.removeItem(at: export); try? FileManager.default.removeItem(at: root) }
        try Data("resource \"jamfplatform_pro_script\" \"s\" {\n  name = \"S\"\n}\n}\n  info = \"x\"\n".utf8)
            .write(to: export.appending(path: "pro_script.tf"))
        #expect(throws: ExportedObjectInventory.SplitError.self) {
            try BlockCapture.capture(BlockCapture.Request(
                blockID: "stray", name: "Stray", summary: "", namePrefix: "", sourceDirectory: export, catalogRootDirectory: root))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "blocks/stray").path))
    }

    @Test func theOriginTenantIsRecordedAsAHashOnly() throws {
        let export = try temporaryFolder("capture-origin")
        let root = try temporaryFolder("capture-origin-dst")
        defer { try? FileManager.default.removeItem(at: export); try? FileManager.default.removeItem(at: root) }
        try Data("resource \"jamfplatform_pro_category\" \"c\" {\n  name = \"C\"\n}\n".utf8)
            .write(to: export.appending(path: "pro_category.tf"))
        let origin = "00000000-0000-4000-8000-000000000001"
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "origin", name: "Origin", summary: "", namePrefix: "", sourceDirectory: export,
            catalogRootDirectory: root, originTenantScopeID: origin))
        let text = try String(contentsOf: result.blockFolderURL.appending(path: "block.json"), encoding: .utf8)
        #expect(!text.contains(origin))
        let block = try JSONDecoder().decode(BlockMetadata.self, from: Data(text.utf8))
        #expect(block.capturedFromTenant?.hasPrefix("sha256:") == true)
        #expect(block.wasCaptured(fromTenantScopeID: origin))
        #expect(block.wasCaptured(fromTenantScopeID: origin.uppercased()))
        #expect(!block.wasCaptured(fromTenantScopeID: "00000000-0000-4000-8000-000000000002"))
        #expect(!block.wasCaptured(fromTenantScopeID: ""))
        // Blocks captured before 1.1.0 hold the scope ID itself.
        let legacy = try GeneratorTests.metadata(#"{"id": "legacy", "capturedFromTenant": "\#(origin)"}"#)
        #expect(legacy.wasCaptured(fromTenantScopeID: origin))
    }

    @Test func tfvarsValuesOfEveryShapeCountAsExported() throws {
        let values = BlockCapture.parseTfvarsValues("""
        name     = "Plain \\"quoted\\""
        count    = 5
        enabled  = true
        groups   = [
          "a",
          "b",
        ]
        settings = { a = "}" }
        script   = <<-EOT
          echo "hi"
          echo done
        EOT
        """)
        #expect(values["name"] == .init(expression: #""Plain \"quoted\"""#, stringContent: #"Plain \"quoted\""#))
        #expect(values["count"]?.expression == "5")
        #expect(values["enabled"]?.expression == "true")
        #expect(values["groups"]?.expression == "[\n  \"a\",\n  \"b\",\n]")
        #expect(values["settings"]?.expression == #"{ a = "}" }"#)
        #expect(values["script"]?.stringContent == #"echo \"hi\"\necho done\n"#)

        let directory = try temporaryFolder("tfvars")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("variable \"groups\" {\n  type = list(string)\n}\n\nvariable \"count\" {\n  type = number\n}\n".utf8)
            .write(to: directory.appending(path: "variables.tf"))
        try Data("groups = [\n  \"a\",\n]\ncount = 5\n".utf8).write(to: directory.appending(path: "terraform.tfvars"))
        try Data("resource \"jamfplatform_pro_policy\" \"p\" {\n  groups = var.groups\n  count  = var.count\n}\n".utf8)
            .write(to: directory.appending(path: "main.tf"))
        // Neither variable is mistaken for a value Jamf didn't export.
        #expect(ExportedObjectInventory.unmanageable(directory: directory).isEmpty)
        try ExportedObjectInventory.inlineVariables(directory: directory)
        let inlined = try String(contentsOf: directory.appending(path: "main.tf"), encoding: .utf8)
        #expect(inlined.contains("groups = [\n  \"a\",\n]"))
        #expect(inlined.contains("count  = 5"))
    }
}

@Suite("Settings checks")
struct SettingsCheckTests {
    static func block(_ settings: String) throws -> BlockMetadata {
        try GeneratorTests.metadata(#"{"id": "checked", "name": "Checked", "settings": [\#(settings)]}"#)
    }

    @Test func choicesMustBeOnesTheBlockOffers() throws {
        let block = try Self.block(#"{"key": "mode", "title": "Mode", "type": "enum", "default": "block", "enumValues": ["block", "report"]}"#)
        func generate(_ value: String?) throws -> String {
            try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "", selections: [GeneratedSelection(block: block, settings: value.map { ["mode": $0] } ?? [:])],
                providerVersion: "1.6.0")).mainTF
        }
        #expect(try generate(nil).contains(#""block""#))
        #expect(try generate("report").contains(#""report""#))
        #expect {
            _ = try generate("Report")
        } throws: { error in
            guard case WorkspaceGeneratorError.invalidChoice(_, let setting, let value) = error else { return false }
            return setting == "Mode" && value == "Report"
        }
    }

    @Test func anUnreadableAppListNeverDeploys() throws {
        let block = try Self.block(#"{"key": "apps_json", "title": "Apps", "type": "appPicker", "default": "[]"}"#)
        func generate(_ value: String) throws {
            _ = try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "", selections: [GeneratedSelection(block: block, settings: ["apps_json": value])],
                providerVersion: "1.6.0"))
        }
        try generate("")
        try generate(AppCatalogApp.encode([AppCatalogApp(titleName: "Zoom", publisher: "Zoom")]))
        #expect(throws: WorkspaceGeneratorError.self) { try generate("[{\"titleName\": ") }
        #expect(AppCatalogApp.decodeIfReadable(settingValue: "not json") == nil)
        #expect(AppCatalogApp.decodeIfReadable(settingValue: "") == [])
        #expect(AppStoreApp.decodeIfReadable(settingValue: "{}") == nil)
        #expect(AppStoreApp.decodeIfReadable(settingValue: "[]") == [])
    }

    @Test func anUnreadablePresetSkipsOnlyItself() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: CatalogTests.catalogURL, to: root)
        let before = try LoadedCatalog.load(from: root)
        try Data("{ not a preset".utf8).write(to: root.appending(path: "presets/broken.json"))
        let catalog = try LoadedCatalog.load(from: root)
        #expect(catalog.presets.map(\.id) == before.presets.map(\.id))
        #expect(catalog.blocks.count == before.blocks.count)
        #expect(catalog.unreadablePresets == ["broken.json"])
        #expect(LoadedCatalog.merge([before, catalog]).unreadablePresets == ["broken.json"])
    }
}

@Suite("Retry and recovery checks")
struct RetryRecoveryTests {
    static func plan(_ address: String, actions: [String], after: String, unknown: String = "{}") throws -> PlanFile {
        let json = #"{"format_version": "1.2", "resource_changes": [{"address": "\#(address)", "type": "t", "name": "n", "change": {"actions": [\#(actions.map { "\"\($0)\"" }.joined(separator: ","))], "after": \#(after), "after_unknown": \#(unknown)}}]}"#
        return try JSONDecoder().decode(PlanFile.self, from: Data(json.utf8))
    }

    @Test func aChangedValueIsOutsideTheApprovedPlan() throws {
        let policy = DeleteOrderRetryTests.policy
        let approved = try Self.plan(policy, actions: ["update"], after: #"{"name": "Rotate", "frequency": "Ongoing", "scope": {"groups": [1]}}"#)
        let same = try Self.plan(policy, actions: ["update"], after: #"{"scope": {"groups": [1]}, "frequency": "Ongoing", "name": "Rotate"}"#)
        let changed = try Self.plan(policy, actions: ["update"], after: #"{"name": "Rotate", "frequency": "Once per computer", "scope": {"groups": [1]}}"#)
        let moreGroups = try Self.plan(policy, actions: ["update"], after: #"{"name": "Rotate", "frequency": "Ongoing", "scope": {"groups": [1, 2]}}"#)
        #expect(DeleteOrderRetry.staysWithin(same, approved: approved))
        #expect(!DeleteOrderRetry.staysWithin(changed, approved: approved))
        #expect(DeleteOrderRetry.changesOutside(changed, approved: approved) == [policy])
        #expect(!DeleteOrderRetry.staysWithin(moreGroups, approved: approved))
    }

    @Test func valuesUnknownAtPreviewMayBeAnything() throws {
        // The new group's ID was unknown when the plan was approved; the
        // retry knows it because the group was created in the meantime.
        let policy = DeleteOrderRetryTests.policy
        let approved = try Self.plan(policy, actions: ["update"], after: #"{"name": "Rotate", "scope": {"groups": [null]}}"#,
                                     unknown: #"{"scope": {"groups": [true]}}"#)
        let retry = try Self.plan(policy, actions: ["update"], after: #"{"name": "Rotate", "scope": {"groups": ["42"]}}"#)
        let renamed = try Self.plan(policy, actions: ["update"], after: #"{"name": "Renamed", "scope": {"groups": ["42"]}}"#)
        #expect(DeleteOrderRetry.staysWithin(retry, approved: approved))
        #expect(!DeleteOrderRetry.staysWithin(renamed, approved: approved))
    }

    @Test func anObjectThatExistedBeforeTheApplyIsNeverRecovered() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(#"""
        {"format_version": "1.2", "resource_changes": [
          {"address": "module.b.jamfplatform_pro_policy.p", "type": "jamfplatform_pro_policy", "name": "p",
           "change": {"actions": ["create"], "after": {"general": {"name": "JD - Enable FileVault"}}}},
          {"address": "module.b.jamfplatform_pro_category.c", "type": "jamfplatform_pro_category", "name": "c",
           "change": {"actions": ["create"], "after": {"name": "JD - Security"}}}
        ]}
        """#.utf8))
        let planned = CreateFailureRecovery.plannedCreates(plan: plan)
        #expect(planned.map(\.name) == ["JD - Enable FileVault"])
        let candidate = try #require(planned.first)
        // A hand-made policy with the planned name was there before the apply.
        let lookup = Data(#"{"policy":{"general":{"id":17,"name":"JD - Enable FileVault"}}}"#.utf8)
        let before = CreateFailureRecovery.matchingIDs(in: lookup, for: candidate)
        #expect(before == ["17"])
        #expect(CreateFailureRecovery.objectID(in: lookup, for: candidate, existedBefore: before) == nil)
        // One Jamf created during the apply is recovered.
        let created = Data(#"{"policy":{"general":{"id":18,"name":"JD - Enable FileVault"}}}"#.utf8)
        #expect(CreateFailureRecovery.objectID(in: created, for: candidate, existedBefore: before) == "18")
    }
}

@Suite("Enrollment icons")
struct EnrollmentIconTests {
    @Test func downloadsOnlyFromTheOriginTenant() {
        let hosts: Set<String> = ["origin.example.com"]
        #expect(EnrollmentIcons.mayDownload(URL(string: "https://origin.example.com/icon/1")!, allowedHosts: hosts))
        #expect(EnrollmentIcons.mayDownload(URL(string: "https://ORIGIN.example.com/icon/1")!, allowedHosts: hosts))
        #expect(!EnrollmentIcons.mayDownload(URL(string: "http://origin.example.com/icon/1")!, allowedHosts: hosts))
        #expect(!EnrollmentIcons.mayDownload(URL(string: "https://origin.example.com.evil.example/icon")!, allowedHosts: hosts))
        #expect(!EnrollmentIcons.mayDownload(URL(string: "https://user:pass@origin.example.com/icon")!, allowedHosts: hosts))
        #expect(EnrollmentIcons.mayDownload(URL(string: "https://a.jamfcloud.com/i")!, allowedHosts: [".jamfcloud.com"]))
        #expect(!EnrollmentIcons.mayDownload(URL(string: "https://jamfcloud.com.example/i")!, allowedHosts: [".jamfcloud.com"]))
    }

    @Test func localizesThroughTheAppsFetch() async throws {
        let directory = try temporaryFolder("icons")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        resource "jamfplatform_pro_enrollment_customization" "ours" {
          display_name = "Ours"
          icon_url     = "https://origin.example.com/icon/1"
          branding_settings = {
            text_color = "000000"
          }
        }

        resource "jamfplatform_pro_enrollment_customization" "elsewhere" {
          display_name = "Elsewhere"
          icon_url     = "https://other.example.net/icon/2"
          branding_settings = {
            text_color = "000000"
          }
        }
        """.utf8).write(to: directory.appending(path: "pro_enrollment_customization.tf"))
        let left = await EnrollmentIcons.localize(directory: directory, allowedHosts: ["origin.example.com"]) { url in
            #expect(url.host() == "origin.example.com")
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        #expect(left.map(\.absoluteString) == ["https://other.example.net/icon/2"])
        let text = try String(contentsOf: directory.appending(path: "pro_enrollment_customization.tf"), encoding: .utf8)
        #expect(text.contains(#"icon_source = "${path.module}/support_files/enrollment_customization_icons/ours.png""#))
        #expect(text.contains("https://other.example.net/icon/2"))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "support_files/enrollment_customization_icons/ours.png").path))
    }
}
