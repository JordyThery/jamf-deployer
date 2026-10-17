import SwiftUI
import os
import DeployerKit
import JamfDeployerCore

/// The building-block library: every block the catalog offers, grouped by
/// category, with what it creates and what it needs.
struct CatalogView: View {
    @Environment(TenantDeployService.self) private var deployService
    @Environment(CatalogSourceStore.self) private var catalogSources
    @State private var catalog: LoadedCatalog?
    @State private var loadError: String?
    @State private var selectedBlock: BlockMetadata?
    @State private var isAddingGitSource = false
    @State private var isManagingSources = false
    @State private var isAddingDemoCatalog = false
    @State private var demoCatalogError: String?

    static let demoCatalogURL = "https://github.com/JordyThery/jamf-deployer-catalog.git"

    var body: some View {
        Group {
            if let catalog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if catalogSources.customSources.isEmpty {
                            demoCatalogBanner
                        }
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
                                        BlockCard(block: block, sourceName: customSourceName(for: block))
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
            Button("Manage Sources…", systemImage: "folder.badge.gearshape") {
                isManagingSources = true
            }
            .help("The folders and repositories your custom blocks come from")
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
            BlockDetailSheet(block: block, catalog: catalog) {
                catalog = try? deployService.loadCatalog()
            }
        }
        .sheet(isPresented: $isManagingSources) {
            ManageSourcesSheet(
                onChanged: { catalog = try? deployService.loadCatalog() },
                onAddGitCatalog: {
                    // Opened from the library, not on top of this sheet:
                    // nested sheets do not reliably receive clicks.
                    isManagingSources = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        isAddingGitSource = true
                    }
                }
            )
        }
        .task {
            do {
                catalog = try deployService.loadCatalog()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    /// The app ships only the configuration-free blocks; opinionated ones
    /// come from catalogs you follow or publish. The demo catalog is a
    /// worked example.
    private var demoCatalogBanner: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Blocks come from catalogs")
                        .font(.headline)
                    Text("The app ships only blocks without configuration opinions (App Catalog, Jamf Protect, Security Cloud); they use the groups and categories already in your tenant. Add the demo catalog for device groups, categories and a full baseline. For real fleets, capture your own blocks or publish your own catalog repository.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let demoCatalogError {
                        Label(demoCatalogError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(isAddingDemoCatalog ? "Adding…" : "Add Demo Catalog") {
                    addDemoCatalog()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAddingDemoCatalog)
            }
            .padding(6)
        }
    }

    private func addDemoCatalog() {
        isAddingDemoCatalog = true
        demoCatalogError = nil
        Task {
            defer { isAddingDemoCatalog = false }
            do {
                guard let latest = try await GitCatalogManager.availableTags(remote: Self.demoCatalogURL).last else {
                    demoCatalogError = "The catalog repository has no releases yet."
                    return
                }
                _ = try await catalogSources.addGitSource(
                    name: "Demo Catalog",
                    url: Self.demoCatalogURL,
                    tag: latest
                )
                catalog = try? deployService.loadCatalog()
            } catch {
                demoCatalogError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The source name shown on a card — only for blocks outside the
    /// built-in catalog.
    private func customSourceName(for block: BlockMetadata) -> String? {
        guard let catalog else { return nil }
        let folder = catalog.blockFolderURL(id: block.id)
        guard !folder.path.hasPrefix(EngineLocator.catalogURL.path) else { return nil }
        return catalog.sourceName(for: block.id)
    }

    private func groupedCategories(_ catalog: LoadedCatalog) -> [(String, [BlockMetadata])] {
        Dictionary(grouping: catalog.blocks, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 == "Core" ? true : ($1.0 == "Core" ? false : $0.0 < $1.0) }
    }
}

struct BlockCard: View {
    let block: BlockMetadata
    var sourceName: String?

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
                if let sourceName {
                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("This block comes from the \"\(sourceName)\" catalog source")
                }
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
    /// Called after anything on disk changed, so the library reloads.
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(TenantStore.self) private var tenantStore
    @Environment(CatalogSourceStore.self) private var catalogSources
    @State private var readme: String?
    @State private var reviewedConfirmation = false
    @State private var isEditingDetails = false
    @State private var isConfirmingDelete = false
    @State private var editName = ""
    @State private var editSummary = ""
    @State private var editVersion = ""
    @State private var editCategory = ""
    @State private var editError: String?
    private static let log = Logger(subsystem: "be.jordythery.jamf-deployer", category: "catalog")
    @State private var actionError: String?

    /// Built-in blocks live inside the app bundle and stay read-only.
    private var isBuiltIn: Bool {
        guard let catalog else { return true }
        return catalog.blockFolderURL(id: block.id).path.hasPrefix(EngineLocator.catalogURL.path)
    }

    /// Blocks from git catalog sources are tag-pinned checkouts; editing or
    /// deleting them would desync the cache from the published tag. Only
    /// blocks in local-folder sources can change in place.
    private var isEditable: Bool {
        guard let catalog, !isBuiltIn else { return false }
        let path = catalog.blockFolderURL(id: block.id).path
        return catalogSources.customSources.contains {
            $0.kind == .localFolder && path.hasPrefix($0.path)
        }
    }

    /// Library sections already in use, for the category picker.
    private var existingCategories: [String] {
        Array(Set((catalog?.blocks ?? []).map(\.category))).sorted()
    }

    /// The sheet already shows the name and summary; drop a README's
    /// leading heading and a repeated summary so About starts with content.
    private func trimmedReadme(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func dropBlank() { while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() } }
        dropBlank()
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst(); dropBlank() }
        if lines.first?.trimmingCharacters(in: .whitespaces) == block.summary { lines.removeFirst(); dropBlank() }
        return lines.joined(separator: "\n")
    }

    /// Tenants whose baseline currently selects this block.
    private var tenantsUsingBlock: [String] {
        tenantStore.tenants
            .filter { tenant in tenant.blockSelections.contains { $0.blockID == block.id } }
            .map(\.name)
    }

    var body: some View {
        SheetFrame(title: block.name, systemImage: "square.grid.2x2") {
            if isEditingDetails {
                // Inline rather than a nested sheet: buttons in a sheet
                // presented from a sheet do not reliably receive clicks.
                editDetailsForm
            } else {
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
            }
        } footer: {
            if isEditingDetails {
                Spacer()
                Button("Cancel") { editError = nil; isEditingDetails = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveDetails() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty || editVersion.isEmpty
                              || editCategory.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
            Text("Source: \(catalog?.sourceName(for: block.id) ?? "—") · \(block.id)@\(block.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isBuiltIn {
                Button("Duplicate to My Blocks…") { duplicateToMyBlocks() }
                    .help("Copies this block into one of your catalog sources, where it can be edited freely")
            } else if isEditable {
                Button("Reveal in Finder") { revealInFinder() }
                Button("Edit Details…") {
                    editName = block.name
                    editSummary = block.summary
                    editVersion = block.version
                    editCategory = block.category
                    isEditingDetails = true
                }
                Button("Delete Block…", role: .destructive) { isConfirmingDelete = true }
            } else {
                Button("Duplicate to My Blocks…") { duplicateToMyBlocks() }
                    .help("Blocks from a git catalog follow their published tag; duplicate one into a folder source to edit it")
            }
            if block.needsReview {
                Button("Mark as Reviewed") {
                    markReviewed()
                }
                .help("Confirms a curator checked this captured block's names, scope and settings")
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            }
        }
        .confirmationDialog(
            tenantsUsingBlock.isEmpty
                ? "Delete “\(block.name)”?"
                : "Delete “\(block.name)”? It is selected by \(tenantsUsingBlock.joined(separator: ", ")) — their baselines will fail to generate until the block is removed there.",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Block", role: .destructive) { deleteBlock() }
        } message: {
            Text("The block folder is deleted from its catalog source. Objects already deployed in Jamf are not touched.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .frame(width: 560, height: 520)
        .task {
            if let catalog {
                let url = catalog.blockFolderURL(id: block.id).appending(path: "README.md")
                readme = (try? String(contentsOf: url, encoding: .utf8)).map(trimmedReadme)
            }
        }
    }

    private var editDetailsForm: some View {
        Form {
            TextField("Name", text: $editName)
            TextField("Summary", text: $editSummary, axis: .vertical)
                .lineLimit(1...3)
            HStack {
                TextField("Category", text: $editCategory)
                Menu("Existing") {
                    ForEach(existingCategories, id: \.self) { category in
                        Button(category) { editCategory = category }
                    }
                }
                .fixedSize()
                .disabled(existingCategories.isEmpty)
                .help("The section this block appears under in the library")
            }
            TextField("Version", text: $editVersion)
                .font(.callout.monospaced())
            Section {
                Text("Deeper changes — settings, scope, the configuration itself — are edited in the block folder (Reveal in Finder).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let editError {
                    Label(editError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func revealInFinder() {
        guard let catalog else { return }
        NSWorkspace.shared.activateFileViewerSelecting([catalog.blockFolderURL(id: block.id)])
    }

    private func saveDetails() {
        do {
            try writeManifest { object in
                object["name"] = editName.trimmingCharacters(in: .whitespaces)
                object["summary"] = editSummary
                object["version"] = editVersion
                object["category"] = editCategory.trimmingCharacters(in: .whitespaces)
            }
        } catch {
            Self.log.error("Saving details for \(block.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            // Shown inline: an alert presented from this sheet is unreliable.
            editError = "The details could not be saved: \(error.localizedDescription)"
            return
        }
        editError = nil
        isEditingDetails = false
        onChanged()
        dismiss()
    }

    private func deleteBlock() {
        guard let catalog else { return }
        do {
            try FileManager.default.removeItem(at: catalog.blockFolderURL(id: block.id))
            onChanged()
            dismiss()
        } catch {
            actionError = "The block could not be deleted: \(error.localizedDescription)"
        }
    }

    /// Copies a built-in block into the first local custom source under a
    /// new ID, ready for editing.
    private func duplicateToMyBlocks() {
        guard let catalog else { return }
        guard let source = catalogSources.customSources.first(where: { $0.kind == .localFolder }) else {
            // No folder source yet: have the user pick one, like Export does.
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use Folder"
            panel.message = "Choose (or create) a folder to hold your blocks."
            guard panel.runModal() == .OK, let url = panel.url,
                  let created = try? catalogSources.addSource(name: url.lastPathComponent, folderURL: url)
            else { return }
            duplicate(into: created, catalog: catalog)
            return
        }
        duplicate(into: source, catalog: catalog)
    }

    private func duplicate(into source: CatalogSourceStore.CustomSource, catalog: LoadedCatalog) {
        let newID = "\(block.id)-custom"
        let destination = URL(filePath: source.path).appending(path: "blocks/\(newID)")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            actionError = "\(source.name) already contains a block named \(newID)."
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: catalog.blockFolderURL(id: block.id), to: destination)
            let manifestURL = destination.appending(path: "block.json")
            if let data = try? Data(contentsOf: manifestURL),
               var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                object["id"] = newID
                object["name"] = "\(block.name) (Custom)"
                if let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                    try? updated.write(to: manifestURL)
                }
            }
            onChanged()
            dismiss()
        } catch {
            actionError = "The block could not be duplicated: \(error.localizedDescription)"
        }
    }

    /// Rewrites block.json in place; throws with the underlying reason.
    private func writeManifest(_ mutate: (inout [String: Any]) -> Void) throws {
        guard let catalog else { throw CocoaError(.fileNoSuchFile) }
        let url = catalog.blockFolderURL(id: block.id).appending(path: "block.json")
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        mutate(&object)
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    private func updateManifest(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        do {
            try writeManifest(mutate)
            return true
        } catch {
            Self.log.error("Writing block.json for \(block.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Rewrites the captured block's reviewStatus in block.json.
    private func markReviewed() {
        guard updateManifest({ $0["reviewStatus"] = "reviewed" }) else {
            actionError = "The block could not be marked as reviewed. Check that the block folder is writable."
            return
        }
        onChanged()
        dismiss()
    }
}


/// Lists the custom catalog sources and lets the user detach them.
struct ManageSourcesSheet: View {
    var onChanged: () -> Void
    var onAddGitCatalog: () -> Void = {}
    @Environment(CatalogSourceStore.self) private var catalogSources
    @Environment(TenantStore.self) private var tenantStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourcePendingRemoval: CatalogSourceStore.CustomSource?
    @State private var addError: String?

    var body: some View {
        SheetFrame(title: "Catalog Sources", systemImage: "folder.badge.gearshape") {
            if catalogSources.customSources.isEmpty {
                ContentUnavailableView(
                    "No Custom Sources",
                    systemImage: "folder",
                    description: Text("Add a folder for your own blocks and presets, or follow a catalog published as a Git repository.")
                )
                .frame(maxHeight: 220)
            } else {
                List(catalogSources.customSources) { source in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.name).font(.headline)
                                if source.kind == .gitRepository {
                                    StatusBadge("Git · \(source.defaultTag ?? "no tag")", style: .neutral)
                                }
                            }
                            Text(source.kind == .gitRepository ? (source.gitURL ?? source.path) : source.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if source.kind == .localFolder {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: source.path)])
                            }
                            .controlSize(.small)
                        }
                        Button("Remove…", role: .destructive) {
                            sourcePendingRemoval = source
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        } footer: {
            Button("Add Folder…", systemImage: "folder.badge.plus") { addFolder() }
                .help("Use a folder on this Mac for your own blocks and presets — new or existing")
            Button("Add Git Catalog…", systemImage: "arrow.triangle.branch") { onAddGitCatalog() }
                .help("Follow a building-block catalog published as a Git repository, pinned by release tag")
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 600, height: 380)
        .alert(
            "The folder could not be added",
            isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Source", role: .destructive) {
                if let source = sourcePendingRemoval { remove(source) }
            }
        } message: {
            Text(sourcePendingRemoval?.kind == .gitRepository
                ? "The downloaded checkouts are deleted; the repository itself is untouched."
                : "The folder and its blocks stay on disk — the app just stops reading them.")
        }
    }

    /// Registers a folder as a catalog source; a new folder gets its
    /// catalog.json, an existing catalog folder is used as it is.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose (or create) a folder for your blocks and presets."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !catalogSources.customSources.contains(where: { $0.path == url.path }) else {
            addError = "\(url.lastPathComponent) is already a catalog source."
            return
        }
        do {
            try catalogSources.addSource(name: url.lastPathComponent, folderURL: url)
            onChanged()
        } catch {
            addError = error.localizedDescription
        }
    }

    private var removalTitle: String {
        guard let source = sourcePendingRemoval else { return "" }
        let users = tenantStore.tenants
            .filter { tenant in tenant.blockSelections.contains { $0.sourceID == source.id.uuidString } }
            .map(\.name)
        return users.isEmpty
            ? "Remove “\(source.name)”?"
            : "Remove “\(source.name)”? Blocks from it are selected by \(users.joined(separator: ", ")) — their baselines will fail to generate."
    }

    private func remove(_ source: CatalogSourceStore.CustomSource) {
        if source.kind == .gitRepository {
            // The cache folder is app-managed; clean it up with the source.
            try? FileManager.default.removeItem(at: URL(filePath: source.path))
        }
        catalogSources.removeSource(source)
        sourcePendingRemoval = nil
        onChanged()
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
