import Foundation
import Testing
@testable import JamfDeployerCore

// Settings Jamf Pro 11.34 retired (jamfplatform 1.10.0 deprecations), as an
// export writes them: every policy carries its whole maintenance object.
@Suite("Settings Jamf Pro 11.34 retired")
struct RetiredSettingsTests {
    private func policy(fixDiskPermissions: Bool) -> String {
        """
        resource "jamfplatform_pro_policy" "jd_maintenance" {
          name    = "JD - Maintenance"
          enabled = true
          maintenance = {
            fix_byhost_files        = false
            fix_disk_permissions    = \(fixDiskPermissions)
            flush_system_caches     = false
            install_cached_packages = false
            update_inventory        = true
          }
        }
        """
    }

    private func enrollmentSettings(signing: Bool, certificate: String) -> String {
        """
        resource "jamfplatform_pro_user_initiated_enrollment_settings" "this" {
          restrict_reenrollment_to_authorized_users_only = false
          sign_quickadd_package                          = \(signing)
          signing_mdm_profile_enabled                    = true
          mdm_signing_certificate = {
            keystore_file      = filebase64("files/mdm.p12")
            keystore_file_name = "mdm.p12"
          }
        \(certificate)
        }
        """
    }

    private let emptyCertificate = """
          developer_certificate = {
            keystore_file                = null
            keystore_file_name           = null
            keystore_password            = null
            keystore_password_wo_version = null
          }
        """

    @Test func fixDiskPermissionsOffIsLeftOut() {
        let result = RetiredSettings.cleaned(policy(fixDiskPermissions: false))
        #expect(!result.text.contains("fix_disk_permissions"))
        #expect(result.text.contains("fix_byhost_files        = false"))
        #expect(result.text.contains("update_inventory        = true"))
        #expect(result.notes.isEmpty)
    }

    @Test func fixDiskPermissionsOnStaysWithANote() {
        let result = RetiredSettings.cleaned(policy(fixDiskPermissions: true))
        #expect(result.text.contains("fix_disk_permissions    = true"))
        #expect(result.notes == ["Policy “JD - Maintenance” has Fix Disk Permissions turned on. Jamf Pro 11.34 and later no longer offer it, so a Preview for a tenant on those versions stops until it is turned off."])
    }

    @Test func signingOffLeavesOutSigningAndTheCertificate() {
        for certificate in ["  developer_certificate = null", emptyCertificate] {
            let result = RetiredSettings.cleaned(enrollmentSettings(signing: false, certificate: certificate))
            #expect(!result.text.contains("sign_quickadd_package"))
            #expect(!result.text.contains("developer_certificate"))
            // The MDM signing certificate is a different setting and stays.
            #expect(result.text.contains(#"keystore_file      = filebase64("files/mdm.p12")"#))
            #expect(result.text.contains("signing_mdm_profile_enabled"))
            #expect(result.notes.isEmpty)
        }
    }

    @Test func signingOnWithoutACertificateKeepsSigningWithANote() {
        let result = RetiredSettings.cleaned(enrollmentSettings(signing: true, certificate: emptyCertificate))
        #expect(result.text.contains("sign_quickadd_package                          = true"))
        #expect(!result.text.contains("developer_certificate"))
        #expect(result.text.contains("mdm_signing_certificate"))
        #expect(result.notes.count == 1)
        #expect(result.notes.first?.contains("turn signing off without one") == true)
    }

    @Test func signingOnWithACertificateKeepsBoth() {
        let certificate = """
              developer_certificate = {
                keystore_file                = filebase64("files/developer.p12")
                keystore_password            = var.developer_keystore_password
                keystore_password_wo_version = 1
              }
            """
        let result = RetiredSettings.cleaned(enrollmentSettings(signing: true, certificate: certificate))
        #expect(result.text.contains("developer_certificate"))
        #expect(result.text.contains("files/developer.p12"))
    }

    @Test func otherObjectsStayExactlyAsTheyWere() {
        let text = """
        resource "jamfplatform_pro_category" "ops" {
          name     = "Ops"
          priority = 9
        }
        """
        #expect(RetiredSettings.cleaned(text).text == text)
    }

    @Test func captureLeavesOutFixDiskPermissionsWhenOff() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "retired-src-\(UUID().uuidString)")
        let catalog = FileManager.default.temporaryDirectory.appending(path: "retired-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: catalog) }
        try Data((policy(fixDiskPermissions: false) + "\n").utf8).write(to: source.appending(path: "pro_policy.tf"))
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "maintenance", name: "Maintenance", summary: "", namePrefix: "",
            sourceDirectory: source, catalogRootDirectory: catalog))
        let text = try String(contentsOf: result.blockFolderURL.appending(path: "pro_policy.tf"), encoding: .utf8)
        #expect(!text.contains("fix_disk_permissions"))
        #expect(text.contains("update_inventory"))
        #expect(!result.warnings.contains { $0.contains("Fix Disk Permissions") })
    }

    @Test func adoptCleansEveryFileAndReportsOnSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "retired-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data((policy(fixDiskPermissions: true) + "\n").utf8).write(to: directory.appending(path: "pro_policy.tf"))
        try Data((enrollmentSettings(signing: false, certificate: emptyCertificate) + "\n").utf8)
            .write(to: directory.appending(path: "pro_user_initiated_enrollment_settings.tf"))
        let notes = try RetiredSettings.clean(directory: directory)
        #expect(notes.count == 1)
        let settings = try String(contentsOf: directory.appending(path: "pro_user_initiated_enrollment_settings.tf"), encoding: .utf8)
        #expect(!settings.contains("sign_quickadd_package"))
        #expect(!settings.contains("developer_certificate"))
    }
}
