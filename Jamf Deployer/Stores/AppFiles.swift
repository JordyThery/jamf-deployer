import Foundation
import JTKit

/// Where the app keeps its own files: `~/Library/Application Support/Jamf
/// Deployer/…`, or, under JTKit's live-check switch (a release check's live
/// UI test), the run's `app-files/Jamf Deployer/…`, so a live run never
/// writes the real store, engine folders, caches or clones.
nonisolated enum AppFiles {
    /// The app's folder under Application Support, or the live run's.
    static var root: URL {
        LiveLaunch.appFilesFolder("Jamf Deployer")
            ?? URL.applicationSupportDirectory.appending(path: "Jamf Deployer", directoryHint: .isDirectory)
    }

    /// A path inside `root`, e.g. "engine/tofu.tfrc".
    static func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    /// The usual place, also under the switch: only for reading a file the
    /// app downloaded earlier (HashiCorp Terraform), never for writing.
    static func usualURL(_ relative: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Jamf Deployer").appending(path: relative)
    }
}
