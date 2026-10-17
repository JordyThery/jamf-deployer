import SwiftUI
import UniformTypeIdentifiers

/// A downloaded .zip held in memory for export via `.fileExporter`.
public nonisolated struct ZipDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [.zip]
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The update sheet: status, release notes, and a download-then-replace flow.
public struct UpdateView: View {
    private var checker: UpdateChecker
    @State private var downloadedZip: ZipDocument?
    @State private var suggestedName = ""
    @State private var isExporting = false
    @State private var isDownloading = false
    @State private var downloadError: String?
    @Environment(\.dismiss) private var dismiss

    public init(checker: UpdateChecker) {
        self.checker = checker
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Software Update", systemImage: "arrow.down.circle")
                    .font(.title3.bold())
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding()

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                statusFooter
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if case .available = checker.status {
                    Button("Download Update") { download() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isDownloading)
                }
            }
            .padding()
        }
        .frame(width: 440)
        .frame(minHeight: 220, maxHeight: 480)
        .fileExporter(
            isPresented: $isExporting,
            document: downloadedZip,
            contentType: .zip,
            defaultFilename: suggestedName
        ) { result in
            if case .success(let url) = result {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private var isBusy: Bool {
        if case .checking = checker.status { return true }
        return isDownloading
    }

    @ViewBuilder
    private var content: some View {
        switch checker.status {
        case .idle, .checking:
            ProgressView("Checking for updates…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        case .upToDate:
            ContentUnavailableView(
                "\(checker.appName) is up to date",
                systemImage: "checkmark.circle",
                description: Text("Version \(checker.installedVersion) is the latest release.")
            )
        case .failed(let message):
            ContentUnavailableView(
                "Update Check Failed",
                systemImage: "xmark.octagon",
                description: Text(message)
            )
        case .available(let release):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Version \(release.version) is available")
                        .font(.headline)
                    Text("You have \(checker.installedVersion).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !release.notesMarkdown.isEmpty {
                        Text(
                            (try? AttributedString(
                                markdown: release.notesMarkdown,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            )) ?? AttributedString(release.notesMarkdown)
                        )
                        .textSelection(.enabled)
                    }
                    if let downloadError {
                        Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    if downloadedZip != nil {
                        Label(
                            "Quit \(checker.appName) and replace it in Applications with the downloaded copy.",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if case .available(let release) = checker.status {
            Link("Release notes", destination: release.pageURL)
        }
    }

    private func download() {
        guard case .available(let release) = checker.status else { return }
        isDownloading = true
        downloadError = nil
        Task {
            defer { isDownloading = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: release.zipAssetURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateChecker.UpdateError.feedUnavailable
                }
                downloadedZip = ZipDocument(data: data)
                suggestedName = release.zipAssetName
                isExporting = true
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }
}
