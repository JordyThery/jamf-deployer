import Foundation
import JamfDeployerCore
import JTKit

/// Hides secrets in what OpenTofu and jamformer print, before it is logged
/// or written: deploy history (`history/<id>/log.jsonl`, committed to the
/// team's Git store), activity log notes and the decisions trace.
///
/// Uses JTKit's free-text cleaning (`Redaction.text`): values of known
/// secret names (`client_secret=…`, `"password": "…"`, `<password>…`) and
/// `Bearer`/`Basic` credentials. It can't recognise a secret without such a
/// name, e.g. a Wi-Fi password repeated in a server's error message.
///
/// A Classic API error page (HTML, or XML `<error>`) quoted in the text is
/// replaced by its message (`readableErrorPages`).
nonisolated enum EngineOutputCleaner {
    /// Free text, e.g. an error message or a trace line.
    static func cleaned(_ text: String) -> String {
        readableErrorPages(in: Redaction.text(text))
    }

    /// Each Classic API error page in `text`, an HTML page or an XML
    /// `<error>`, replaced by its message with JTKit's reader. Secrets in a
    /// page are hidden first, while their tags (`<password>`) still say what
    /// they are. Everything outside a page, and text without one, stays
    /// exactly as it was.
    static func readableErrorPages(in text: String) -> String {
        guard text.localizedCaseInsensitiveContains("<html") || text.localizedCaseInsensitiveContains("<error") else {
            return text
        }
        func readable(_ page: Substring) -> String {
            let redacted = Redaction.text(String(page))
            return JamfClassic.errorMessage(in: Data(redacted.utf8)).map(Redaction.text) ?? redacted
        }
        return text
            .replacing(/(?is)(?:<!DOCTYPE html[^>]*>\s*)?<html\b.*?<\/html>/) { readable($0.output) }
            .replacing(/(?is)(?:<\?xml[^>]*\?>\s*)?<error\b[^>]*>.*?<\/error>/) { readable($0.output) }
    }

    /// A diagnostic with any error page in its summary or detail made
    /// readable; what the deploy sheet shows and translates.
    static func readableErrorPages(in diagnostic: EngineStreamEvent.Diagnostic) -> EngineStreamEvent.Diagnostic {
        var diagnostic = diagnostic
        diagnostic.summary = readableErrorPages(in: diagnostic.summary)
        diagnostic.detail = diagnostic.detail.map { readableErrorPages(in: $0) }
        return diagnostic
    }

    /// One line of engine output. OpenTofu's `-json` lines hold messages as
    /// JSON strings, where a server's answer inside them has its quotes
    /// escaped (`\"password\":\"…\"`) and the free-text cleaning can't see
    /// it; so a JSON line is unpacked and every text value in it is cleaned.
    /// A line with nothing to hide is returned exactly as it was.
    static func cleanedLine(_ line: String) -> String {
        guard line.first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              object is [String: Any] else {
            return cleaned(line)
        }
        var changed = false
        let cleanedObject = cleanStrings(in: object, changed: &changed)
        guard changed,
              let data = try? JSONSerialization.data(
                  withJSONObject: cleanedObject, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return cleaned(line)
        }
        return Redaction.text(text)
    }

    /// Every line, for a history log.
    static func cleanedLog(_ lines: [String]) -> String {
        lines.map(cleanedLine).joined(separator: "\n")
    }

    private static func cleanStrings(in value: Any, changed: inout Bool) -> Any {
        switch value {
        case let text as String:
            let result = cleaned(text)
            if result != text { changed = true }
            return result
        case let dictionary as [String: Any]:
            return dictionary.mapValues { cleanStrings(in: $0, changed: &changed) }
        case let array as [Any]:
            return array.map { cleanStrings(in: $0, changed: &changed) }
        default:
            return value
        }
    }
}
