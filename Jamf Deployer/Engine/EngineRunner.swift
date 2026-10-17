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

    enum EngineError: Error {
        case alreadyRunning
        /// Carries everything the run produced so partial successes are
        /// never lost (an apply can fail on one object after creating ten).
        case nonZeroExit(RunResult)
    }

    private let configuration: Configuration
    private var currentProcess: Process?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Requests a graceful stop (single SIGINT, OpenTofu finishes in-flight
    /// operations). A force kill is a separate, second user action.
    func cancel(force: Bool = false) {
        guard let process = currentProcess, process.isRunning else { return }
        if force {
            process.terminate()
        } else {
            process.interrupt()
        }
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
        process.standardOutput = stdout
        process.standardError = stderr

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
            do {
                for try await line in stderrHandle.bytes.lines {
                    lines.append(line)
                }
            } catch {
                // Partial stderr is still useful; ignore read errors.
            }
            return lines
        }

        for try await line in stdout.fileHandleForReading.bytes.lines {
            rawLines.append(line)
            guard line.hasPrefix("{"),
                  let event = try? decoder.decode(EngineStreamEvent.self, from: Data(line.utf8))
            else { continue }
            events.append(event)
            if let diagnostic = event.diagnostic, diagnostic.severity == "error" {
                errorDiagnostics.append(diagnostic)
            }
            onEvent(event)
        }

        rawLines.append(contentsOf: await stderrTask.value)

        process.waitUntilExit()
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

    /// Raw stdout of an arbitrary engine command (schema dumps).
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
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
        process.standardOutput = stdout
        try process.run()
        // Read fully before waiting, so a large plan cannot deadlock the pipe.
        let collected = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return collected
    }

    /// Decoded `tofu show -json <planFile>`.
    func showPlan(planFileName: String) async throws -> PlanFile {
        try JSONDecoder().decode(PlanFile.self, from: try await showPlanData(planFileName: planFileName))
    }
}
