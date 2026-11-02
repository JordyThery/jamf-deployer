import Foundation

/// Enrollment customization icons are exported as URLs on the origin
/// tenant. Jamf cannot upload from those URLs directly, so after an export
/// each icon is downloaded next to the configuration and referenced as a
/// local file — captured blocks then carry their own copy.
///
/// The download itself is the app's (`fetch`: its logged networking), and
/// only from the origin tenant: an exported URL pointing anywhere else is
/// left alone, and the capture warns about it like any icon it couldn't get.
public nonisolated enum EnrollmentIcons {
    static let folder = "enrollment_customization_icons"

    /// Whether an icon URL may be downloaded: HTTPS on one of `allowedHosts`
    /// (lowercased; an entry starting with "." also allows its subdomains,
    /// e.g. ".jamfcloud.com").
    public static func mayDownload(_ url: URL, allowedHosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return allowedHosts.contains { allowed in
            let allowed = allowed.lowercased()
            return allowed.hasPrefix(".") ? host.hasSuffix(allowed) && host.count > allowed.count : host == allowed
        }
    }

    /// The hosts icons may come from for a tenant: Jamf Cloud for a Jamf
    /// Platform API tenant (no Jamf Pro address); for a Jamf Pro API tenant
    /// its own host, and Jamf Cloud too when it's hosted there, where Jamf
    /// serves the icons from its own Jamf Cloud services.
    public static func allowedHosts(jamfProURL: String?) -> Set<String> {
        guard let host = jamfProURL.flatMap({ URL(string: $0)?.host()?.lowercased() }), !host.isEmpty else {
            return [jamfCloud]
        }
        return host.hasSuffix(jamfCloud) ? [host, jamfCloud] : [host]
    }

    static let jamfCloud = ".jamfcloud.com"

    /// Downloads each enrollment customization icon through `fetch` (which
    /// returns the body of a 200 answer and throws otherwise) and points the
    /// configuration at the local copy. Returns the icon URLs left in place.
    @discardableResult
    public static func localize(
        directory: URL, allowedHosts: Set<String>, fetch: @Sendable (URL) async throws -> Data
    ) async -> [URL] {
        var leftInPlace: [URL] = []
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
                      let url = URL(string: String(icon.1))
                else { continue }
                guard mayDownload(url, allowedHosts: allowedHosts),
                      let data = try? await fetch(url), !data.isEmpty
                else {
                    leftInPlace.append(url)
                    continue
                }
                let relative = "\(folder)/\(header.1).png"
                let target = directory.appending(path: "support_files/\(relative)")
                do {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                } catch {
                    leftInPlace.append(url)
                    continue
                }
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
        return leftInPlace
    }
}
