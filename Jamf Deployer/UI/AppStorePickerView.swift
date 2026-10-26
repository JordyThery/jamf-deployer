import SwiftUI
import JTKit
import JamfDeployerCore

/// Picks App Store apps the tenant holds Apps and Books licenses for, for
/// the Mac or the iPad and iPhone App Store block.
struct AppStorePickerView: View {
    enum Platform {
        case mac
        case mobile

        var title: String {
            switch self {
            case .mac: "Mac App Store Apps"
            case .mobile: "iPad and iPhone Apps"
            }
        }

        /// Apps and Books content types listed for this platform.
        func includes(_ contentType: String) -> Bool {
            switch self {
            case .mac: contentType.contains("MAC")
            case .mobile: contentType.contains("IOS")
            }
        }
    }

    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.dismiss) private var dismiss

    let tenant: Tenant
    let platform: Platform
    @Binding var apps: [AppStoreApp]
    @Binding var locationName: String

    nonisolated private struct Location: Decodable, Identifiable, Sendable, Hashable {
        var id: String
        var name: String
    }

    nonisolated private struct Content: Decodable, Identifiable, Sendable {
        var adamId: String
        var name: String
        var contentType: String
        var iconUrl: String?
        var licenseCountTotal: Int?
        var licenseCountInUse: Int?
        var id: String { adamId }
    }

    @State private var locations: [Location] = []
    @State private var content: [Content] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var categories: [ExistingObjectRef] = []

    private var visibleContent: [Content] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return content
            .filter { platform.includes($0.contentType) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SheetFrame(
            title: "\(platform.title) — \(tenant.name)",
            systemImage: platform == .mac ? "app.badge" : "ipad.and.iphone",
            isBusy: isLoading
        ) {
            HStack(spacing: 0) {
                contentColumn
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
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(width: 760, height: 540)
        .task { await loadLocations() }
        .task {
            categories = (try? await ExistingObjectService.categories(tenant: tenant, activityLog: activityLog)) ?? []
        }
    }

    // MARK: Licensed apps

    private var contentColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if locations.count > 1 {
                    Picker("Apps and Books location", selection: $locationName) {
                        ForEach(locations) { location in
                            Text(location.name).tag(location.name)
                        }
                    }
                    .onChange(of: locationName) { Task { await loadContent(locationNamed: locationName) } }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter licensed apps", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(10)

            Divider()

            if let loadError {
                ContentUnavailableView(
                    "Apps and Books Unavailable",
                    systemImage: "exclamationmark.icloud",
                    description: Text(loadError)
                )
                .frame(maxHeight: .infinity)
            } else if !isLoading && visibleContent.isEmpty {
                ContentUnavailableView(
                    "No Licensed Apps",
                    systemImage: "bag",
                    description: Text(locations.isEmpty
                        ? "This tenant has no Apps and Books location. Connect one in Jamf Pro (Settings → Global → Volume purchasing) first."
                        : "Get apps for this location in Apple Business Manager — free apps too — and Jamf lists them here after its next sync.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(visibleContent) { item in
                    contentRow(item)
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func contentRow(_ item: Content) -> some View {
        let isSelected = apps.contains { $0.adamID == item.adamId }
        HStack(spacing: 8) {
            AsyncImage(url: item.iconUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                if let total = item.licenseCountTotal {
                    Text("\(item.licenseCountInUse ?? 0) of \(total) licenses in use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(isSelected ? "Remove" : "Add") {
                if isSelected {
                    apps.removeAll { $0.adamID == item.adamId }
                } else {
                    apps.append(AppStoreApp(adamID: item.adamId, name: item.name))
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    // MARK: Selection

    private var selectionColumn: some View {
        Group {
            if apps.isEmpty {
                ContentUnavailableView(
                    "No Apps Selected",
                    systemImage: "app.badge.checkmark",
                    description: Text("Add licensed apps on the left, then choose how each one is delivered. Every tenant this block deploys to needs licenses for the same apps.")
                )
            } else {
                List {
                    ForEach($apps) { $app in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(app.name)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Button("Remove", systemImage: "xmark.circle") {
                                    apps.removeAll { $0.adamID == app.adamID }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            Picker("Delivery", selection: $app.deploymentType) {
                                ForEach(AppStoreApp.DeploymentType.allCases, id: \.self) { type in
                                    Text(type.label).tag(type)
                                }
                            }
                            Picker("Category", selection: categoryBinding($app)) {
                                Text("Same as the block").tag("")
                                if let id = app.categoryID, !categories.contains(where: { $0.id == id }) {
                                    Text(app.categoryName ?? id).tag(id)
                                }
                                ForEach(categories, id: \.id) { category in
                                    Text(category.name).tag(category.id)
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

    private func categoryBinding(_ app: Binding<AppStoreApp>) -> Binding<String> {
        Binding(
            get: { app.wrappedValue.categoryID ?? "" },
            set: { id in
                app.wrappedValue.categoryID = id.isEmpty ? nil : id
                app.wrappedValue.categoryName = id.isEmpty ? nil : categories.first { $0.id == id }?.name ?? app.wrappedValue.categoryName
            }
        )
    }

    // MARK: Loading

    private func client() -> JamfPlatformClient? {
        guard TenantSecrets(tenantID: tenant.id).platformClientSecret.load() != nil else {
            loadError = "The tenant's stored credentials are missing."
            return nil
        }
        return TenantClients.shared.client(for: tenant, activityLog: activityLog)
    }

    private func loadLocations() async {
        guard let client = client() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            locations = try await client.allPages("/pro/v1/volume-purchasing-locations", as: Location.self,
                                                  privileges: [.readVolumePurchasingLocations])
            // The binding writes through the tenant store, so read the
            // choice from a local rather than back from the binding.
            let chosen = locations.contains(where: { $0.name == locationName }) ? locationName : (locations.first?.name ?? "")
            if chosen != locationName { locationName = chosen }
            await loadContent(locationNamed: chosen)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadContent(locationNamed name: String) async {
        guard let location = locations.first(where: { $0.name == name }), let client = client() else {
            content = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await client.allPages(
                "/pro/v1/volume-purchasing-locations/\(location.id)/content", as: Content.self,
                pageSize: 2000, privileges: [.readVolumePurchasingLocations]
            )
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
