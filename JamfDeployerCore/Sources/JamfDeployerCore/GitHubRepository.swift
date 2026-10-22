import Foundation

/// A repository on github.com, read from any of the remote URL forms Git
/// accepts: `https://github.com/owner/name(.git)` and `git@github.com:owner/name(.git)`.
public nonisolated struct GitHubRepository: Sendable, Equatable {
    public var owner: String
    public var name: String

    public init?(remote: String) {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if let match = text.wholeMatch(of: /git@github\.com:(.+)/) {
            path = match.1
        } else if let url = URLComponents(string: text), url.host?.lowercased() == "github.com",
                  ["https", "http", "ssh"].contains(url.scheme?.lowercased() ?? "") {
            path = Substring(url.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        var name = String(parts[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        owner = String(parts[0])
        self.name = name
    }

    /// The repository's page.
    public var webURL: URL {
        URL(string: "https://github.com/\(owner)/\(name)")!
    }

    /// A Markdown status badge linking to one of the repository's workflows.
    public func badge(title: String, workflow: String) -> String {
        let runs = "\(webURL.absoluteString)/actions/workflows/\(workflow)"
        return "[![\(title)](\(runs)/badge.svg)](\(runs))"
    }
}
