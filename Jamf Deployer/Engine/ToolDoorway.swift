import Foundation
import JTKit
import os

/// The outside programs the app starts. Each talks to Jamf or to Git
/// itself, so none of them can run against demo mode's sample data.
nonisolated enum ExternalTool: String, Sendable, CaseIterable {
    case openTofu = "OpenTofu"
    case jamformer
    case stateBackend = "terraform-backend-git"
    case git = "Git"
}

/// The one doorway through which the app starts OpenTofu, jamformer, the
/// state backend and git: every launch asks it for its `Process`.
///
/// - The app's doorway (`.app`) refuses everything while demo mode is on,
///   and always refuses a launch that points at demo mode: its folder, a
///   demo address or a demo tenant's ID.
/// - Demo mode's doorway (`.demo`) refuses everything.
/// - A test's doorway (`trap(_:)`) reports every attempt and refuses it.
nonisolated final class ToolDoorway: Sendable {
    struct Refused: LocalizedError, Equatable {
        let tool: ExternalTool

        var errorDescription: String? {
            "This isn't available in Demo Mode: it needs \(tool.rawValue), which would reach Jamf or Git itself instead of the sample data."
        }
    }

    private enum Mode: Sendable {
        case real(isDemoOn: @Sendable () -> Bool)
        case demo
        case trap(@Sendable (ExternalTool) -> Void)
    }

    private let mode: Mode

    private init(_ mode: Mode) {
        self.mode = mode
    }

    /// Whether demo mode is on in the app; set by the switch.
    private static let demoSwitch = OSAllocatedUnfairLock(initialState: false)

    static func setDemoMode(_ isOn: Bool) {
        demoSwitch.withLock { $0 = isOn }
    }

    /// The app's real doorway.
    static let app = ToolDoorway(.real(isDemoOn: { demoSwitch.withLock { $0 } }))

    /// Demo mode's doorway: nothing is ever started.
    static let demo = ToolDoorway(.demo)

    /// A real doorway with its own switch, for tests.
    static func real(isDemoOn: @escaping @Sendable () -> Bool) -> ToolDoorway {
        ToolDoorway(.real(isDemoOn: isDemoOn))
    }

    /// For tests: `attempted` hears of every launch, which is then refused.
    static func trap(_ attempted: @escaping @Sendable (ExternalTool) -> Void) -> ToolDoorway {
        ToolDoorway(.trap(attempted))
    }

    var refusesEverything: Bool {
        switch mode {
        case .real(let isDemoOn): isDemoOn()
        case .demo, .trap: true
        }
    }

    /// The process for one launch of `tool`, or `Refused` before anything starts.
    func process(
        _ tool: ExternalTool,
        executable: URL,
        arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> Process {
        switch mode {
        case .trap(let attempted):
            attempted(tool)
            throw Refused(tool: tool)
        case .demo:
            throw Refused(tool: tool)
        case .real(let isDemoOn):
            if isDemoOn() || Self.pointsAtDemo(directory: directory, arguments: arguments, environment: environment) {
                throw Refused(tool: tool)
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        return process
    }

    /// A launch that would work on demo mode's files or tenants: its
    /// temporary folder, a `.demo.invalid` address or an ID in the fake range.
    static func pointsAtDemo(directory: URL?, arguments: [String], environment: [String: String]?) -> Bool {
        let texts = [directory?.path ?? ""] + arguments + (environment.map { Array($0.values) } ?? [])
        return texts.contains { text in
            let lowered = text.lowercased()
            return lowered.contains("/jtkitdemo-") || lowered.contains("." + DemoNetwork.reservedDomain)
                || lowered.contains(DemoSamples.uuidPrefix)
        }
    }
}
