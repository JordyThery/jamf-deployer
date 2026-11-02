import Foundation

/// Adopt's possible secrets: each flagged value of an adopted object becomes
/// a sensitive variable, its value kept in the Keychain (like the export's
/// own sensitive variables), so the adopted configuration in the store holds
/// `var.<name>` instead. An object whose finding the engineer marked "not a
/// secret" keeps its value as it is.
///
/// Two steps, because jamformer's line numbers are those of the whole
/// export: `locate` before anything is pruned, `replace` once the staged
/// configuration is final. Values stay in memory.
public nonisolated enum AdoptSecrets {
    /// A value found behind a finding, and the object holding it.
    public struct Located: Sendable {
        public var value: String
        public var object: SecretObjectFinding
    }

    public struct LocatedResult: Sendable {
        public var values: [Located]
        /// Findings in selected objects whose value couldn't be found (a
        /// fully masked short value): they can't become a variable.
        public var notLocated: [SecretObjectFinding]
    }

    /// The values behind jamformer's findings and the app's own scan, for
    /// the objects in `selected` (addresses), except findings marked not a
    /// secret (`SecretObjectFinding.id`).
    public static func locate(
        in directory: URL, jamformerFindings: [JamformerSecretFinding], selected: Set<String>, notSecret: Set<String>
    ) -> LocatedResult {
        var values: [Located] = []
        var notLocated: [SecretObjectFinding] = []
        for finding in jamformerFindings {
            for object in SecretScan.objectFindings([finding.location], in: directory) {
                guard let address = object.address, selected.contains(address), !notSecret.contains(object.id) else { continue }
                if let value = SecretScan.value(of: finding, in: directory) {
                    values.append(Located(value: value, object: object))
                } else {
                    notLocated.append(object)
                }
            }
        }
        for match in SecretScan.exportMatches(directory) {
            for object in SecretScan.objectFindings([match.finding], in: directory) {
                guard let address = object.address, selected.contains(address), !notSecret.contains(object.id) else { continue }
                values.append(Located(value: match.value, object: object))
            }
        }
        return LocatedResult(values: values, notLocated: notLocated)
    }

    /// A variable that replaced a value; `value` goes to the Keychain.
    public struct Variable: Sendable, Equatable {
        public var name: String
        public var value: String
        public var objectDescription: String
        public var rule: String

        /// The declaration for the adopted configuration: sensitive, no default.
        public var declaration: String {
            "variable \"\(name)\" {\n  type      = string\n  sensitive = true\n}"
        }
    }

    public struct Replaced: Sendable {
        public var variables: [Variable]
        /// Objects whose value is neither in the configuration nor in a
        /// support file it loads with `file()`: still in place.
        public var notReplaced: [SecretObjectFinding]
    }

    /// Replaces each located value in the staged configuration's `.tf`
    /// files with `var.<name>`; a support file loaded with
    /// `file("${path.module}/support_files/…")` becomes a `templatefile()`
    /// template. Names start with `secret_` and avoid `taken`.
    public static func replace(in directory: URL, values: [Located], taken: Set<String>) throws -> Replaced {
        let fileManager = FileManager.default
        let tfFiles = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "tf" && !$0.lastPathComponent.hasSuffix("_import.tf") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var texts = try tfFiles.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
        let joined = texts.map(\.1).joined(separator: "\n")

        var supportTexts: [String: String] = [:]
        let supportURL = directory.appending(path: "support_files")
        let base = supportURL.resolvingSymlinksInPath().path
        let enumerator = fileManager.enumerator(at: supportURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: item), let text = SecretScan.scannableText(data) else { continue }
            let resolved = item.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base + "/") else { continue }
            supportTexts[String(resolved.dropFirst(base.count + 1))] = text
        }

        var usedNames = taken
        var variables: [Variable] = []
        var notReplaced: [SecretObjectFinding] = []
        var hclReplacements: [(value: String, key: String)] = []
        var supportReplacements: [String: [(value: String, key: String)]] = [:]
        var seenValues: Set<String> = []
        let ordered = values.sorted {
            ($0.object.objectName, $0.object.rule, $0.value) < ($1.object.objectName, $1.object.rule, $1.value)
        }
        for entry in ordered where seenValues.insert(entry.value).inserted {
            let inConfiguration = joined.contains(entry.value)
            let files = supportTexts
                .filter { $0.value.contains(entry.value) && joined.contains(fileCall($0.key)) }
                .map(\.key).sorted()
            guard inConfiguration || !files.isEmpty else {
                notReplaced.append(entry.object)
                continue
            }
            let name = BlockCapture.uniqueSecretKey(for: entry.object.objectName, taken: &usedNames)
            variables.append(Variable(name: name, value: entry.value,
                                      objectDescription: entry.object.objectDescription, rule: entry.object.rule))
            if inConfiguration { hclReplacements.append((entry.value, name)) }
            for file in files { supportReplacements[file, default: []].append((entry.value, name)) }
        }

        texts = texts.map { ($0.0, SecretScan.referencing($0.1, replacing: hclReplacements)) }
        for (file, replacements) in supportReplacements.sorted(by: { $0.key < $1.key }) {
            guard let text = supportTexts[file] else { continue }
            let call = fileCall(file)
            let arguments = replacements.map { "\($0.key) = var.\($0.key)" }.joined(separator: ", ")
            let template = "templatefile(\"${path.module}/support_files/\(file)\", { \(arguments) })"
            texts = texts.map { ($0.0, $0.1.replacingOccurrences(of: call, with: template)) }
            try Data(SecretScan.templated(text, replacing: replacements).utf8)
                .write(to: supportURL.appending(path: file), options: .atomic)
        }
        for (url, text) in texts {
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        return Replaced(variables: variables, notReplaced: notReplaced)
    }

    static func fileCall(_ supportPath: String) -> String {
        "file(\"${path.module}/support_files/\(supportPath)\")"
    }
}
