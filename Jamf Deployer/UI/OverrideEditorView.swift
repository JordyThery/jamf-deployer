import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Keeps a parsed provider schema cached on disk, generating it once from
/// the bundled engine (`tofu providers schema -json`).
actor SchemaProvider {
    static let shared = SchemaProvider()

    private var cached: ProviderSchemaCatalog?

    func catalog() async throws -> ProviderSchemaCatalog {
        if let cached { return cached }

        // Named by plugin versions, so an app update with newer plugins
        // regenerates the schema.
        let versions = [EngineInfo.jamfPlatformProviderVersion, EngineInfo.jamfProtectProviderVersion, EngineInfo.jamfProProviderVersion]
        let cacheURL = URL.applicationSupportDirectory
            .appending(path: "Jamf Deployer/engine/providers-schema-\(versions.joined(separator: "-")).json")
        if let data = try? Data(contentsOf: cacheURL),
           let parsed = try? ProviderSchemaCatalog.parse(schemaJSON: data) {
            cached = parsed
            return parsed
        }

        // One-time generation in a scratch workspace with every plugin.
        let workspace = URL.applicationSupportDirectory
            .appending(path: "Jamf Deployer/engine/schema-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // Release builds re-sign the plugin archives, so a lock file or
        // plugin cache from another build no longer matches.
        for leftover in [".terraform.lock.hcl", ".terraform"] {
            try? FileManager.default.removeItem(at: workspace.appending(path: leftover))
        }
        try Data("""
        terraform {
          required_providers {
            jamfplatform = {
              source  = "jamf/jamfplatform"
              version = "\(EngineInfo.jamfPlatformProviderVersion)"
            }
            jamfprotect = {
              source  = "Jamf-Concepts/jamfprotect"
              version = "\(EngineInfo.jamfProtectProviderVersion)"
            }
            jamfpro = {
              source  = "deploymenttheory/jamfpro"
              version = "\(EngineInfo.jamfProProviderVersion)"
            }
          }
        }
        """.utf8).write(to: workspace.appending(path: "main.tf"))

        let runner = EngineRunner(configuration: EngineRunner.Configuration(
            engineURL: EngineLocator.tofuURL,
            workingDirectory: workspace,
            cliConfigURL: try EngineLocator.ensureCLIConfig(),
            environment: [:]
        ))
        try await runner.run(arguments: ["init", "-input=false", "-backend=false"])
        let data = try await runner.rawCommandOutput(arguments: ["providers", "schema", "-json"])
        try data.write(to: cacheURL)
        let parsed = try ProviderSchemaCatalog.parse(schemaJSON: data)
        cached = parsed
        return parsed
    }
}

/// "Add a Custom Object": a form built live from the provider schema, for
/// objects the catalog doesn't cover — no HCL required.
struct OverrideEditorView: View {
    @Environment(TenantDeployService.self) private var deployService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false

    let tenant: Tenant

    @State private var catalog: ProviderSchemaCatalog?
    @State private var searchText = ""
    @State private var selectedTypeName: String?
    @State private var objectName = ""
    @State private var values: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        SheetFrame(
            title: "Add a Custom Object — \(tenant.name)",
            systemImage: "plus.rectangle.on.rectangle",
            isBusy: catalog == nil
        ) {
            content
        } footer: {
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Stage Object") { stage() }
                .buttonStyle(.borderedProminent)
                .disabled(!canStage)
        }
        .frame(width: 680, height: 560)
        .task {
            do {
                catalog = try await SchemaProvider.shared.catalog()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var selectedType: ProviderSchemaCatalog.ResourceType? {
        guard let selectedTypeName, let catalog else { return nil }
        return catalog.resourceType(named: selectedTypeName)
    }

    private var canStage: Bool {
        guard let type = selectedType, !objectName.isEmpty else { return false }
        return type.requiredPrimitives.allSatisfy { !(values[$0.name] ?? "").isEmpty || $0.kind == .bool }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            // Type list.
            VStack(spacing: 0) {
                TextField("Filter object types", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(filteredTypes, selection: $selectedTypeName) { type in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(friendlyName(type.name))
                        Text(type.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .tag(type.name)
                }
                .listStyle(.inset)
            }
            .frame(width: 290)

            Divider()

            // Form.
            if let type = selectedType {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Object name (for the record)", text: $objectName, prompt: Text("my_custom_object"))
                            .font(.callout.monospaced())
                            .help("Internal name in the tenant record — lowercase with underscores")

                        attributeFields(type.requiredPrimitives, header: "Required")
                        attributeFields(type.optionalPrimitives, header: "Optional")

                        if !type.sensitiveWritables.isEmpty {
                            Text("Secret values (\(type.sensitiveWritables.map(\.name).joined(separator: ", "))) are left out: this form writes plain configuration files. Set them in Jamf after deploying.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !type.complexWritables.isEmpty {
                            Text("Not editable here yet: \(type.complexWritables.map(\.name).joined(separator: ", ")). Capture an export or edit a block for objects needing these.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if showsTechnicalDetails, canStage {
                            GroupBox("Generated configuration") {
                                Text(previewHCL(type))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(4)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "Pick an Object Type",
                    systemImage: "square.grid.3x1.folder.badge.plus",
                    description: Text("Every type the Jamf providers support is listed — the form is built from the live schema.")
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var filteredTypes: [ProviderSchemaCatalog.ResourceType] {
        // Only types the tenant's connection can manage.
        let all = (catalog?.resourceTypes ?? []).filter { type in
            type.isFormEditable && (type.name.hasPrefix("jamfpro_") == tenant.isJamfPro)
        }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    @ViewBuilder
    private func attributeFields(_ attributes: [ProviderSchemaCatalog.Attribute], header: String) -> some View {
        if !attributes.isEmpty {
            Text(header)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(attributes) { attribute in
                let binding = Binding(
                    get: { values[attribute.name] ?? "" },
                    set: { values[attribute.name] = $0 }
                )
                VStack(alignment: .leading, spacing: 2) {
                    switch attribute.kind {
                    case .bool:
                        Toggle(attribute.name, isOn: Binding(
                            get: { binding.wrappedValue == "true" },
                            set: { binding.wrappedValue = $0 ? "true" : "false" }
                        ))
                    case .number:
                        TextField(attribute.name, text: binding, prompt: Text("0"))
                            .frame(maxWidth: 220)
                    case .stringList:
                        TextField("\(attribute.name) (comma-separated)", text: binding)
                    case .string, .complex:
                        TextField(attribute.name, text: binding)
                    }
                    if !attribute.description.isEmpty {
                        Text(attribute.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func friendlyName(_ typeName: String) -> String {
        typeName
            .replacingOccurrences(of: "jamfplatform_pro_", with: "")
            .replacingOccurrences(of: "jamfplatform_", with: "")
            .replacingOccurrences(of: "jamfpro_", with: "")
            .replacingOccurrences(of: "jamfprotect_", with: "Protect: ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func previewHCL(_ type: ProviderSchemaCatalog.ResourceType) -> String {
        OverrideGenerator.hcl(
            resourceType: type.name,
            terraformName: sanitizedObjectName,
            values: (type.requiredPrimitives + type.optionalPrimitives).map { ($0, values[$0.name] ?? "") }
        )
    }

    private var sanitizedObjectName: String {
        let cleaned = objectName.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(cleaned)
    }

    private func stage() {
        guard let type = selectedType else { return }
        do {
            let hcl = previewHCL(type)
            let destination = deployService.adoptedURL(for: tenant)
                .appending(path: "override-\(sanitizedObjectName).tf")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(hcl.utf8).write(to: destination)
            dismiss()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
