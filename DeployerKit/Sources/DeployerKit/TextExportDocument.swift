import SwiftUI
import UniformTypeIdentifiers

/// Plain-text file export (Markdown, HTML, JSON, CSV) for `.fileExporter`.
public nonisolated struct TextExportDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [
        .plainText, .html, .json, .commaSeparatedText,
    ]

    public var text: String
    public var contentType: UTType

    public init(text: String, contentType: UTType = .plainText) {
        self.text = text
        self.contentType = contentType
    }

    public init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
        contentType = .plainText
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
