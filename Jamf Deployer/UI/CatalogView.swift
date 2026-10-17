import SwiftUI
import DeployerKit
import JamfDeployerCore

/// The building-block library: every block the catalog offers, grouped by
/// category, with what it creates and what it needs.
struct CatalogView: View {
    @Environment(TenantDeployService.self) private var deployService
    @State private var catalog: LoadedCatalog?
    @State private var loadError: String?
    @State private var selectedBlock: BlockMetadata?
    @State private var isAddingGitSource = false

    var body: some View {
        Group {
            if let catalog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groupedCategories(catalog), id: \.0) { category, blocks in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category)
                                    .font(.title3.bold())
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                                    alignment: .leading,
                                    spacing: 12
                                ) {
                                    ForEach(blocks) { block in
                                        BlockCard(block: block)
                                            .onTapGesture { selectedBlock = block }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Catalog Unavailable",
                    systemImage: "square.grid.2x2",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Loading building blocks…")
            }
        }
        .navigationTitle("Building Blocks")
        .toolbar {
            Button("Add Git Catalog…", systemImage: "arrow.triangle.branch") {
                isAddingGitSource = true
            }
            .help("Follow a building-block catalog published as a Git repository, pinned by release tag")
        }
        .sheet(isPresented: $isAddingGitSource) {
            AddGitCatalogSheet { 
                catalog = try? deployService.loadCatalog()
            }
        }
        .sheet(item: $selectedBlock) { block in
            BlockDetailSheet(block: block, catalog: catalog)
        }
        .task {
            do {
                catalog = try deployService.loadCatalog()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func groupedCategories(_ catalog: LoadedCatalog) -> [(String, [BlockMetadata])] {
        Dictionary(grouping: catalog.blocks, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 == "Core" ? true : ($1.0 == "Core" ? false : $0.0 < $1.0) }
    }
}

struct BlockCard: View {
    let block: BlockMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(block.name)
                    .font(.headline)
                Spacer()
                if block.needsReview {
                    StatusBadge("Review before use", style: .warning)
                } else if block.alwaysOn {
                    StatusBadge("Always on", style: .neutral)
                } else if block.risk == "high" {
                    StatusBadge("High impact", style: .warning)
                }
            }
            Text(block.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text("v\(block.version)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(block.objectsCreated.count) object type\(block.objectsCreated.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(height: 130)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(block.summary)
    }
}

struct BlockDetailSheet: View {
    let block: BlockMetadata
    let catalog: LoadedCatalog?
    @Environment(\.dismiss) private var dismiss
    @State private var readme: String?
    @State private var reviewedConfirmation = false

    var body: some View {
        SheetFrame(title: block.name, systemImage: "square.grid.2x2") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(block.summary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox("This block creates") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(block.objectsCreated, id: \.self) { object in
                                Label(object, systemImage: "plus.circle")
                                    .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    GroupBox("Permissions it needs") {
                        Text(block.permissions.joined(separator: "  ·  "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .textSelection(.enabled)
                    }

                    if !block.requires.isEmpty {
                        GroupBox("Requires") {
                            Text(block.requires.joined(separator: ", "))
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                        }
                    }

                    if let readme {
                        GroupBox("About") {
                            Text(.init(readme))
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Text("Source: \(catalog?.sourceName(for: block.id) ?? "—") · \(block.id)@\(block.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if block.needsReview {
                Button("Mark as Reviewed") {
                    markReviewed()
                }
                .help("Confirms a curator checked this captured block's names, scope and settings")
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 560, height: 520)
        .task {
            if let catalog {
                let url = catalog.blockFolderURL(id: block.id).appending(path: "README.md")
                readme = try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }

    /// Rewrites the captured block's reviewStatus in block.json.
    private func markReviewed() {
        guard let catalog else { return }
        let url = catalog.blockFolderURL(id: block.id).appending(path: "block.json")
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        object["reviewStatus"] = "reviewed"
        if let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: url)
            dismiss()
        }
    }
}


/// Registers a Git-hosted catalog source at a chosen release tag.
struct AddGitCatalogSheet: View {
    @Environment(CatalogSourceStore.self) private var catalogSources
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var tags: [String] = []
    @State private var selectedTag = ""
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        SheetFrame(title: "Add Git Catalog", systemImage: "arrow.triangle.branch", isBusy: isWorking) {
            Form {
                TextField("Name", text: $name, prompt: Text("Shared Blocks"))
                TextField("Repository URL", text: $url, prompt: Text("https://github.com/org/blocks.git"))
                    .font(.callout.monospaced())
                HStack {
                    Button("Fetch Release Tags") { fetchTags() }
                        .disabled(url.isEmpty || isWorking)
                    if !tags.isEmpty {
                        Picker("Tag", selection: $selectedTag) {
                            ForEach(tags, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 220)
                    }
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Catalog") { add() }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || selectedTag.isEmpty || isWorking)
        }
        .frame(width: 520, height: 340)
    }

    private func fetchTags() {
        isWorking = true
        message = nil
        let remote = url.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isWorking = false }
            do {
                let found = try await GitCatalogManager.availableTags(remote: remote)
                if found.isEmpty {
                    message = "The repository has no release tags yet — catalogs are pinned by tag."
                } else {
                    tags = found
                    selectedTag = found.last ?? ""
                }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func add() {
        isWorking = true
        let remote = url.trimmingCharacters(in: .whitespaces)
        let tag = selectedTag
        let sourceName = name
        Task {
            defer { isWorking = false }
            do {
                _ = try await catalogSources.addGitSource(name: sourceName, url: remote, tag: tag)
                onAdded()
                dismiss()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
