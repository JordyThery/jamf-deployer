import Foundation

/// Settings Jamf Pro 11.34 retired, which jamfplatform 1.10.0 deprecates
/// (removal not before 2027-02-15): a policy's Fix Disk Permissions, and
/// QuickAdd package signing with its developer certificate in the
/// user-initiated enrollment settings. Exports write them out whatever their
/// value, and the plugin warns whenever one is set, even to false.
///
/// Turned off, they are left out of captured and adopted code: the plugin
/// then keeps the value Jamf reports, so nothing changes. Turned on, they
/// stay (older Jamf Pro versions still honor them) with a note, because the
/// plugin refuses them at plan time on Jamf Pro 11.34 and later. A developer
/// certificate is left out when signing is off or the export holds no
/// keystore file, which Jamf never exports.
public nonisolated enum RetiredSettings {
    static let policyType = "jamfplatform_pro_policy"
    static let enrollmentSettingsType = "jamfplatform_pro_user_initiated_enrollment_settings"

    /// The text with retired settings that are off left out, and a note for
    /// each object that has one turned on.
    public static func cleaned(_ text: String) -> (text: String, notes: [String]) {
        guard text.contains("resource \"\(policyType)\"") || text.contains("resource \"\(enrollmentSettingsType)\"")
        else { return (text, []) }
        var notes: [String] = []
        let blocks = ExportedObjectInventory.topLevelBlocks(in: text).map { block -> String in
            if block.hasPrefix("resource \"\(policyType)\"") {
                if block.range(of: #"\n\s*fix_disk_permissions\s*=\s*true\s*\n"#, options: .regularExpression) != nil {
                    notes.append("Policy “\(objectName(in: block))” has Fix Disk Permissions turned on. Jamf Pro 11.34 and later no longer offer it, so a Preview for a tenant on those versions stops until it is turned off.")
                }
                return removingLines(matching: #"^\s*fix_disk_permissions\s*=\s*false\s*$"#, from: block)
            }
            if block.hasPrefix("resource \"\(enrollmentSettingsType)\"") {
                var block = block
                let signing = block.range(of: #"\n  sign_quickadd_package\s*=\s*true\s*\n"#, options: .regularExpression) != nil
                if !signing || !hasKeystoreFile(in: block) {
                    block = removingLines(matching: #"^  developer_certificate\s*=\s*null\s*$"#, from: block)
                    block = BlockCapture.strippingAttributeObject(named: "developer_certificate", from: block)
                }
                if signing {
                    notes.append("The user-initiated enrollment settings sign the QuickAdd package. Jamf doesn’t export the developer certificate, and Jamf Pro 11.34 and later turn signing off without one, so a Preview for a tenant on those versions stops until signing is turned off.")
                }
                return removingLines(matching: #"^  sign_quickadd_package\s*=\s*false\s*$"#, from: block)
            }
            return block
        }
        return (blocks.joined(separator: "\n\n") + "\n", notes)
    }

    /// `cleaned(_:)` for every configuration file in an export.
    public static func clean(directory: URL) throws -> [String] {
        var notes: [String] = []
        for file in try ExportedObjectInventory.configurationFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let result = cleaned(text)
            notes += result.notes
            if result.text != text {
                try Data(result.text.utf8).write(to: file)
            }
        }
        return notes
    }

    /// Whether the developer certificate object sets a keystore file (the
    /// MDM signing certificate has one of its own, so only this object counts).
    private static func hasKeystoreFile(in block: String) -> Bool {
        guard let object = block.firstMatch(of: /(?s)\n  developer_certificate\s*=\s*\{(.*?)\n  \}/) else { return false }
        return String(object.1).range(of: #"\n\s*keystore_file\s*=\s*(?!null\b)\S"#, options: .regularExpression) != nil
    }

    private static func objectName(in block: String) -> String {
        block.firstMatch(of: /\n  name\s*=\s*"([^"]*)"/).map { String($0.1) } ?? "unnamed"
    }

    private static func removingLines(matching pattern: String, from block: String) -> String {
        block.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.range(of: pattern, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }
}
