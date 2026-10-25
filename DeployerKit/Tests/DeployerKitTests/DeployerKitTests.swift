import Foundation
import Testing
@testable import DeployerKit

@Suite("Version comparison")
struct VersionComparisonTests {
    @Test(arguments: [
        ("1.1", "1.0", true),
        ("1.0", "1.1", false),
        ("1.0", "1.0", false),
        ("1.0.1", "1.0", true),
        ("1.0", "1.0.0", false),
        ("2.0", "1.9.9", true),
        ("0.10", "0.9", true),
    ])
    func comparesDotSeparatedVersions(candidate: String, installed: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: installed) == expected)
    }
}
