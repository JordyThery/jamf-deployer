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
    func export(
        tenant: Tenant,
        clientSecret: String,
        provider: String = "jamfplatform",
        includeResources: [String],
        includePackageFiles: Bool,
        skipImportBlocks: Bool = false,
        terraformPath: String
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

        var result = try await run(arguments: arguments, environment: environment)
        result.outputURL = outputURL
        return result
    }

    private func run(arguments: [String], environment: [String: String]) async throws -> ExportResult {
        let process = Process()
        process.executableURL = jamformerURL
        process.arguments = arguments

        var fullEnvironment = environment
        fullEnvironment["HOME"] = NSHomeDirectory()
        fullEnvironment["PATH"] = "/usr/bin:/bin"
        process.environment = fullEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Drain stderr concurrently so neither pipe can fill and deadlock.
        let stderrHandle = stderr.fileHandleForReading
        let stderrTask = Task<[String], Never> {
            var collected: [String] = []
            do {
                for try await line in stderrHandle.bytes.lines {
                    collected.append(line)
                }
            } catch {}
            return collected
        }

        var lines: [String] = []
        for try await line in stdout.fileHandleForReading.bytes.lines {
            lines.append(stripANSI(line))
        }
        lines.append(contentsOf: await stderrTask.value.map(stripANSI))
        process.waitUntilExit()

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

    private nonisolated func stripANSI(_ line: String) -> String {
        line.replacingOccurrences(of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
    }
}
