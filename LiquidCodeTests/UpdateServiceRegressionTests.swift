@testable import LiquidCode
import XCTest

final class UpdateServiceRegressionTests: XCTestCase {
    func testParseManifestReadsDarwinUniversal() throws {
        let json = """
        {
          "version": "0.2.0",
          "build": "12",
          "pub_date": "2026-07-09T00:00:00Z",
          "name": "LiquidCode",
          "platforms": {
            "darwin-universal": {
              "url": "LiquidCode-0.2.0.dmg",
              "updater": "LiquidCode-0.2.0.app.tar.gz",
              "updater_signature": "LiquidCode-0.2.0.app.tar.gz.sig",
              "signature": "abc123",
              "checksum": "deadbeef"
            }
          }
        }
        """
        let manifest = try UpdateService.parseManifest(Data(json.utf8))
        XCTAssertEqual(manifest.version, "0.2.0")
        XCTAssertEqual(manifest.build, "12")
        XCTAssertEqual(manifest.platform.updater, "LiquidCode-0.2.0.app.tar.gz")
        XCTAssertEqual(manifest.platform.checksum, "deadbeef")
        XCTAssertEqual(manifest.platform.signature, "abc123")
    }

    func testParseManifestRejectsMissingPlatform() {
        let json = #"{"version":"1.0.0","build":"1","platforms":{}}"#
        XCTAssertThrowsError(try UpdateService.parseManifest(Data(json.utf8)))
    }

    func testVersionComparePrefersNewerMarketingVersion() {
        XCTAssertTrue(
            UpdateService.isRemoteNewer(
                remoteVersion: "0.2.0",
                remoteBuild: "1",
                localVersion: "0.1.0",
                localBuild: "99"
            )
        )
        XCTAssertFalse(
            UpdateService.isRemoteNewer(
                remoteVersion: "0.1.0",
                remoteBuild: "99",
                localVersion: "0.2.0",
                localBuild: "1"
            )
        )
    }

    func testVersionCompareUsesBuildWhenMarketingEqual() {
        XCTAssertTrue(
            UpdateService.isRemoteNewer(
                remoteVersion: "0.1.0",
                remoteBuild: "3",
                localVersion: "0.1.0",
                localBuild: "2"
            )
        )
        XCTAssertFalse(
            UpdateService.isRemoteNewer(
                remoteVersion: "0.1.0",
                remoteBuild: "2",
                localVersion: "0.1.0",
                localBuild: "2"
            )
        )
    }

    func testAvailabilityReportsUpToDateAndAvailable() throws {
        let manifest = try UpdateService.parseManifest(Data("""
        {
          "version": "0.2.0",
          "build": "2",
          "platforms": {
            "darwin-universal": {
              "url": "a.dmg",
              "updater": "a.tar.gz",
              "updater_signature": "a.sig",
              "signature": "sig",
              "checksum": "aa"
            }
          }
        }
        """.utf8))
        if
            case .available(_, let latest, _) = UpdateService.availability(
                manifest: manifest,
                localVersion: "0.1.0",
                localBuild: "1"
            ) {
            XCTAssertEqual(latest, "0.2.0")
        } else {
            XCTFail("expected available")
        }
        if
            case .upToDate = UpdateService.availability(
                manifest: manifest,
                localVersion: "0.2.0",
                localBuild: "2"
            ) {
            // ok
        } else {
            XCTFail("expected up to date")
        }
    }

    func testVerifyRejectsChecksumMismatchAndPlaceholder() {
        let payload = Data("hello-updater".utf8)
        let goodChecksum = UpdateService.sha256Hex(payload)
        XCTAssertEqual(
            UpdateService.verify(payload: payload, checksum: "00" + String(repeating: "0", count: 62), signature: "sig"),
            .rejected(reason: "Checksum mismatch")
        )
        XCTAssertEqual(
            UpdateService.verify(payload: payload, checksum: goodChecksum, signature: ""),
            .rejected(reason: "Missing signature")
        )
        XCTAssertEqual(
            UpdateService.verify(payload: payload, checksum: goodChecksum, signature: "placeholder-not-real"),
            .rejected(reason: "Placeholder signature rejected")
        )
        if
            case .verified(let kind) = UpdateService.verify(
                payload: payload,
                checksum: goodChecksum,
                signature: "nonempty-production-style-sig"
            ) {
            XCTAssertEqual(kind, .checksumAndSignaturePresent)
        } else {
            XCTFail("expected verified with signature present")
        }
    }

    func testVerifyAcceptsDevSignatureFromReleaseHelper() throws {
        let fixture = try ReleaseFixture()
        let artifact = fixture.root.appendingPathComponent("LiquidCode-0.1.0.app.tar.gz")
        let sig = fixture.root.appendingPathComponent("LiquidCode-0.1.0.app.tar.gz.sig")
        let payload = Data("fake updater payload for app update".utf8)
        try payload.write(to: artifact)
        let result = try fixture.runHelper(["dev-signature", artifact.path, sig.path])
        XCTAssertEqual(result.status, 0, result.combinedOutput)
        let signatureText = try String(contentsOf: sig, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = UpdateService.sha256Hex(payload)
        if
            case .verified(let kind) = UpdateService.verify(
                payload: payload,
                checksum: checksum,
                signature: signatureText
            ) {
            XCTAssertEqual(kind, .devSignature)
        } else {
            XCTFail("dev signature should verify")
        }
        // Tamper payload → reject
        let tampered = Data("tampered".utf8)
        if
            case .rejected = UpdateService.verify(
                payload: tampered,
                checksum: UpdateService.sha256Hex(tampered),
                signature: signatureText
            ) {
            // ok — MAC won't match even if checksum of tampered is used... wait, we pass
            // tampered checksum so first check passes; MAC should fail.
        } else {
            // If it somehow used checksumAndSignaturePresent path because base64 decode of
            // signature still looks like dev format, MAC mismatch returns rejected.
            let outcome = UpdateService.verify(
                payload: tampered,
                checksum: UpdateService.sha256Hex(tampered),
                signature: signatureText
            )
            if case .rejected(let reason) = outcome {
                XCTAssertTrue(
                    reason.contains("MAC") || reason.contains("checksum comment"),
                    "unexpected reject reason: \(reason)"
                )
            } else {
                XCTFail("tampered payload must not verify with old signature: \(outcome)")
            }
        }
    }

    func testResolvedManifestURLPrefersSettingsThenPlist() {
        let file = URL(fileURLWithPath: "/tmp/latest.json")
        XCTAssertEqual(
            UpdateService.resolvedManifestURL(settingsURL: file.absoluteString)?.path,
            file.path
        )
        XCTAssertNil(UpdateService.resolvedManifestURL(settingsURL: "   "))
    }

    func testArtifactURLResolvesRelativeToManifest() throws {
        let manifest = URL(string: "https://example.com/releases/latest.json")!
        let url = try XCTUnwrap(UpdateService.artifactURL(named: "LiquidCode-0.2.0.app.tar.gz", manifestURL: manifest))
        XCTAssertEqual(url.absoluteString, "https://example.com/releases/LiquidCode-0.2.0.app.tar.gz")
        let absolute = try XCTUnwrap(UpdateService.artifactURL(named: "https://cdn.example.com/a.tar.gz", manifestURL: manifest))
        XCTAssertEqual(absolute.absoluteString, "https://cdn.example.com/a.tar.gz")
    }

    func testSettingsSurfaceAndUpdateServiceExist() throws {
        let models = try Self.source("LiquidCode/Models.swift")
        XCTAssertTrue(models.contains("updateManifestURL"))
        let setup = try Self.source("LiquidCode/AppModel/Setup.swift")
        XCTAssertTrue(setup.contains("checkForAppUpdates"))
        XCTAssertTrue(setup.contains("downloadAndVerifyUpdate"))
        let panels = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(panels.contains("Check for Updates") || panels.contains("L(\"Check for Updates\")"))
        let service = try Self.source("LiquidCode/UpdateService.swift")
        XCTAssertTrue(service.contains("verifyDevSignature"))
        XCTAssertTrue(service.contains("Placeholder signature rejected") || service.contains("placeholder"))
    }

    // MARK: - Helpers

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

// Local copy of ReleaseFixture helpers used by ReleaseHelperTests (same script).
private final class ReleaseFixture {
    let root: URL
    private let helperURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lc-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var dir = URL(fileURLWithPath: #filePath)
        var found: URL?
        while dir.pathComponents.count > 1 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("scripts/release-helpers.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
        }
        helperURL = try XCTUnwrap(found)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    struct RunResult {
        var status: Int32
        var combinedOutput: String
    }

    func runHelper(_ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperURL.path] + args
        process.currentDirectoryURL = root
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(status: process.terminationStatus, combinedOutput: stdout + stderr)
    }
}
