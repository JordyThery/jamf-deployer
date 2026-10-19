import Foundation

/// Which connections a block folder can deploy through, and where its
/// module lives for each. A block's own folder holds its main module; a
/// `jamfpro/` subfolder holds a Jamf Pro API version of it with the same
/// variables and outputs. A main module that uses no Jamf Platform API
/// resources (Jamf Protect blocks) serves both connections.
public nonisolated enum BlockModule {
    public static let jamfProFolder = "jamfpro"

    public static func connections(ofBlockAt folder: URL) -> Set<ConnectionKind> {
        let root = sourceText(in: folder)
        var connections: Set<ConnectionKind> = []
        if !usesJamfPro(root) { connections.insert(.platform) }
        if !usesPlatform(root) || hasJamfProFolder(folder) { connections.insert(.jamfPro) }
        return connections
    }

    /// The module's path relative to the block folder ("" for the folder
    /// itself), or nil when the block cannot deploy through `connection`.
    public static func modulePath(ofBlockAt folder: URL, for connection: ConnectionKind) -> String? {
        switch connection {
        case .platform:
            return usesJamfPro(sourceText(in: folder)) ? nil : ""
        case .jamfPro:
            if hasJamfProFolder(folder) { return jamfProFolder }
            return usesPlatform(sourceText(in: folder)) ? nil : ""
        }
    }

    static func hasJamfProFolder(_ folder: URL) -> Bool {
        !sourceText(in: folder.appending(path: jamfProFolder)).isEmpty
    }

    static func usesPlatform(_ text: String) -> Bool {
        text.contains("jamf/jamfplatform") || text.contains(#""jamfplatform_"#)
    }

    static func usesJamfPro(_ text: String) -> Bool {
        text.contains("deploymenttheory/jamfpro") || text.contains(#""jamfpro_"#)
    }

    /// The concatenated .tf files directly in `folder`.
    static func sourceText(in folder: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "tf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
