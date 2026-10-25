import Foundation

/// What is left of DeployerKit's update checker: the version comparison that
/// `ComponentUpdateChecker` uses for the bundled engine and providers. The
/// app's own update check now comes from JTKit.
public nonisolated enum UpdateChecker {
    /// Dot-separated numeric comparison; missing components count as 0.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
