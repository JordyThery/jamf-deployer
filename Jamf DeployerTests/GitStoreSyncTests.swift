import Foundation
import Testing
import JamfDeployerCore
@testable import Jamf_Deployer

/// Git helpers for tests: throwaway repositories in the temporary folder,
/// with a local bare repository as the team space. Never the real store.
enum TestGit {
    static func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "jd-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        process.environment = environment
        let output = try GitCommand.run(process, input: nil)
        guard output.status == 0 else {
            throw GitStoreService.GitError.commandFailed(arguments.first ?? "", output: output.text)
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ text: String, to path: String, in directory: URL) throws {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// A bare "team space" and a store attached to it, plus a teammate's clone.
    static func teamSpace() async throws -> (store: GitStoreService, storeURL: URL, teammate: URL, root: URL) {
        let root = folder("team")
        let remote = root.appending(path: "remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try run(["init", "--bare", "--initial-branch", "main"], in: remote)
        let storeURL = root.appending(path: "store")
        let store = GitStoreService(storeURL: storeURL, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        try await store.attachRemote(remote.path)
        let teammate = root.appending(path: "teammate")
        try run(["clone", "-q", remote.path, teammate.path], in: root)
        return (store, storeURL, teammate, root)
    }

    static func isRebaseInProgress(_ repo: URL) -> Bool {
        let git = repo.appending(path: ".git")
        return FileManager.default.fileExists(atPath: git.appending(path: "rebase-merge").path)
            || FileManager.default.fileExists(atPath: git.appending(path: "rebase-apply").path)
    }
}

@Suite("Team sync in the store repository")
struct GitStoreSyncTests {
    static let recordPath = "tenants/00000000-0000-4000-9000-0000000000aa/tenant.json"

    @Test("Concurrent commits run one at a time, without index.lock collisions")
    func concurrentCommitsAreSerialized() async throws {
        let url = TestGit.folder("serial")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GitStoreService(storeURL: url, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                try TestGit.write("{\"n\": \(index)}\n", to: "tenants/t\(index)/tenant.json", in: url)
                group.addTask {
                    _ = try await store.commitAll(message: "Change \(index)")
                    _ = try await store.currentFindings()
                }
            }
            try await group.waitForAll()
        }
        #expect(try TestGit.run(["status", "--porcelain"], in: url).isEmpty)
        #expect(try TestGit.run(["ls-files"], in: url).split(separator: "\n").count(where: { $0.hasSuffix("tenant.json") }) == 12)
    }

    @Test("A pull that conflicts is undone: no markers, no rebase left, this Mac's commit kept")
    func conflictingPullIsAborted() async throws {
        let (store, storeURL, teammate, root) = try await TestGit.teamSpace()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestGit.write("{\"name\": \"base\"}\n", to: Self.recordPath, in: storeURL)
        try await store.sync(savingChangesAs: "Add tenant")

        // The teammate changes the record and publishes first.
        try TestGit.run(["pull", "-q", "origin", "main"], in: teammate)
        try TestGit.write("{\"name\": \"teammate\"}\n", to: Self.recordPath, in: teammate)
        try TestGit.run(["commit", "-qam", "Teammate edit"], in: teammate)
        try TestGit.run(["push", "-q", "origin", "main"], in: teammate)

        // This Mac changed the same record without committing.
        try TestGit.write("{\"name\": \"mine\"}\n", to: Self.recordPath, in: storeURL)
        await #expect {
            try await store.sync(savingChangesAs: "Update tenant")
        } throws: { error in
            guard case GitStoreService.GitError.syncConflict(let files) = error else { return false }
            return files == [Self.recordPath]
        }

        #expect(!TestGit.isRebaseInProgress(storeURL))
        #expect(try TestGit.run(["status", "--porcelain"], in: storeURL).isEmpty, "the store is clean")
        #expect(try TestGit.run(["log", "-1", "--format=%s"], in: storeURL) == "Update tenant", "at the pre-pull commit")
        let text = try String(contentsOf: storeURL.appending(path: Self.recordPath), encoding: .utf8)
        #expect(text == "{\"name\": \"mine\"}\n")
        #expect(!text.contains("<<<<<<<"))
        #expect(try TestGit.run(["stash", "list"], in: storeURL).isEmpty, "nothing was stashed")
        // The store itself stays healthy: the sync failure is what stops engine work.
        try await store.checkHealthy()
    }

    @Test("Unmerged files are never staged: commit and sync refuse")
    func unmergedEntriesStopTheCommit() async throws {
        let url = TestGit.folder("unmerged")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GitStoreService(storeURL: url, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        try TestGit.write("v1\n", to: Self.recordPath, in: url)
        _ = try await store.commitAll(message: "v1")
        // What an autostash that didn't apply leaves behind.
        try TestGit.write("v2\n", to: Self.recordPath, in: url)
        try TestGit.run(["stash", "-q"], in: url)
        try TestGit.write("v3\n", to: Self.recordPath, in: url)
        try TestGit.run(["commit", "-qam", "v3"], in: url)
        #expect(throws: (any Error).self) { try TestGit.run(["stash", "pop", "-q"], in: url) }
        let head = try TestGit.run(["rev-parse", "HEAD"], in: url)

        await #expect {
            try await store.commitAll(message: "Commit markers")
        } throws: { error in
            guard case GitStoreService.GitError.unfinishedMerge(let files) = error else { return false }
            return files == [Self.recordPath]
        }
        await #expect(throws: GitStoreService.GitError.self) { try await store.checkHealthy() }
        #expect(try TestGit.run(["rev-parse", "HEAD"], in: url) == head, "nothing was committed")
        #expect(try TestGit.run(["diff", "--name-only", "--diff-filter=U"], in: url) == Self.recordPath)
    }

    @Test("A rebase an earlier version left in progress is undone")
    func leftoverRebaseIsAborted() async throws {
        let url = TestGit.folder("rebase")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GitStoreService(storeURL: url, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        try TestGit.write("base\n", to: Self.recordPath, in: url)
        _ = try await store.commitAll(message: "base")
        try TestGit.run(["checkout", "-qb", "other"], in: url)
        try TestGit.write("other\n", to: Self.recordPath, in: url)
        try TestGit.run(["commit", "-qam", "other"], in: url)
        try TestGit.run(["checkout", "-q", "main"], in: url)
        try TestGit.write("main\n", to: Self.recordPath, in: url)
        try TestGit.run(["commit", "-qam", "main"], in: url)
        let head = try TestGit.run(["rev-parse", "HEAD"], in: url)
        #expect(throws: (any Error).self) { try TestGit.run(["rebase", "-q", "other"], in: url) }
        #expect(TestGit.isRebaseInProgress(url))

        try await store.checkHealthy()
        #expect(!TestGit.isRebaseInProgress(url))
        #expect(try TestGit.run(["rev-parse", "HEAD"], in: url) == head)
        #expect(try TestGit.run(["status", "--porcelain"], in: url).isEmpty)
    }

    @Test("Sync commits waiting changes and publishes them")
    func syncPublishes() async throws {
        let (store, storeURL, teammate, root) = try await TestGit.teamSpace()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestGit.write("{}\n", to: Self.recordPath, in: storeURL)
        try await store.sync(savingChangesAs: "Add tenant — Test")
        try TestGit.run(["pull", "-q", "origin", "main"], in: teammate)
        #expect(FileManager.default.fileExists(atPath: teammate.appending(path: Self.recordPath).path))
        #expect(try TestGit.run(["log", "-1", "--format=%s"], in: teammate) == "Add tenant — Test")
    }

    @Test("Team state and locks are read from refs that are deleted again")
    func stateBranchAndLocksLeaveNoRefs() async throws {
        let (store, storeURL, teammate, root) = try await TestGit.teamSpace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tenantID = UUID(uuidString: "00000000-0000-4000-9000-0000000000bb")!
        try await store.ensureStateBranch()
        // The state backend's layout: one state file per tenant, a lock branch per lock.
        try TestGit.run(["fetch", "-q", "origin", StateBackendService.stateBranch], in: teammate)
        try TestGit.run(["checkout", "-q", "-b", "state", "FETCH_HEAD"], in: teammate)
        try TestGit.write("{\"encrypted\": true}\n", to: "tenants/\(tenantID.uuidString)/terraform.tfstate", in: teammate)
        try TestGit.run(["add", "-A"], in: teammate)
        try TestGit.run(["commit", "-qm", "state"], in: teammate)
        try TestGit.run(["push", "-q", "origin", "state:\(StateBackendService.stateBranch)"], in: teammate)
        try TestGit.write("{\"ID\":\"lock-1\",\"Who\":\"alex@mac\",\"Operation\":\"OperationTypeApply\"}",
                          to: "tenants/\(tenantID.uuidString)/terraform.tfstate.lock", in: teammate)
        try TestGit.run(["add", "-A"], in: teammate)
        try TestGit.run(["commit", "-qm", "lock"], in: teammate)
        try TestGit.run(["push", "-q", "origin", "state:locks/tenants/\(tenantID.uuidString)/terraform.tfstate"], in: teammate)

        #expect(try await store.tenantIDsWithTeamState() == [tenantID])
        let locks = await store.stateLocks()
        #expect(locks[tenantID]?.lockID == "lock-1")
        #expect(locks[tenantID]?.engineer == "alex")
        #expect(try TestGit.run(["for-each-ref", GitStoreService.scratchRefs], in: storeURL).isEmpty)
    }

    @Test func batchOutputIsParsed() {
        let output = Data("aaa blob 5\nhello\nbbb missing\nccc blob 0\n\nddd blob 3\na\nb\n".utf8)
        let objects = GitStoreService.batchContents(output)
        #expect(objects.map(\.id) == ["aaa", "ccc", "ddd"])
        #expect(objects.map { String(decoding: $0.data, as: UTF8.self) } == ["hello", "", "a\nb"])
    }

    @Test func stateListingIsParsed() {
        let id = UUID(uuidString: "00000000-0000-4000-9000-0000000000cc")!
        let listing = "README.md\ntenants/\(id.uuidString)/terraform.tfstate\ntenants/not-a-uuid/terraform.tfstate\n"
        #expect(GitStoreService.tenantIDs(inStateListing: listing) == [id])
    }

    @Test("An unchanged ignore file isn't rewritten on every sync")
    func ignoreFileIsLeftAlone() async throws {
        let url = TestGit.folder("ignore")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GitStoreService(storeURL: url, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        let file = url.appending(path: ".gitignore")
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        try await store.ensureRepo()
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(modified == past)
    }

    @Test("The one-time check reads thousands of earlier objects without blocking", .timeLimit(.minutes(2)))
    func fullCheckOnALargeHistory() async throws {
        let url = TestGit.folder("large")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GitStoreService(storeURL: url, tools: .real(isDemoOn: { false }))
        try await store.ensureRepo()
        // 3,000 objects only in an earlier version: more than a pipe holds,
        // both as input and as output.
        let folder = url.appending(path: "tenants/history-test/history")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3_000 {
            try Data("{\"entry\": \(index)}\n".utf8).write(to: folder.appending(path: "e\(index).json"))
        }
        _ = try await store.commitAll(message: "Many")
        try FileManager.default.removeItem(at: folder)
        _ = try await store.commitAll(message: "Removed")
        #expect(try await store.fullCheck().isEmpty)
    }
}

@Suite("Git and engine pipes")
struct PipeTests {
    @Test("Input larger than a pipe comes back whole", .timeLimit(.minutes(1)))
    func largeInputRoundTrips() throws {
        let input = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cat")
        let output = try GitCommand.run(process, input: input)
        #expect(output.status == 0)
        #expect(output.data == input)
    }

    @Test("A child that exits without reading its input doesn't take the app down")
    func earlyExitIsSurvived() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        let output = try GitCommand.run(process, input: Data(count: 1_000_000))
        #expect(output.status == 0)
    }

    /// A stand-in for the engine: a script in a temporary folder.
    static func fakeEngine(_ script: String) throws -> (EngineRunner, URL) {
        let folder = TestGit.folder("engine")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = folder.appending(path: "tofu")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let config = folder.appending(path: "tofu.tfrc")
        try Data().write(to: config)
        let runner = EngineRunner(configuration: EngineRunner.Configuration(
            engineURL: engine, workingDirectory: folder, cliConfigURL: config,
            environment: [:], tools: .real(isDemoOn: { false })))
        return (runner, folder)
    }

    @Test("Engine input larger than a pipe", .timeLimit(.minutes(1)))
    func engineInputRoundTrips() async throws {
        let (runner, folder) = try Self.fakeEngine("cat")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = Data(repeating: 0x41, count: 800_000)
        #expect(try await runner.checkedOutput(arguments: ["state", "push", "-"], input: input) == input)
    }

    @Test("A failed `show -json` throws with its error output instead of half an answer")
    func rawOutputChecksTheExitStatus() async throws {
        let (runner, folder) = try Self.fakeEngine("echo '{\"partial\"'; echo 'Error: state locked' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect {
            _ = try await runner.rawCommandOutput(arguments: ["show", "-json"])
        } throws: { error in
            guard case EngineRunner.EngineError.nonZeroExit(let result) = error else { return false }
            return result.exitCode == 1 && result.rawLines.contains("Error: state locked")
        }
        #expect(!TenantDeployService.isReadableState(Data("{\"partial\"".utf8)))
        #expect(!TenantDeployService.isReadableState(Data()))
        #expect(TenantDeployService.isReadableState(Data("{\"format_version\":\"1.0\"}".utf8)))
    }

    @Test("The engine gets a PATH for `show -json` too")
    func rawOutputHasAPath() async throws {
        let (runner, folder) = try Self.fakeEngine("printf '%s' \"$PATH\"")
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try await runner.rawCommandOutput(arguments: ["show", "-json"])
        #expect(String(decoding: output, as: UTF8.self) == "/usr/bin:/bin")
    }
}
