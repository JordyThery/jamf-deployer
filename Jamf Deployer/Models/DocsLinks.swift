import Foundation

/// Links into the published documentation. The learning path's stage
/// headings are "Stage <n> — <title>"; GitHub anchors them as `stage-<n>--…`.
nonisolated enum DocsLinks {
    private static let base = "https://github.com/JordyThery/jamf-deployer/blob/main/docs/"

    static let graduating = URL(string: base + "graduating.md")!

    static func stage(_ number: Int) -> URL {
        let anchors = [
            0: "stage-0--what-you-already-know",
            1: "stage-1--watch-the-engine-work",
            2: "stage-2--run-one-tenant-yourself",
            3: "stage-3--many-tenants-git-and-reviews",
            4: "stage-4--run-a-fleet",
        ]
        return URL(string: base + "graduating.md#" + (anchors[number] ?? ""))!
    }
}
