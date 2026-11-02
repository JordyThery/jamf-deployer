import Foundation

/// Finds the bundled engine, provider mirror and catalog. Release builds use
/// the app bundle; during development everything resolves from the repo the
/// source was built from.
nonisolated enum EngineLocator {
    #if DEBUG
    /// The repo root, derived from this source file's compile-time path.
    /// Development fallback only: release builds don't carry the path.
    private static var repoRootURL: URL? {
        URL(filePath: #filePath)                 // …/Jamf Deployer/Engine/EngineLocator.swift
            .deletingLastPathComponent()         // …/Jamf Deployer/Engine
            .deletingLastPathComponent()         // …/Jamf Deployer (app folder)
            .deletingLastPathComponent()         // repo root
    }
    #else
    private static var repoRootURL: URL? { nil }
    #endif

    private static func locate(_ relativePath: String) -> URL {
        let bundled = Bundle.main.resourceURL?.appending(path: relativePath)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // A release build always has its resources; a missing one stays
        // missing (callers report it) instead of pointing elsewhere.
        return repoRootURL?.appending(path: relativePath)
            ?? bundled
            ?? URL(filePath: "/nonexistent").appending(path: relativePath)
    }

    static var tofuURL: URL {
        locate("Vendor/opentofu/bin/tofu")
    }

    /// Generic lookup for other bundled tools (jamformer).
    static func locateTool(_ relativePath: String) -> URL {
        locate(relativePath)
    }

    static var providerMirrorURL: URL {
        locate("Vendor/providers")
    }

    static var catalogURL: URL {
        locate("Catalog")
    }

    /// The pipeline files a standalone Terraform export ships with.
    static var exportTemplatesURL: URL {
        locate("Templates/standalone-export")
    }

    /// Writes the engine CLI configuration pointing
    /// provider installation at the bundled mirror, so init never downloads.
    static func ensureCLIConfig() throws -> URL {
        let url = AppFiles.url("engine/tofu.tfrc")
        let contents = """
        provider_installation {
          filesystem_mirror {
            path    = "\(providerMirrorURL.path)"
            include = ["registry.opentofu.org/*/*"]
          }
          direct {
            exclude = ["registry.opentofu.org/*/*"]
          }
        }
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }
}
