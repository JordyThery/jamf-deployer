import Foundation
import JTKit

/// Hides secrets in what OpenTofu and jamformer print, before it is logged
/// or written: deploy history (`history/<id>/log.jsonl`, committed to the
/// team's Git store), activity log notes and the decisions trace.
///
/// Uses JTKit's free-text cleaning (`Redaction.text`): values of known
/// secret names (`client_secret=…`, `"password": "…"`, `<password>…`) and
/// `Bearer`/`Basic` credentials. It can't recognise a secret without such a
/// name, e.g. a Wi-Fi password repeated in a server's error message.
nonisolated enum EngineOutputCleaner {
    /// Free text, e.g. an error message or a trace line.
    static func cleaned(_ text: String) -> String {
        Redaction.text(text)
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
            return Redaction.text(line)
        }
        var changed = false
        let cleanedObject = cleanStrings(in: object, changed: &changed)
        guard changed,
              let data = try? JSONSerialization.data(
                  withJSONObject: cleanedObject, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return Redaction.text(line)
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
            let cleaned = Redaction.text(text)
            if cleaned != text { changed = true }
            return cleaned
        case let dictionary as [String: Any]:
            return dictionary.mapValues { cleanStrings(in: $0, changed: &changed) }
        case let array as [Any]:
            return array.map { cleanStrings(in: $0, changed: &changed) }
        default:
            return value
        }
    }
}
