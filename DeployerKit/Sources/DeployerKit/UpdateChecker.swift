import Foundation

/// Where an app's releases are published. Updates come from GitHub Releases
/// over HTTPS; the app itself is signed and notarized.
public nonisolated struct UpdateFeed: Sendable {
    public var owner: String
    public var repository: String
    /// The app's user-facing name, used in update messages.
    public var appName: String

    public init(owner: String, repository: String, appName: String) {
        self.owner = owner
        self.repository = repository
        self.appName = appName
    }

    var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }
}

/// A published release with a downloadable .zip asset.
public nonisolated struct AppRelease: Sendable {
    public var version: String
    public var notesMarkdown: String
    public var zipAssetURL: URL
    public var pageURL: URL
    public var zipAssetName: String
}

/// Checks GitHub Releases for a newer version. Carried over from Intune
/// Deployer: at most one automatic check per 24 hours, silent failures on
/// the automatic path, and a release is only offered automatically once.
@Observable
public final class UpdateChecker {
    public enum Status {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public var isPresented = false

    private let feed: UpdateFeed
    private let currentVersion: String
    private let defaults: UserDefaults

    public init(
        feed: UpdateFeed,
        currentVersion: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.feed = feed
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        self.defaults = defaults
    }

    public var appName: String { feed.appName }
    public var installedVersion: String { currentVersion }

    /// Automatic launch-time check: respects the `checksForUpdates` setting,
    /// runs at most once every 24 hours, fails silently, and only presents a
    /// release it has not offered before.
    public func checkAutomatically() async {
        if defaults.object(forKey: "checksForUpdates") != nil,
           !defaults.bool(forKey: "checksForUpdates") {
            return
        }
        if let last = defaults.object(forKey: "lastUpdateCheck") as? Date,
           Date.now.timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        defaults.set(Date.now, forKey: "lastUpdateCheck")
        do {
            let release = try await fetchLatest()
            if Self.isNewer(release.version, than: currentVersion),
               defaults.string(forKey: "lastOfferedUpdate") != release.version {
                defaults.set(release.version, forKey: "lastOfferedUpdate")
                status = .available(release)
                isPresented = true
            }
        } catch {
            // Silent on the automatic path.
        }
    }

    public func checkManually() {
        status = .checking
        isPresented = true
        Task {
            do {
                let release = try await fetchLatest()
                if Self.isNewer(release.version, than: currentVersion) {
                    status = .available(release)
                } else {
                    status = .upToDate
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async throws -> AppRelease {
        var request = URLRequest(url: feed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.feedUnavailable
        }

        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }

        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noDownloadableAsset
        }
        guard Self.isTrustedHost(zip.browser_download_url), Self.isTrustedHost(release.html_url) else {
            throw UpdateError.untrustedURL
        }
        var version = release.tag_name
        if version.hasPrefix("v") { version.removeFirst() }
        return AppRelease(
            version: version,
            notesMarkdown: release.body ?? "",
            zipAssetURL: zip.browser_download_url,
            pageURL: release.html_url,
            zipAssetName: zip.name
        )
    }

    nonisolated static func isTrustedHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    /// Dot-separated numeric comparison; missing components count as 0.
    public nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    public nonisolated enum UpdateError: LocalizedError {
        case feedUnavailable
        case noDownloadableAsset
        case untrustedURL

        public var errorDescription: String? {
            switch self {
            case .feedUnavailable:
                "The release feed could not be reached. Check your internet connection and try again."
            case .noDownloadableAsset:
                "The latest release has no downloadable app archive."
            case .untrustedURL:
                "The release points at an unexpected download location, so it was not offered."
            }
        }
    }
}
