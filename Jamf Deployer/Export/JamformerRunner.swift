import Foundation
import DeployerKit

/// Runs the bundled jamformer as a child process for Export, Adopt and
/// Clone. Credentials go in as environment variables only; the secret scan
/// is never skipped and its findings are surfaced in the app.
actor JamformerRunner {
    struct ResourceType: Sendable, Identifiable, Hashable {
        /// The -include-resources filter key (e.g. "policy").
        var filterKey: String
        /// The Terraform type (e.g. "jamfplatform_pro_policy").
        var terraformType: String
        var id: String { filterKey }
    }

    struct ExportResult: Sendable {
        var outputURL: URL
        var logLines: [String]
        /// Lines the secret scan reported (empty = clean).
        var secretFindings: [String]
        var exitCode: Int32
    }

    private let jamformerURL: URL

    init() {
        self.jamformerURL = EngineLocator.locateTool("Vendor/jamformer/jamformer")
    }

    /// Object types the exporter supports, for the checklist UI.
    func listResourceTypes(provider: String) async throws -> [ResourceType] {
        let output = try await run(
            arguments: ["-skip-update-check", "-list-resources", "-provider", provider],
            environment: [:]
        )
        var types: [ResourceType] = []
        for line in output.logLines {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2,
                  columns[1].hasPrefix("jamfplatform_") || columns[1].hasPrefix("jamfprotect_"),
                  !line.contains("FILTER KEY")
            else { continue }
            types.append(ResourceType(filterKey: String(columns[0]), terraformType: String(columns[1])))
        }
        return types
    }

    /// Exports the chosen object types into a fresh temp folder.
    /// `onLine` receives each output line as it happens, for live progress.
    func export(
        tenant: Tenant,
        clientSecret: String,
        provider: String = "jamfplatform",
        includeResources: [String],
        includePackageFiles: Bool,
        skipImportBlocks: Bool = false,
        terraformPath: String,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ExportResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "jamf-deployer-export-\(UUID().uuidString)")

        var arguments = [
            "-skip-update-check",
            "-provider", provider,
            "-include-resources", includeResources.joined(separator: " "),
            "-terraform-path", terraformPath,
            "-output", outputURL.path,
        ]
        if !includePackageFiles {
            arguments.append("-skip-package-downloads")
        }
        if skipImportBlocks {
            arguments.append("-skip-import-blocks")
        }

        var environment: [String: String]
        if provider == "jamfprotect" {
            // Protect exports authenticate against the Protect console.
            environment = [
                "JAMF_URL": tenant.protectURL ?? "",
                "JAMF_CLIENT_ID": tenant.protectClientID ?? "",
                "JAMF_CLIENT_SECRET": clientSecret,
            ]
        } else {
            environment = [
                "JAMF_URL": tenant.region.gatewayURL.absoluteString,
                "JAMF_CLIENT_ID": tenant.clientID,
                "JAMF_CLIENT_SECRET": clientSecret,
            ]
            switch tenant.apiScope {
            case .environment: environment["JAMF_ENVIRONMENT_ID"] = tenant.scopeID
            case .tenant: environment["JAMF_TENANT_ID"] = tenant.scopeID
            }
        }

        var result = try await run(arguments: arguments, environment: environment, onLine: onLine)
        result.outputURL = outputURL

        // The exporter always runs a search phase, but settings-style types
        // have nothing to search; a selection with only those fails with
        // "No resources to query". Retry with a small searchable helper type
        // and drop its files from the result.
        if result.exitCode != 0,
           provider != "jamfprotect",
           !includeResources.contains("category"),
           let events = try? String(contentsOf: outputURL.appending(path: "query_events.json"), encoding: .utf8),
           events.contains("No resources to query") {
            onLine?("The selected types have no searchable objects — retrying with a helper type.")
            let retryURL = FileManager.default.temporaryDirectory
                .appending(path: "jamf-deployer-export-\(UUID().uuidString)")
            var retryArguments = arguments
            if let index = retryArguments.firstIndex(of: "-include-resources") {
                retryArguments[index + 1] = (includeResources + ["category"]).joined(separator: " ")
            }
            if let index = retryArguments.firstIndex(of: "-output") {
                retryArguments[index + 1] = retryURL.path
            }
            try? FileManager.default.removeItem(at: outputURL)
            result = try await run(arguments: retryArguments, environment: environment, onLine: onLine)
            result.outputURL = retryURL
            for file in ["pro_category.tf", "pro_category_import.tf"] {
                try? FileManager.default.removeItem(at: retryURL.appending(path: file))
            }
        }
        return result
    }

    private func run(
        arguments: [String],
        environment: [String: String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ExportResult {
        let process = Process()
        process.executableURL = jamformerURL
        process.arguments = arguments

        var fullEnvironment = environment
        fullEnvironment["HOME"] = NSHomeDirectory()
        fullEnvironment["PATH"] = "/usr/bin:/bin"
        process.environment = fullEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        // No stdin: a TTY here (dev runs from Xcode) switches child tools into
        // interactive mode and they block waiting for input.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let terminated = EngineRunner.installTerminationWait(process)
        try process.run()

        // Drain stderr concurrently so neither pipe can fill and deadlock —
        // and stream it: the exporter reports errors there.
        let stderrHandle = stderr.fileHandleForReading
        let stderrTask = Task<[String], Never> {
            var collected: [String] = []
            for await line in EngineRunner.lines(from: stderrHandle) {
                let clean = Self.stripTerminalNoise(line)
                guard !clean.isEmpty else { continue }
                collected.append(clean)
                onLine?(clean)
            }
            return collected
        }

        var lines: [String] = []
        for await line in EngineRunner.lines(from: stdout.fileHandleForReading) {
            let clean = Self.stripTerminalNoise(line)
            guard !clean.isEmpty else { continue }
            lines.append(clean)
            onLine?(clean)
        }
        lines.append(contentsOf: await stderrTask.value)
        await EngineRunner.awaitTermination(terminated)

        // The gitleaks-based scan is always on; collect what it reported.
        var findings: [String] = []
        var inFindings = false
        for line in lines {
            let lowered = line.lowercased()
            if lowered.contains("secret") && (lowered.contains("detected") || lowered.contains("found")) {
                if lowered.contains("no secrets") {
                    inFindings = false
                } else {
                    inFindings = true
                    findings.append(line.trimmingCharacters(in: .whitespaces))
                    continue
                }
            }
            if inFindings {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { inFindings = false } else { findings.append(trimmed) }
            }
        }

        return ExportResult(
            outputURL: URL(filePath: "/"),
            logLines: lines,
            secretFindings: findings,
            exitCode: process.terminationStatus
        )
    }

    /// Removes terminal control sequences and progress-bar junk. The
    /// exporter renders animated progress with full CSI sequences (cursor
    /// movement, 24-bit colors) and carriage-return redraws; after
    /// stripping, pure drawing lines reduce to nothing and are dropped.
    nonisolated static func stripTerminalNoise(_ line: String) -> String {
        var text = line
        // Complete CSI sequences, any final byte (colors, cursor, erase).
        text = text.replacingOccurrences(
            of: #"\u{1B}\[[0-9;?]*[@-~]"#, with: "", options: .regularExpression)
        // Orphaned sequence bodies whose ESC byte was lost in line splitting.
        text = text.replacingOccurrences(
            of: #"\[\?[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\[[0-9]{1,3}(;[0-9]{1,3})*[a-zA-Z]"#, with: "", options: .regularExpression)
        // Stray escapes and carriage returns.
        text = text.replacingOccurrences(of: "\u{1B}", with: "")
        text = text.replacingOccurrences(of: "\r", with: " ")
        // Progress bars reduce to box-drawing glyphs and whitespace.
        let drawing = text.unicodeScalars.allSatisfy {
            $0.properties.isWhitespace || ($0.value >= 0x2500 && $0.value <= 0x259F)
        }
        if drawing { return "" }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
