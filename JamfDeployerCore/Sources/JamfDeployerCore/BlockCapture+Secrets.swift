import Foundation

nonisolated extension BlockCapture {
    /// What a capture does with the possible secrets in its objects.
    struct SecretPlan {
        /// The configuration texts with every value replaced by its variable.
        var fileTexts: [(name: String, text: String)]
        var settings: [CapturedSecret]
        /// Support files (path inside `files/`) that became templates, with
        /// their templated text.
        var templatedSupportFiles: [String: String]
    }

    /// Finds the values behind jamformer's findings and the app's own scan,
    /// keeps the ones in captured objects, and replaces each with a secret
    /// setting: `.tf` values become `var.<key>`, support files become
    /// `templatefile()` templates. A finding in a captured object whose
    /// value cannot be found or replaced stops the capture.
    static func planSecretSettings(
        request: Request,
        fileTexts: [(name: String, text: String)],
        localAddresses: Set<String>
    ) throws -> SecretPlan {
        let reportDirectory = request.resolutionDirectory ?? request.sourceDirectory
        func fallbackObject(_ finding: SecretFinding) -> SecretObjectFinding {
            SecretObjectFinding(address: nil, objectType: "File", objectName: finding.path, rule: finding.rule)
        }

        var found: [(value: String, object: SecretObjectFinding)] = []
        for finding in request.secretFindings {
            let object = SecretScan.objectFindings([finding.location], in: reportDirectory).first
                ?? fallbackObject(finding.location)
            // Only objects in this capture count; a file no object uses is
            // never captured.
            let captured = object.address.map(localAddresses.contains) ?? false
            guard let value = SecretScan.value(of: finding, in: reportDirectory) else {
                if captured { throw CaptureError.secretNotLocated(object: object.objectDescription, rule: object.rule) }
                continue
            }
            found.append((value, object))
        }
        for match in SecretScan.exportMatches(request.sourceDirectory) {
            let object = SecretScan.objectFindings([match.finding], in: request.sourceDirectory).first
                ?? fallbackObject(match.finding)
            found.append((match.value, object))
        }

        // Support files, by their path inside support_files/.
        var supportTexts: [String: String] = [:]
        let supportURL = request.sourceDirectory.appending(path: "support_files")
        let base = supportURL.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: supportURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: item), let text = SecretScan.scannableText(data) else { continue }
            let resolved = item.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base + "/") else { continue }
            supportTexts[String(resolved.dropFirst(base.count + 1))] = text
        }

        let joined = fileTexts.map(\.text).joined(separator: "\n")
        var settings: [CapturedSecret] = []
        var usedKeys: Set<String> = []
        var hclReplacements: [(value: String, key: String)] = []
        var supportReplacements: [String: [(value: String, key: String)]] = [:]
        var supportObjects: [String: String] = [:]
        var seenValues: Set<String> = []
        let ordered = found.sorted {
            ($0.object.objectName, $0.object.rule, $0.value) < ($1.object.objectName, $1.object.rule, $1.value)
        }
        for entry in ordered where seenValues.insert(entry.value).inserted {
            let inConfiguration = joined.contains(entry.value)
            let files = supportTexts
                .filter { $0.value.contains(entry.value) && joined.contains("files/\($0.key)") }
                .map(\.key).sorted()
            guard inConfiguration || !files.isEmpty else { continue }
            let key = uniqueSecretKey(for: entry.object.objectName, taken: &usedKeys)
            settings.append(CapturedSecret(
                key: key, title: "Secret in \(midSentence(entry.object))",
                objectDescription: entry.object.objectDescription, rule: entry.object.rule))
            if inConfiguration { hclReplacements.append((entry.value, key)) }
            for file in files {
                supportReplacements[file, default: []].append((entry.value, key))
                supportObjects[file] = supportObjects[file] ?? entry.object.objectDescription
            }
        }

        var texts = fileTexts.map { ($0.name, SecretScan.referencing($0.text, replacing: hclReplacements)) }
        var templated: [String: String] = [:]
        for (file, replacements) in supportReplacements.sorted(by: { $0.key < $1.key }) {
            let call = "file(\"${path.module}/files/\(file)\")"
            guard texts.contains(where: { $0.1.contains(call) }), let text = supportTexts[file] else {
                throw CaptureError.secretNotReplaceable(object: supportObjects[file] ?? file)
            }
            let variables = replacements.map { "\($0.key) = var.\($0.key)" }.joined(separator: ", ")
            let template = "templatefile(\"${path.module}/files/\(file)\", { \(variables) })"
            texts = texts.map { ($0.0, $0.1.replacingOccurrences(of: call, with: template)) }
            templated[file] = SecretScan.templated(text, replacing: replacements)
        }
        return SecretPlan(
            fileTexts: texts.map { (name: $0.0, text: $0.1) },
            settings: settings, templatedSupportFiles: templated)
    }

    /// `secret_<object name>`, lower case, unique within the block.
    static func uniqueSecretKey(for objectName: String, taken: inout Set<String>) -> String {
        var stem = objectName.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if stem.count > 40 { stem = String(stem.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "_")) }
        let base = "secret_" + (stem.isEmpty ? "value" : stem)
        var key = base
        var counter = 2
        while taken.contains(key) {
            key = "\(base)_\(counter)"
            counter += 1
        }
        taken.insert(key)
        return key
    }

    /// "script “Bind to AD”" for use inside a sentence.
    static func midSentence(_ object: SecretObjectFinding) -> String {
        guard object.address != nil else { return object.objectName }
        let type = object.objectType.hasPrefix("macOS") || object.objectType.hasPrefix("iOS")
            ? object.objectType
            : object.objectType.prefix(1).lowercased() + object.objectType.dropFirst()
        return "\(type) “\(object.objectName)”"
    }
}
