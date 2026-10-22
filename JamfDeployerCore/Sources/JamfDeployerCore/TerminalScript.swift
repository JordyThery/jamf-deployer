import Foundation

/// The `plan.sh` written next to every tenant's generated configuration:
/// the same plan Preview Changes runs, to run yourself in Terminal. It holds
/// no secrets — they are read from the login Keychain when it runs — and it
/// only plans, so nothing in Jamf changes.
public nonisolated enum TerminalScript {
    /// A Keychain item the script reads at run time.
    public struct KeychainRef: Sendable, Equatable {
        public var service: String
        public var account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    public struct Input: Sendable {
        /// The engine binary and its CLI configuration (the app's provider mirror).
        public var enginePath: String
        public var cliConfigPath: String
        /// Plain values: base URL, client ID, environment ID, Protect URL…
        public var environment: [String: String]
        /// Secret values by environment variable name.
        public var secrets: [String: KeychainRef]
        /// Encrypts the state; the script builds TF_ENCRYPTION around it.
        public var statePassphrase: KeychainRef
        public var planArguments: [String]
        /// Team Mode workspaces keep state behind the app's state backend,
        /// which only runs inside the app.
        public var isTeamMode: Bool

        public init(
            enginePath: String,
            cliConfigPath: String,
            environment: [String: String],
            secrets: [String: KeychainRef],
            statePassphrase: KeychainRef,
            planArguments: [String] = [],
            isTeamMode: Bool = false
        ) {
            self.enginePath = enginePath
            self.cliConfigPath = cliConfigPath
            self.environment = environment
            self.secrets = secrets
            self.statePassphrase = statePassphrase
            self.planArguments = planArguments
            self.isTeamMode = isTeamMode
        }
    }

    public static let fileName = "plan.sh"

    public static func render(_ input: Input) -> String {
        var lines = [
            "#!/bin/zsh",
            "# Runs this tenant's plan yourself: the engine, configuration and state",
            "# Preview Changes uses. A plan only reads; nothing in Jamf changes.",
            "#",
            "#   ./plan.sh                 the same plan as Preview Changes",
            "#   ./plan.sh -target=ADDRESS any other plan options",
            "#",
            "# Secrets come from your login Keychain while it runs (macOS asks the",
            "# first time) and are never written to a file. Jamf Deployer rewrites",
            "# this script on every preview.",
            "set -eu",
        ]
        if input.isTeamMode {
            lines += [
                "echo \"This tenant's state is in the team space, which the app reaches through\" >&2",
                "echo \"its own state backend. Use Export as Terraform to work with it outside the app.\" >&2",
                "exit 1",
            ]
            return lines.joined(separator: "\n") + "\n"
        }
        lines += [
            "cd \"${0:A:h}\"",
            "secret() {",
            "  security find-generic-password -s \"$1\" -a \"$2\" -w 2> /dev/null \\",
            "    || { echo \"Not in your Keychain: $1. Open the tenant in Jamf Deployer and enter it again.\" >&2; exit 1; }",
            "}",
            "",
            "export TF_CLI_CONFIG_FILE=\(quoted(input.cliConfigPath))",
        ]
        for (name, value) in input.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(name)=\(quoted(value))")
        }
        // Assigned before export: `export X="$(…)"` would hide a missing item from set -e.
        for (name, ref) in input.secrets.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name)=\"$(secret \(quoted(ref.service)) \(quoted(ref.account)))\"; export \(name)")
        }
        lines += [
            "",
            "# The state is encrypted with the passphrase on the tenant's recovery sheet.",
            "passphrase=\"$(secret \(quoted(input.statePassphrase.service)) \(quoted(input.statePassphrase.account)))\"",
            // Escaped for an HCL string, as the app's own hclEscaped does.
            #"passphrase=${passphrase//\\/\\\\}"#,
            #"passphrase=${passphrase//\"/\\\"}"#,
            #"passphrase=${passphrase//\$\{/\$\$\{}"#,
            #"passphrase=${passphrase//\%\{/\%\%\{}"#,
            #"passphrase=${passphrase//$'\n'/\\n}"#,
            "export TF_ENCRYPTION=\"",
            "key_provider \\\"pbkdf2\\\" \\\"passphrase\\\" {",
            "  passphrase = \\\"$passphrase\\\"",
            "}",
            "method \\\"aes_gcm\\\" \\\"default\\\" {",
            "  keys = key_provider.pbkdf2.passphrase",
            "}",
            "state {",
            "  method   = method.aes_gcm.default",
            "  enforced = true",
            "}",
            "plan {",
            "  method   = method.aes_gcm.default",
            "  enforced = true",
            "}\"",
            "unset passphrase",
            "",
            "engine=\(quoted(input.enginePath))",
            "\"$engine\" init -input=false > /dev/null",
            "exec \"$engine\" plan -input=false\(input.planArguments.map { " " + quoted($0) }.joined()) \"$@\"",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
