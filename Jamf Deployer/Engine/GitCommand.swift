import Foundation

/// Runs `/usr/bin/git` once, through the doorway. The one place the app's git
/// launches are wired up: the store, catalog checkouts, the exported
/// repository and credential lookups all use it.
///
/// Input is written on its own thread while the output is read, so neither
/// side can block the other on a full pipe, and a git that exits before it
/// has read everything can't raise SIGPIPE in the app.
nonisolated enum GitCommand {
    struct Output: Sendable {
        var status: Int32
        /// Standard output, plus standard error unless it was discarded.
        var data: Data

        var text: String { String(decoding: data, as: UTF8.self) }
    }

    static let executableURL = URL(filePath: "/usr/bin/git")

    /// Blocks until git exits; call it off the main actor.
    /// - Parameters:
    ///   - discardsErrors: standard error goes nowhere instead of into `data`.
    static func run(
        _ arguments: [String],
        in directory: URL?,
        input: Data? = nil,
        discardsErrors: Bool = false,
        extraEnvironment: [String: String] = [:],
        tools: ToolDoorway
    ) throws -> Output {
        var environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { $1 }
        environment["GIT_TERMINAL_PROMPT"] = "0" // never hang on auth prompts
        let process = try tools.process(.git, executable: executableURL, arguments: arguments,
                                        directory: directory, environment: environment)
        return try run(process, input: input, discardsErrors: discardsErrors)
    }

    /// Runs a prepared process with the same pipe handling; tests use it with
    /// other executables.
    static func run(_ process: Process, input: Data?, discardsErrors: Bool = false) throws -> Output {
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = output
        process.standardError = discardsErrors ? FileHandle.nullDevice : output
        // A child that exits before reading all of its input must not raise
        // SIGPIPE here; the write then fails and the exit status says why.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        let writer = stdin.fileHandleForWriting
        let written = DispatchGroup()
        if let input {
            written.enter()
            Thread.detachNewThread {
                try? writer.write(contentsOf: input)
                try? writer.close()
                written.leave()
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        written.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: data)
    }
}
