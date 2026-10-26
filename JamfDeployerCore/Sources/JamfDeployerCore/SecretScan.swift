import Foundation

/// Where a possible secret is: a file, a line and the rule that matched.
/// Never the value. This is what screens, READMEs and the store's "not a
/// secret" acknowledgements hold.
public nonisolated struct SecretFinding: Codable, Sendable, Hashable {
    /// Path relative to the scanned folder (an export or the store).
    public var path: String
    /// 1-based line.
    public var line: Int
    /// The rule's plain-language description.
    public var rule: String

    public init(path: String, line: Int, rule: String) {
        self.path = path
        self.line = line
        self.rule = rule
    }
}

/// One finding from jamformer's secret scan report. jamformer prints part
/// of the value (its first and last characters, the rest as `*`); that text
/// is kept only in memory, to find the value again in the export, and is
/// not public: nothing outside this module can show it.
public nonisolated struct JamformerSecretFinding: Sendable, Hashable {
    public var location: SecretFinding
    let maskedText: String

    init(location: SecretFinding, maskedText: String) {
        self.location = location
        self.maskedText = maskedText
    }
}

/// A possible secret tied to the exported object that holds it.
public nonisolated struct SecretObjectFinding: Sendable, Hashable, Identifiable {
    /// Resource address, or nil when no object references the file.
    public var address: String?
    /// "Script", "macOS configuration profile", …; the file path when there is no object.
    public var objectType: String
    public var objectName: String
    public var rule: String

    public var id: String { "\(address ?? objectName)|\(rule)" }

    /// "Script “Bind to AD”", for screens and READMEs.
    public var objectDescription: String {
        address == nil ? objectName : "\(objectType) “\(objectName)”"
    }
}

/// Reads jamformer's secret scan report, ties findings to objects, and
/// scans text itself (the store check before every commit; jamformer has
/// no scan-only mode).
public nonisolated enum SecretScan {
    // MARK: jamformer's report

    /// The findings in jamformer's output. The report is
    ///
    ///     !  Secret scan found 2 potential secret(s):
    ///
    ///       In support files:
    ///
    ///         support_files/scripts/Bind.zsh
    ///           Line 3    FAKE***************-123  (Password value in HCL attribute)
    ///
    ///       Review these findings before committing to version control.
    ///
    /// with blank lines inside it; it ends at the "Review" line, or once the
    /// announced number of findings has been read.
    public static func parseJamformerReport(_ lines: [String]) -> [JamformerSecretFinding] {
        var findings: [JamformerSecretFinding] = []
        var expected: Int?
        var currentPath: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if expected == nil {
                if let match = line.firstMatch(of: /(?i)secret scan found\s+(\d+)\s+potential secret/) {
                    expected = Int(match.1)
                }
                continue
            }
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("review these findings") { break }
            if let match = line.firstMatch(of: /^Line\s+(\d+)\s+(.+?)\s+\(([^()]+)\)$/) {
                guard let path = currentPath, let number = Int(match.1) else { continue }
                findings.append(JamformerSecretFinding(
                    location: SecretFinding(path: path, line: number, rule: String(match.3)),
                    maskedText: String(match.2)))
                if let expected, findings.count >= expected { break }
            } else if line.hasPrefix("In "), line.hasSuffix(":") {
                continue
            } else if line.contains("/") || line.contains(".") {
                currentPath = line
            } else {
                // Anything else means the report is over.
                break
            }
        }
        return findings
    }

    /// A line of jamformer's output with the scanned text removed: a
    /// finding line keeps only its line number and rule. Other lines are
    /// unchanged. Every jamformer line shown or logged goes through this.
    public static func withoutScannedText(_ line: String) -> String {
        guard let match = line.firstMatch(of: /^(\s*Line\s+\d+)\s+.+?\s+(\([^()]+\))\s*$/) else { return line }
        return "\(match.1)  \(match.2)"
    }

    // MARK: Objects

    /// Ties findings to the exported objects holding them: a support file
    /// to every resource that loads it, a `.tf` line to the resource
    /// around it. Findings in files no object uses keep the file as name.
    public static func objectFindings(_ findings: [SecretFinding], in exportDirectory: URL) -> [SecretObjectFinding] {
        let resources = resourceBlocks(in: exportDirectory)
        var result: [SecretObjectFinding] = []
        var seen: Set<String> = []
        for finding in findings {
            var matched: [ResourceBlock] = []
            if finding.path.hasSuffix(".tf") {
                matched = resources.filter { $0.file == finding.path && $0.lines.contains(finding.line) }
            } else {
                matched = resources.filter { $0.text.contains(finding.path) }
            }
            if matched.isEmpty {
                let entry = SecretObjectFinding(address: nil, objectType: "File", objectName: finding.path, rule: finding.rule)
                if seen.insert(entry.id).inserted { result.append(entry) }
            }
            for resource in matched {
                let entry = SecretObjectFinding(
                    address: resource.address, objectType: BlockCapture.objectLabel(for: resource.type),
                    objectName: resource.name, rule: finding.rule)
                if seen.insert(entry.id).inserted { result.append(entry) }
            }
        }
        return result
    }

    struct ResourceBlock {
        var file: String
        var type: String
        var address: String
        var name: String
        var text: String
        var lines: ClosedRange<Int>
    }

    /// The resource blocks of an export's top-level `.tf` files, with the
    /// lines each one spans.
    static func resourceBlocks(in directory: URL) -> [ResourceBlock] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [ResourceBlock] = []
        for file in files where file.pathExtension == "tf" && !file.lastPathComponent.hasSuffix("_import.tf") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var searchStart = text.startIndex
            for block in ExportedObjectInventory.topLevelBlocks(in: text) {
                guard let range = text.range(of: block, range: searchStart..<text.endIndex) else { continue }
                searchStart = range.upperBound
                guard let header = block.firstMatch(of: /^resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) else { continue }
                let first = text[..<range.lowerBound].count(where: { $0 == "\n" }) + 1
                let last = first + block.count(where: { $0 == "\n" })
                let name = block.firstMatch(of: /\n\s+(?:name|display_name)\s+= "([^"]*)"/).map { String($0.1) } ?? String(header.2)
                result.append(ResourceBlock(
                    file: file.lastPathComponent, type: String(header.1), address: "\(header.1).\(header.2)",
                    name: name, text: block, lines: first...last))
            }
        }
        return result
    }

    // MARK: Values (in memory only)

    /// The value behind a jamformer finding, read from the export the report
    /// is about. jamformer's masked text keeps the value's length and its
    /// first and last characters; the value is on the reported line or just
    /// after it (a plist value follows its key's line).
    static func value(of finding: JamformerSecretFinding, in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appending(path: finding.location.path), encoding: .utf8) else { return nil }
        let pattern = finding.maskedText.map { $0 == "*" ? "." : NSRegularExpression.escapedPattern(for: String($0)) }.joined()
        // A mask of stars only matches anything; refuse rather than guess.
        guard finding.maskedText.contains(where: { $0 != "*" }),
              let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let lines = text.components(separatedBy: "\n")
        let wanted = finding.location.line - 1
        for index in [wanted, wanted + 1, wanted + 2, wanted - 1] where lines.indices.contains(index) {
            let line = lines[index] as NSString
            if let match = regex.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) {
                return line.substring(with: match.range)
            }
        }
        return nil
    }

    // MARK: Own scan

    /// A possible secret found by `scan`, with its value (in memory only).
    struct Match {
        var finding: SecretFinding
        var value: String
    }

    struct Rule {
        var description: String
        var regex: NSRegularExpression
        /// Capture group holding the value; 0 = the whole match.
        var valueGroup: Int
        /// Capture group holding the key name, checked against `secretKey`.
        var keyGroup: Int?
        /// Line of this group's start (a plist key) instead of the value's.
        var lineGroup: Int?
    }

    static let secretKey = try! NSRegularExpression(
        pattern: #"(?i)(pass(word|wd|phrase)?|secret|token|psk|challenge|credential|api[_-]?key|private[_-]?key|shared[_-]?key)"#)
    /// Key names that mention a secret without holding one.
    static let harmlessKey = try! NSRegularExpression(
        pattern: #"(?i)(_?(name|id|ids|url|uri|type|hint|length|policy|file|path|label|description|enabled|required|expir\w*|count|format|method|mode|prompt|title)$|^(sensitive|token_type))"#)

    static let rules: [Rule] = {
        func rule(_ description: String, _ pattern: String, value: Int, key: Int? = nil, line: Int? = nil) -> Rule {
            Rule(description: description, regex: try! NSRegularExpression(pattern: pattern), valueGroup: value, keyGroup: key, lineGroup: line)
        }
        return [
            rule("Password or secret in plist/XML configuration",
                 #"(?is)<key>\s*([^<]{1,64}?)\s*</key>\s*<string>([^<]{6,})</string>"#, value: 2, key: 1, line: 1),
            rule("Password value in HCL attribute",
                 #"(?i)\b([A-Za-z0-9_.-]{0,40}(?:pass(?:word|wd|phrase)?|secret|token|psk|challenge|api[_-]?key)[A-Za-z0-9_]{0,40})\\?["']?[ \t]*[:=][ \t]*\\?["']([^"'\s\\]{6,})\\?["']"#,
                 value: 2, key: 1),
            rule("Password value in a script",
                 #"(?im)^[ \t]*(?:export[ \t]+)?([A-Za-z_]{0,40}(?:PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY)[A-Za-z_]{0,40})=([^\s"'$;#`(][^\s;#`]{5,})"#,
                 value: 2, key: 1),
            rule("Private key", #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#, value: 0),
            rule("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, value: 0),
            rule("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#, value: 0),
            rule("Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#, value: 0),
            // READMEs captured before this check listed jamformer's findings,
            // with part of each value.
            rule("Part of a secret in an earlier secret scan report",
                 #"(?m)\bLine\s+\d+\s+(\S{1,8}\*{3,}\S{0,8})\s+\("#, value: 1),
        ]
    }()

    /// Values that are placeholders or references, not secrets.
    static func isPlaceholder(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if value.contains("${") || value.contains("%{") || value.contains("<redacted>") || value.hasPrefix("$") { return true }
        if ["var.", "local.", "data.", "each.", "module."].contains(where: lowered.hasPrefix) { return true }
        if ["bearer", "basic", "true", "false", "null", "none", "string", "required", "changeme", "password"].contains(lowered) { return true }
        // Masks such as "******" or "••••••".
        if !value.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        return false
    }

    /// Possible secrets in `text`, the contents of the file at `path`.
    public static func scan(text: String, path: String) -> [SecretFinding] {
        matches(in: text, path: path).map(\.finding)
    }

    static func matches(in text: String, path: String) -> [Match] {
        let nsText = text as NSString
        var lineStarts: [Int] = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { lineStarts.append(offset + 1) }
        func lineNumber(at location: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }
        var result: [Match] = []
        var seen: Set<String> = []
        for rule in rules {
            for match in rule.regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let valueRange = match.range(at: rule.valueGroup)
                guard valueRange.location != NSNotFound else { continue }
                let value = nsText.substring(with: valueRange)
                if rule.keyGroup != nil || rule.valueGroup != 0, isPlaceholder(value) { continue }
                if let keyGroup = rule.keyGroup {
                    let key = nsText.substring(with: match.range(at: keyGroup))
                    let keyRange = NSRange(location: 0, length: (key as NSString).length)
                    guard secretKey.firstMatch(in: key, range: keyRange) != nil,
                          harmlessKey.firstMatch(in: key, range: keyRange) == nil else { continue }
                }
                let lineLocation = rule.lineGroup.map { match.range(at: $0).location } ?? valueRange.location
                let finding = SecretFinding(path: path, line: lineNumber(at: lineLocation), rule: rule.description)
                // One finding per line and value: the rules overlap.
                guard seen.insert("\(finding.line)|\(value)").inserted else { continue }
                result.append(Match(finding: finding, value: value))
            }
        }
        return result.sorted { ($0.finding.line, $0.finding.rule) < ($1.finding.line, $1.finding.rule) }
    }

    /// Files larger than this, or with a NUL byte, are not text and are skipped.
    public static let maximumFileSize = 4 * 1024 * 1024

    /// The text of a file worth scanning, or nil for binaries and large files.
    public static func scannableText(_ data: Data) -> String? {
        guard data.count <= maximumFileSize, !data.contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Possible secrets in an export: its `.tf` files and support files.
    /// Provider wiring (credentials arrive as environment variables) and
    /// the engine's own folders are skipped.
    public static func scanExport(_ directory: URL) -> [SecretFinding] {
        exportMatches(directory).map(\.finding)
    }

    static func exportMatches(_ directory: URL) -> [Match] {
        let skipped: Set<String> = ["provider.tf", "versions.tf", "variables.tf", "terraform.tfvars", ".terraform", ".terraform.lock.hcl", "PERMISSIONS.md", ".gitignore"]
        let base = directory.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: nil) else { return [] }
        var result: [Match] = []
        while let item = enumerator.nextObject() as? URL {
            if skipped.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  item.lastPathComponent.hasSuffix("_import.tf") == false,
                  let data = try? Data(contentsOf: item), let text = scannableText(data) else { continue }
            let resolved = item.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base + "/") else { continue }
            result += matches(in: text, path: String(resolved.dropFirst(base.count + 1)))
        }
        return result
    }

    // MARK: Templates

    /// A support file's text as a Terraform template: `${` and `%{` already
    /// in it are escaped, then each value becomes `${key}`.
    static func templated(_ text: String, replacing values: [(value: String, key: String)]) -> String {
        var result = text
        // Placeholders first, so a value containing `${` survives escaping.
        let ordered = values.sorted { $0.value.count > $1.value.count }
        for (index, entry) in ordered.enumerated() {
            result = result.replacingOccurrences(of: entry.value, with: "\u{0}\(index)\u{0}")
        }
        result = result.replacingOccurrences(of: "${", with: "$${").replacingOccurrences(of: "%{", with: "%%{")
        for (index, entry) in ordered.enumerated() {
            result = result.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: "${\(entry.key)}")
        }
        return result
    }

    /// HCL text with each value replaced by its variable: a whole string
    /// literal becomes `var.key`, a value inside a longer string `${var.key}`.
    static func referencing(_ text: String, replacing values: [(value: String, key: String)]) -> String {
        var result = text
        for entry in values.sorted(by: { $0.value.count > $1.value.count }) {
            result = result.replacingOccurrences(of: "\"\(entry.value)\"", with: "var.\(entry.key)")
            result = result.replacingOccurrences(of: entry.value, with: "${var.\(entry.key)}")
        }
        return result
    }
}
