import Foundation

/// Versions of the tools that ship inside the app. They only change with app
/// updates, never silently. `Vendor/fetch.sh` is where they are pinned; a unit
/// test keeps these equal to it.
nonisolated enum EngineInfo {
    static let openTofuVersion = "1.13.2"
    static let jamfPlatformProviderVersion = "1.6.0"
    static let jamfProtectProviderVersion = "0.12.0"
    static let jamfProProviderVersion = "0.42.0"
    static let jamformerVersion = "0.6.1"
    static let stateBackendVersion = "0.1.12"
}
