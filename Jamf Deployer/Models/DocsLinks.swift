import Foundation

/// Links into the published documentation. The learning path's stage
/// headings are "Stage <n> — <title>"; GitHub anchors them as `stage-<n>--…`.
nonisolated enum DocsLinks {
    private static let base = "https://github.com/JordyThery/jamf-deployer/blob/main/docs/"

    static let graduating = URL(string: base + "graduating.md")!

    static func stage(_ number: Int) -> URL {
        // Only the stages the app links to.
        let anchors = [
            1: "stage-1--watch-the-engine-work",
            3: "stage-3--many-tenants-git-and-reviews",
        ]
        return URL(string: base + "graduating.md#" + (anchors[number] ?? ""))!
    }
}
