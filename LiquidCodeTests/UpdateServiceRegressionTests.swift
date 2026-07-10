@testable import LiquidCode
import XCTest

final class UpdateServiceRegressionTests: XCTestCase {
    func testLatestReleaseEndpointIsFixedToLiquidCodeRepository() {
        XCTAssertEqual(
            UpdateService.latestReleaseURL.absoluteString,
            "https://api.github.com/repos/starlight02/LiquidCode/releases/latest"
        )
    }

    func testParseReleaseReadsGitHubFields() throws {
        let release = try UpdateService.parseRelease(Data("""
        {
          "tag_name": "v0.2.0",
          "name": "LiquidCode 0.2.0",
          "body": "New settings and update flow.",
          "html_url": "https://github.com/starlight02/LiquidCode/releases/tag/v0.2.0",
          "published_at": "2026-07-09T12:30:00Z",
          "draft": false,
          "prerelease": false
        }
        """.utf8))

        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.name, "LiquidCode 0.2.0")
        XCTAssertEqual(release.body, "New settings and update flow.")
        XCTAssertEqual(
            release.htmlURL.absoluteString,
            "https://github.com/starlight02/LiquidCode/releases/tag/v0.2.0"
        )
        XCTAssertNotNil(release.publishedAt)
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
    }

    func testParseReleaseUsesSafeDefaultsForOptionalGitHubFields() throws {
        let release = try UpdateService.parseRelease(Data("""
        {
          "tag_name": "0.2.0",
          "html_url": "https://github.com/starlight02/LiquidCode/releases/tag/0.2.0"
        }
        """.utf8))

        XCTAssertNil(release.name)
        XCTAssertEqual(release.body, "")
        XCTAssertNil(release.publishedAt)
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.displayName, "LiquidCode 0.2.0")
    }

    func testParseReleaseRejectsMissingTagAndNonGitHubURL() {
        XCTAssertThrowsError(try UpdateService.parseRelease(Data("""
        {
          "html_url": "https://github.com/starlight02/LiquidCode/releases/latest"
        }
        """.utf8))) { error in
            XCTAssertEqual(error as? UpdateError, .invalidRelease)
        }

        XCTAssertThrowsError(try UpdateService.parseRelease(Data("""
        {
          "tag_name": "v0.2.0",
          "html_url": "https://example.com/LiquidCode/v0.2.0"
        }
        """.utf8))) { error in
            XCTAssertEqual(error as? UpdateError, .invalidRelease)
        }
    }

    func testVersionComparisonNormalizesLeadingV() {
        XCTAssertTrue(UpdateService.isRemoteNewer(remoteVersion: "v0.2.0", localVersion: "0.1.7"))
        XCTAssertFalse(UpdateService.isRemoteNewer(remoteVersion: "v0.1.7", localVersion: "0.1.7"))
        XCTAssertFalse(UpdateService.isRemoteNewer(remoteVersion: "0.1.6", localVersion: "v0.1.7"))
    }

    func testAvailabilityReportsAvailableAndUpToDate() throws {
        let release = try makeRelease(tag: "v0.2.0")
        if
            case .available(let current, let latestRelease) = UpdateService.availability(
                release: release,
                localVersion: "0.1.7"
            ) {
            XCTAssertEqual(current, "0.1.7")
            XCTAssertEqual(latestRelease.version, "0.2.0")
        } else {
            XCTFail("expected available")
        }

        if
            case .upToDate(let current) = UpdateService.availability(
                release: release,
                localVersion: "0.2.0"
            ) {
            XCTAssertEqual(current, "0.2.0")
        } else {
            XCTFail("expected up to date")
        }
    }

    func testAvailabilityRejectsDraftsAndPrereleases() throws {
        var release = try makeRelease(tag: "v0.3.0")
        release.draft = true
        if case .unknown(let reason) = UpdateService.availability(release: release, localVersion: "0.1.7") {
            XCTAssertEqual(reason, L("GitHub returned a draft release."))
        } else {
            XCTFail("draft must not be offered")
        }

        release.draft = false
        release.prerelease = true
        if case .unknown(let reason) = UpdateService.availability(release: release, localVersion: "0.1.7") {
            XCTAssertEqual(reason, L("GitHub returned a prerelease."))
        } else {
            XCTFail("prerelease must not be offered")
        }
    }

    func testSettingsAndSetupUseGitHubReleaseContractOnly() throws {
        let models = try Self.source("LiquidCode/Models.swift")
        XCTAssertTrue(models.contains("var accent: AccentTheme"), "accent remains persisted for a future release")
        XCTAssertFalse(models.contains("updateManifestURL"))

        let setup = try Self.source("LiquidCode/AppModel/Setup.swift")
        XCTAssertTrue(setup.contains("fetchLatestRelease"))
        XCTAssertTrue(setup.contains("openAppUpdateRelease"))
        XCTAssertFalse(setup.contains("downloadAndVerifyUpdate"))

        let panels = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(panels.contains("Open GitHub Release"))
        XCTAssertFalse(panels.contains("latest.json URL"))
        XCTAssertFalse(panels.contains("ForEach(AccentTheme.allCases)"))

        let service = try Self.source("LiquidCode/UpdateService.swift")
        XCTAssertTrue(service.contains("session.data(for: request)"))
        XCTAssertFalse(service.contains("DispatchSemaphore"))
        XCTAssertFalse(service.contains("verifyDevSignature"))
    }

    private func makeRelease(tag: String) throws -> GitHubRelease {
        try UpdateService.parseRelease(Data("""
        {
          "tag_name": "\(tag)",
          "name": "LiquidCode \(tag)",
          "body": "Release notes",
          "html_url": "https://github.com/starlight02/LiquidCode/releases/tag/\(tag)",
          "published_at": "2026-07-09T12:30:00Z",
          "draft": false,
          "prerelease": false
        }
        """.utf8))
    }

    private static func source(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.pathComponents.count > 1 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
