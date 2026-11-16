import Foundation
import Testing
@testable import JamfDeployerCore

// jamfplatform 1.8 renamed PreStage attributes and flattened pro_policy;
// 1.9 refuses "" and "0" (and, for enrollment customizations, "-1") as
// reference IDs at plan time. Captures, checks and previews follow along.
// All data below is made up.

@Suite("jamfplatform 1.8 and 1.9")
struct ProviderUpgradeTests {
    private static func resolve(_ source: String, table: BlockCapture.ReferenceTable = .init(),
                                localAddresses: Set<String> = []) -> (text: String, warnings: [String]) {
        var text = source
        var builtins = Set<String>()
        var warnings = [String]()
        _ = BlockCapture.resolveAssociations(in: &text, table: table, localAddresses: localAddresses,
                                             namePrefix: "", builtinGroupNames: &builtins, warnings: &warnings)
        return (text, warnings)
    }

    @Test("A flattened policy's script_assignments resolve like the old scripts block")
    func scriptAssignmentsResolve() {
        var table = BlockCapture.ReferenceTable()
        table.addressByTypeAndID["jamfplatform_pro_script#12"] = "jamfplatform_pro_script.example_script"
        table.nameByAddress["jamfplatform_pro_script.example_script"] = "Example Script"
        let (text, warnings) = Self.resolve("""
        resource "jamfplatform_pro_policy" "example" {
          script_assignments = [
            {
              id = "12" # TODO: unresolved reference
              priority = "After"
            },
          ]
        }
        """, table: table, localAddresses: ["jamfplatform_pro_script.example_script"])
        #expect(text.contains("id = jamfplatform_pro_script.example_script.id"))
        #expect(!text.contains("TODO: unresolved reference"))
        #expect(warnings.isEmpty)
    }

    @Test("An enrollment customization of \"-1\" or \"\" becomes \"0\", which means none", arguments: [#""-1""#, #""""#])
    func enrollmentCustomizationNoneIsZero(value: String) {
        let (text, _) = Self.resolve("""
        resource "jamfplatform_pro_computer_prestage_enrollment" "example" {
          display_name                = "Example PreStage"
          enrollment_customization_id = \(value)
        }
        """)
        #expect(text.contains(#"enrollment_customization_id = "0""#))
        #expect(!text.contains(#""-1""#))
    }

    @Test("An app without a location gets vpp_admin_account_id \"-1\", never \"0\" or \"\"", arguments: [#""0""#, #""""#])
    func appWithoutLocationIsMinusOne(value: String) throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "vpp-none-src-\(UUID().uuidString)")
        let catalog = FileManager.default.temporaryDirectory.appending(path: "vpp-none-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: catalog) }
        try Data("""
        resource "jamfplatform_pro_mac_app_store_app" "example_app" {
          general = {
            name = "Example App"
          }
          vpp = {
            assign_vpp_device_based_licenses = false
            vpp_admin_account_id             = \(value)
          }
        }
        """.utf8).write(to: source.appending(path: "pro_mac_app_store_app.tf"))

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "apps", name: "Apps", summary: "", namePrefix: "",
            sourceDirectory: source, catalogRootDirectory: catalog))
        let apps = try String(contentsOf: result.blockFolderURL.appending(path: "pro_mac_app_store_app.tf"), encoding: .utf8)
        #expect(apps.contains(#"vpp_admin_account_id             = "-1""#))
        #expect(!apps.contains("apps_and_books"), "no location is looked up for it")
    }

    @Test("Check for Changes ignores configuration_profile_ids, as it did prestage_installed_profile_ids")
    func renamedProfileListIsComputed() {
        #expect(DriftReportBuilder.isComputed("prestage_installed_profile_ids"))
        #expect(DriftReportBuilder.isComputed("configuration_profile_ids"))
    }

    @Test("A warning repeated for many objects shows once, with how often it came")
    func repeatedWarningsAreGrouped() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(#"{"resource_changes": []}"#.utf8))
        func warning(_ summary: String) -> EngineStreamEvent.Diagnostic {
            .init(severity: "warning", summary: summary, detail: nil, address: nil)
        }
        let summary = PreviewBuilder.build(plan: plan, diagnostics: [
            warning("Argument is deprecated"), warning("Other note"),
            warning("Argument is deprecated"), warning("Argument is deprecated"),
        ], blockNames: [:])
        #expect(summary.generalNotes == ["Argument is deprecated (3 times)", "Other note"])
    }
}
