import Foundation
import JamfDeployerCore

/// Runs the bundled OpenTofu binary as a child process and parses its
/// machine-readable JSON output.
///
/// One instance per tenant, so a tenant never has two runs at once.
/// Secrets are injected as environment variables only — never written to
/// disk and never logged.
actor EngineRunner {
    struct Configuration: Sendable {
        /// Path to the `tofu` binary.
        var engineURL: URL
        /// The tenant workspace's generated configuration directory.
        var workingDirectory: URL
        /// CLI config pointing provider installation at the bundled mirror.
        var cliConfigURL: URL
        /// Secret and non-secret environment (JAMFPLATFORM_*, TF_ENCRYPTION,
        /// TF_VAR_*). Never logged.
        var environment: [String: String]
    }

    /// Everything one engine run produced, available after it finishes.
    struct RunResult: Sendable {
        var exitCode: Int32
        var events: [EngineStreamEvent]
        /// Every stdout/stderr line, for history logs and technical details.
        var rawLines: [String]
        var errorDiagnostics: [EngineStreamEvent.Diagnostic]
    }

    enum EngineError: LocalizedError {
        case alreadyRunning
        /// Carries everything the run produced so partial successes are
        /// never lost (an apply can fail on one object after creating ten).
        case nonZeroExit(RunResult)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Another engine run for this tenant is still in progress."
            case .nonZeroExit(let result):
                // The engine's own error summary, else its first error line.
                if let diagnostic = result.errorDiagnostics.first {
                    return diagnostic.summary
                }
                let line = result.rawLines.first { $0.contains("Error:") }
                    ?? result.rawLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return line.map {
                    let text = EngineOutputCleaner.readableErrorPages(in: $0)
                    return "The engine stopped: \(text.replacing("│", with: "").trimmingCharacters(in: .whitespaces))"
                }
                    ?? "The engine stopped with exit code \(result.exitCode)."
            }
        }
    }

    private let configuration: Configuration
    private var currentProcess: Process?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Requests a graceful stop (a single SIGINT: OpenTofu finishes
    /// in-flight operations and releases its state lock).
    func cancel() {
        guard let process = currentProcess, process.isRunning else { return }
        process.interrupt()
    }

    /// Runs one engine command. Decoded events are collected into the result;
    /// `onEvent` is display-only live progress.
    @discardableResult
    func run(
        arguments: [String],
        onEvent: @Sendable (EngineStreamEvent) -> Void = { _ in }
    ) async throws -> RunResult {
        guard currentProcess == nil else { throw EngineError.alreadyRunning }

        let process = Process()
        process.executableURL = configuration.engineURL
        process.arguments = arguments
        process.currentDirectoryURL = configuration.workingDirectory

        var environment = configuration.environment
        environment["TF_CLI_CONFIG_FILE"] = configuration.cliConfigURL.path
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        // No stdin: a TTY here (dev runs from Xcode) switches child tools into
        // interactive mode and they block waiting for input.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let terminated = Self.installTerminationWait(process)
        try process.run()
        currentProcess = process
        defer { currentProcess = nil }

        let decoder = JSONDecoder()
        var events: [EngineStreamEvent] = []
        var rawLines: [String] = []
        var errorDiagnostics: [EngineStreamEvent.Diagnostic] = []

        // Drain stderr concurrently: a child that fills the stderr pipe
        // while stdout is still open would otherwise deadlock the run.
        let stderrHandle = stderr.fileHandleForReading
        let stderrTask = Task<[String], Never> {
            var lines: [String] = []
            for await line in Self.lines(from: stderrHandle) {
                lines.append(line)
            }
            return lines
        }

        for await line in Self.lines(from: stdout.fileHandleForReading) {
            rawLines.append(line)
            guard line.hasPrefix("{"),
                  let event = try? decoder.decode(EngineStreamEvent.self, from: Data(line.utf8))
            else { continue }
            events.append(event)
            if let diagnostic = event.diagnostic, diagnostic.severity == "error" {
                // a Classic API error page in it reads as its message
                errorDiagnostics.append(EngineOutputCleaner.readableErrorPages(in: diagnostic))
            }
            onEvent(event)
        }

        rawLines.append(contentsOf: await stderrTask.value)

        await Self.awaitTermination(terminated)
        let status = process.terminationStatus
        let result = RunResult(
            exitCode: status,
            events: events,
            rawLines: rawLines,
            errorDiagnostics: errorDiagnostics
        )
        if status != 0 {
            throw EngineError.nonZeroExit(result)
        }
        return result
    }

    /// Raw stdout of an engine command (schema dumps, `show -json` of the state).
    func rawCommandOutput(arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = configuration.engineURL
        process.arguments = arguments
        process.currentDirectoryURL = configuration.workingDirectory
        var environment = configuration.environment
        environment["TF_CLI_CONFIG_FILE"] = configuration.cliConfigURL.path
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment
        let stdout = Pipe()
        // No stdin: a TTY here (dev runs from Xcode) switches child tools into
        // interactive mode and they block waiting for input.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        let terminated = Self.installTerminationWait(process)
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        await Self.awaitTermination(terminated)
        return data
    }

    /// stdout of an engine command that must succeed, optionally fed `input`
    /// on stdin — used to move state between backends without writing it
    /// to disk (`state pull` / `state push -`).
    func checkedOutput(arguments: [String], input: Data? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = configuration.engineURL
        process.arguments = arguments
        process.currentDirectoryURL = configuration.workingDirectory
        var environment = configuration.environment
        environment["TF_CLI_CONFIG_FILE"] = configuration.cliConfigURL.path
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A child that exits before reading its input must not raise SIGPIPE
        // in the app; the write then fails and the exit status reports why.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let terminated = Self.installTerminationWait(process)
        try process.run()

        // Writing and both reads block, so each runs on its own thread:
        // a full pipe on any of them would otherwise stall the others.
        let writer = stdin.fileHandleForWriting
        let writeTask = Task.detached {
            if let input { try? writer.write(contentsOf: input) }
            try? writer.close()
        }
        let outputHandle = stdout.fileHandleForReading
        let errorHandle = stderr.fileHandleForReading
        let outputTask = Task.detached { outputHandle.readDataToEndOfFile() }
        let errorTask = Task.detached { errorHandle.readDataToEndOfFile() }
        await writeTask.value
        let data = await outputTask.value
        let errors = await errorTask.value
        await Self.awaitTermination(terminated)
        guard process.terminationStatus == 0 else {
            let lines = String(decoding: errors + data, as: UTF8.self).split(separator: "\n").map(String.init)
            throw EngineError.nonZeroExit(RunResult(
                exitCode: process.terminationStatus, events: [], rawLines: lines, errorDiagnostics: []))
        }
        return data
    }

    /// Raw `tofu show -json <planFile>` output.
    func showPlanData(planFileName: String) async throws -> Data {
        let process = Process()
        process.executableURL = configuration.engineURL
        process.arguments = ["show", "-json", planFileName]
        process.currentDirectoryURL = configuration.workingDirectory

        var environment = configuration.environment
        environment["TF_CLI_CONFIG_FILE"] = configuration.cliConfigURL.path
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment

        let stdout = Pipe()
        // No stdin: a TTY here (dev runs from Xcode) switches child tools into
        // interactive mode and they block waiting for input.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        let terminated = Self.installTerminationWait(process)
        try process.run()
        // Read fully before waiting, so a large plan cannot deadlock the pipe.
        let collected = stdout.fileHandleForReading.readDataToEndOfFile()
        await Self.awaitTermination(terminated)
        return collected
    }

    /// Decoded `tofu show -json <planFile>`.
    func showPlan(planFileName: String) async throws -> PlanFile {
        try JSONDecoder().decode(PlanFile.self, from: try await showPlanData(planFileName: planFileName))
    }

    /// Awaits child termination via the termination handler. `waitUntilExit`
    /// spins a runloop that can miss the notification on Swift-concurrency
    /// threads, hanging after the child has already exited.
    nonisolated static func installTerminationWait(_ process: Process) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            continuation.yield(())
            continuation.finish()
        }
        return stream
    }

    nonisolated static func awaitTermination(_ stream: AsyncStream<Void>) async {
        // Stream iteration ends early when the awaiting task is cancelled
        // (closing a sheet cancels its .task). Shield the wait so callers
        // never read terminationStatus from a still-running child.
        await Task { for await _ in stream { break } }.value
    }

    /// Lines from a pipe via readabilityHandler — deterministic, unlike
    /// FileHandle.bytes, whose iterator can fail to start consuming and
    /// leave the child blocked on a full pipe.
    nonisolated static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            nonisolated(unsafe) var buffer = Data()
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                        continuation.yield(line)
                    }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    buffer.removeSubrange(buffer.startIndex...newline)
                    continuation.yield(line)
                }
            }
        }
    }
}
