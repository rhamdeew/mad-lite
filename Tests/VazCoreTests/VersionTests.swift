import Foundation
import Testing
@testable import VazCore

@Suite struct VersionTests {
    /// The version in code is the latest release in CHANGELOG.md, and it is semver.
    @Test func versionMatchesChangelog() throws {
        let changelog = try String(contentsOf: firmwareDir.deletingLastPathComponent().appendingPathComponent("CHANGELOG.md"),
                                   encoding: .utf8)
        let latest = try #require(changelog.firstMatch(of: /## \[(\d+\.\d+\.\d+)\]/)?.1)
        #expect(String(latest) == AppVersion.current)
        #expect(AppVersion.current.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
    }
}
