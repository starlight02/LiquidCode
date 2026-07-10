import Foundation
import XCTest

final class ReleaseHelperTests: XCTestCase {
    func testDevSignatureIsStableMarkedAndNotSha256Text() throws {
        let fixture = try ReleaseFixture()
        let artifact = fixture.root.appendingPathComponent("LiquidCode-0.1.0.app.tar.gz")
        let sig = fixture.root.appendingPathComponent("LiquidCode-0.1.0.app.tar.gz.sig")
        try Data("fake updater payload".utf8).write(to: artifact)

        let first = try fixture.runHelper(["dev-signature", artifact.path, sig.path])
        XCTAssertEqual(first.status, 0, first.combinedOutput)
        let firstSignature = try String(contentsOf: sig, encoding: .utf8)

        let second = try fixture.runHelper(["dev-signature", artifact.path, sig.path])
        XCTAssertEqual(second.status, 0, second.combinedOutput)
        let secondSignature = try String(contentsOf: sig, encoding: .utf8)
        XCTAssertEqual(firstSignature, secondSignature)

        let sha256 = "48a03a17ddddfe35debe25c439aae3e6d6a4fad31066b46f8ff394f13f539d00"
        XCTAssertNotEqual(firstSignature.trimmingCharacters(in: .whitespacesAndNewlines), sha256)
        let decoded = try XCTUnwrap(Data(base64Encoded: firstSignature.trimmingCharacters(in: .whitespacesAndNewlines)))
        let decodedText = try XCTUnwrap(String(data: decoded, encoding: .utf8))
        XCTAssertTrue(decodedText.contains("dev-only deterministic signature"))
        XCTAssertTrue(decodedText.contains("trusted comment: dev-only"))
    }

    func testUploadDryRunValidatesAndListsArtifacts() throws {
        let fixture = try ReleaseFixture()
        let artifacts = [
            "LiquidCode-0.1.0.pkg",
            "LiquidCode-0.1.0.pkg.sha256"
        ].map { fixture.root.appendingPathComponent($0) }
        for artifact in artifacts {
            try Data(artifact.lastPathComponent.utf8).write(to: artifact)
        }

        let result = try fixture.runHelper(["upload-dry-run", "v0.1.0"] + artifacts.map(\.path))
        XCTAssertEqual(result.status, 0, result.combinedOutput)
        XCTAssertTrue(result.combinedOutput.contains("GitHub release upload dry-run for v0.1.0"))
        for artifact in artifacts {
            XCTAssertTrue(result.combinedOutput.contains(artifact.lastPathComponent), result.combinedOutput)
        }
    }

    func testUploadDryRunRejectsIncompleteReleaseArtifactMatrix() throws {
        let fixture = try ReleaseFixture()
        let artifacts = [
            "LiquidCode-0.1.0.dmg"
        ].map { fixture.root.appendingPathComponent($0) }
        for artifact in artifacts {
            try Data(artifact.lastPathComponent.utf8).write(to: artifact)
        }

        let result = try fixture.runHelper(["upload-dry-run", "v0.1.0"] + artifacts.map(\.path))

        XCTAssertNotEqual(result.status, 0, "Release upload must reject a matrix without PKG")
        XCTAssertTrue(
            result.combinedOutput.contains(".pkg") || result.combinedOutput.localizedCaseInsensitiveContains("artifact"),
            result.combinedOutput
        )
    }

    func testUploadRealRunHardFailsWithoutReleaseTagBeforeGhUpload() throws {
        let fixture = try ReleaseFixture()
        let artifact = fixture.root.appendingPathComponent("LiquidCode-0.1.0.dmg")
        try Data("dmg".utf8).write(to: artifact)

        let result = try fixture.runHelper(["upload-real", "", artifact.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.combinedOutput.contains("RELEASE_UPLOAD=1 requires a release tag"), result.combinedOutput)

    }
}

private final class ReleaseFixture {
    let root: URL
    private let helperURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("liquidcode-release-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helperURL = Self.repositoryRoot().appendingPathComponent("scripts/release-helpers.sh")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func runHelper(_ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperURL.path] + arguments
        process.currentDirectoryURL = Self.repositoryRoot()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(status: process.terminationStatus, combinedOutput: String(data: data, encoding: .utf8) ?? "")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ProcessResult {
    var status: Int32
    var combinedOutput: String
}
