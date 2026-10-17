import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Searches Jamf's App Catalog and configures the selected apps for the
/// app-catalog building block.
struct AppCatalogPickerView: View {
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.dismiss) private var dismiss

    let tenant: Tenant
    @Binding var apps: [AppCatalogApp]

    nonisolated private struct Title: Decodable, Identifiable, Sendable {
        var id: String
        var titleName: String
        var publisher: String
        var iconUrl: String?
        var version: String?
    }

    nonisolated private struct TitlesPage: Decodable, Sendable {
        var totalCount: Int
        var results: [Title]
    }

    @State private var searchText = ""
    @State private var titles: [Title] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        SheetFrame(
            title: "App Catalog — \(tenant.name)",
            systemImage: "app.badge",
            isBusy: isLoading
        ) {
            HStack(spacing: 0) {
                searchColumn
                    .frame(width: 350)
                    .frame(maxHeight: .infinity, alignment: .top)
                Divider()
                selectionColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            Text("\(apps.count) app\(apps.count == 1 ? "" : "s") selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            // Deliberately no .defaultAction shortcut: pressing Return in
            // the search field must search, not close the sheet.
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(width: 760, height: 540)
        .task {
            search()
        }
    }

    // MARK: Search column

    private var searchColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps and publishers", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }
                    .onChange(of: searchText) {
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            search()
                        }
                    }
                if !searchText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        searchText = ""
                        search()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)

            Divider()

            if let loadError {
                ContentUnavailableView(
                    "Couldn't Load the Catalog",
                    systemImage: "exclamationmark.icloud",
                    description: Text(loadError)
                )
                .frame(maxHeight: .infinity)
            } else {
                List(titles) { title in
                    titleRow(title)
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }

            if totalCount > titles.count {
                Divider()
                Text("Showing \(titles.count) of \(totalCount) — refine the search to see more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func titleRow(_ title: Title) -> some View {
        let isSelected = apps.contains { $0.titleName == title.titleName }
        HStack(spacing: 8) {
            AsyncImage(url: title.iconUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.titleName)
                Text("\(title.publisher)\(title.version.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isSelected ? "Remove" : "Add") {
                if isSelected {
                    apps.removeAll { $0.titleName == title.titleName }
                } else {
                    apps.append(AppCatalogApp(titleName: title.titleName, publisher: title.publisher))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    // MARK: Selection column

    private var selectionColumn: some View {
        Group {
            if apps.isEmpty {
                ContentUnavailableView(
                    "No Apps Selected",
                    systemImage: "app.badge.checkmark",
                    description: Text("Add apps on the left, then choose how each one is delivered and updated.")
                )
            } else {
                List {
                    ForEach($apps) { $app in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(app.titleName)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Button("Remove", systemImage: "xmark.circle") {
                                    apps.removeAll { $0.titleName == app.titleName }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            Picker("Delivery", selection: $app.deploymentType) {
                                ForEach(AppCatalogApp.DeploymentType.allCases, id: \.self) { type in
                                    Text(type.label).tag(type)
                                }
                            }
                            Picker("Updates", selection: $app.updateBehavior) {
                                ForEach(AppCatalogApp.UpdateBehavior.allCases, id: \.self) { behavior in
                                    Text(behavior.label).tag(behavior)
                                }
                            }
                        }
                        .controlSize(.small)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Search

    private func search() {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            loadError = "The tenant's stored credentials are missing."
            return
        }
        isLoading = true
        loadError = nil
        let client = JamfPlatformClient(
            configuration: JamfAPIConfiguration(tenant: tenant, clientSecret: secret),
            activityLog: activityLog
        )
        let query = searchText.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isLoading = false }
            do {
                var items = [
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "page-size", value: "50"),
                    URLQueryItem(name: "sort", value: "titleName:asc"),
                ]
                if !query.isEmpty {
                    items.append(URLQueryItem(
                        name: "filter",
                        value: #"titleName=="*\#(query)*",publisher=="*\#(query)*""#
                    ))
                }
                let page = try await client.getDecoded(TitlesPage.self, path: "/pro/v1/app-installers/titles", query: items)
                titles = page.results
                totalCount = page.totalCount
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

#Preview {
    @Previewable @State var apps: [AppCatalogApp] = [
        AppCatalogApp(titleName: "Google Chrome", publisher: "Google"),
        AppCatalogApp(titleName: "1Password 8", publisher: "AgileBits", deploymentType: .installAutomatically, updateBehavior: .manual),
    ]
    AppCatalogPickerView(
        tenant: Tenant(
            name: "Preview Tenant",
            region: .eu,
            clientID: "preview",
            environmentID: "00000000-0000-0000-0000-000000000000",
            isProduction: false
        ),
        apps: $apps
    )
    .environment(ActivityLog())
}
