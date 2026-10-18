import Foundation

/// Enrollment customization icons are exported as URLs on the origin
/// tenant. Jamf cannot upload from those URLs directly, so after an export
/// each icon is downloaded next to the configuration and referenced as a
/// local file — captured blocks then carry their own copy.
public nonisolated enum EnrollmentIcons {
    static let folder = "enrollment_customization_icons"

    public static func localize(directory: URL, session: URLSession = .shared) async {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "tf" && !file.lastPathComponent.hasSuffix("_import.tf") {
            guard var text = try? String(contentsOf: file, encoding: .utf8),
                  text.contains("resource \"jamfplatform_pro_enrollment_customization\"") else { continue }
            var changed = false
            var blocks = ExportedObjectInventory.topLevelBlocks(in: text)
            for index in blocks.indices {
                let block = blocks[index]
                guard let header = block.firstMatch(of: /^resource\s+"jamfplatform_pro_enrollment_customization"\s+"([A-Za-z0-9_-]+)"/),
                      let icon = block.firstMatch(of: /\n\s*icon_url\s*=\s*"(https:\/\/[^"]+)"/),
                      let url = URL(string: String(icon.1)),
                      let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
                else { continue }
                let relative = "\(folder)/\(header.1).png"
                let target = directory.appending(path: "support_files/\(relative)")
                do {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                } catch { continue }
                var updated = block
                updated.removeSubrange(icon.range)
                if let branding = updated.range(of: "\n  branding_settings = {") {
                    updated.insert(contentsOf: "\n  icon_source = \"${path.module}/support_files/\(relative)\"\n", at: branding.lowerBound)
                    blocks[index] = updated
                    changed = true
                }
            }
            if changed {
                text = blocks.joined(separator: "\n\n") + "\n"
                try? Data(text.utf8).write(to: file)
            }
        }
    }
}
