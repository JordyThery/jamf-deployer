import Foundation
import CryptoKit

/// Downloads and manages the Terraform binary jamformer needs for exports.
///
/// Terraform is BSL-licensed, so it is never bundled or redistributed: the
/// app downloads it from HashiCorp on first export, after explicit consent,
/// verifies the published checksum, and keeps it in Application Support.
/// Everything that writes to tenants still runs on the bundled OpenTofu.
@Observable
final class TerraformManager {
    static let pinnedVersion = "1.16.6"

    enum Status: Equatable {
        case notInstalled
        case downloading
        case installed(URL)
        case failed(String)
    }

    private(set) var status: Status = .notInstalled

    private var installURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Jamf Deployer/terraform/\(Self.pinnedVersion)/terraform")
    }

    init() {
        if FileManager.default.isExecutableFile(atPath: installURL.path) {
            status = .installed(installURL)
        }
    }

    var binaryURL: URL? {
        if case .installed(let url) = status { return url }
        return nil
    }

    /// Call only after the user consented in the export UI.
    func downloadIfNeeded() async {
        if case .installed = status { return }
        status = .downloading

        let version = Self.pinnedVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let base = "https://releases.hashicorp.com/terraform/\(version)"
        let zipName = "terraform_\(version)_darwin_\(architecture).zip"

        do {
            let (sumsData, sumsResponse) = try await URLSession.shared.data(
                from: URL(string: "\(base)/terraform_\(version)_SHA256SUMS")!
            )
            let (zipData, zipResponse) = try await URLSession.shared.data(
                from: URL(string: "\(base)/\(zipName)")!
            )
            guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
                  (zipResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw TerraformError.downloadFailed
            }

            // Verify against the published checksum.
            let expected = String(decoding: sumsData, as: UTF8.self)
                .split(separator: "\n")
                .first { $0.hasSuffix(zipName) }?
                .split(separator: " ").first.map(String.init)
            let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected == actual else {
                throw TerraformError.checksumMismatch
            }

            // Unpack with the system unzip into place.
            let staging = FileManager.default.temporaryDirectory
                .appending(path: "jamf-deployer-terraform-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let zipURL = staging.appending(path: zipName)
            try zipData.write(to: zipURL)

            let unzip = Process()
            unzip.executableURL = URL(filePath: "/usr/bin/unzip")
            unzip.arguments = ["-oq", zipURL.path, "-d", staging.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { throw TerraformError.unpackFailed }

            try FileManager.default.createDirectory(
                at: installURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: installURL)
            try FileManager.default.moveItem(at: staging.appending(path: "terraform"), to: installURL)
            try? FileManager.default.removeItem(at: staging)

            status = .installed(installURL)
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    nonisolated enum TerraformError: LocalizedError {
        case downloadFailed
        case checksumMismatch
        case unpackFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                "Terraform could not be downloaded from HashiCorp. Check your connection and try again."
            case .checksumMismatch:
                "The downloaded Terraform did not match its published checksum, so it was discarded."
            case .unpackFailed:
                "The Terraform download could not be unpacked."
            }
        }
    }
}
