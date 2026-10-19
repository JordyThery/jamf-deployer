import Foundation

/// Publishes an exported Terraform repository: its first commit to an empty
/// remote, plus an empty state branch for the state backend to write to.
/// Git authentication is the user's own (git, gh or SSH); nothing is stored.
nonisolated enum RepositoryPublisher {
    /// The branch the exported workflows keep state on.
    static let stateBranch = "terraform-state"

    enum PublishError: LocalizedError {
        case git(String, output: String)

        var errorDescription: String? {
            switch self {
            case .git(let step, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Git could not \(step)\(detail.isEmpty ? "." : ": \(detail.prefix(300))")"
            }
        }
    }

    /// Commits `directory` and pushes it as main of the empty `remote`, then
    /// creates the state branch there.
    static func publish(_ directory: URL, to remote: String) async throws {
        try await Task.detached {
            try git(directory, "create the repository", "init", "--initial-branch", "main")
            if ((try? git(directory, "read the identity", "config", "user.email")) ?? "").isEmpty {
                try git(directory, "set an identity", "config", "user.name", "Jamf Deployer")
                try git(directory, "set an identity", "config", "user.email", "jamf-deployer@localhost")
            }
            try git(directory, "stage the files", "add", "-A")
            try git(directory, "commit", "commit", "-q", "-m", "Export from Jamf Deployer")
            try git(directory, "add the remote", "remote", "add", "origin", remote)
            try git(directory, "push to the repository (it must be empty and yours to push to)", "push", "-q", "-u", "origin", "main")
            let tree = try git(directory, "create the state branch", "mktree", input: "")
            let commit = try git(directory, "create the state branch", "commit-tree", tree, "-m", "Create the state branch")
            try git(directory, "push the state branch", "push", "-q", "origin", "\(commit):refs/heads/\(stateBranch)")
        }.value
    }

    @discardableResult
    private static func git(_ directory: URL, _ step: String, _ arguments: String..., input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = output
        process.standardError = output
        try process.run()
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw PublishError.git(step, output: text) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
