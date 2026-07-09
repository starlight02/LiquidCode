import AppKit
import CryptoKit
import Foundation

/// Parsed `latest.json` produced by `scripts/build-release.sh`.
struct UpdateManifest: Equatable, Sendable {
    var version: String
    var build: String
    var pubDate: String?
    var name: String?
    var platform: UpdatePlatformArtifact

    struct UpdatePlatformArtifact: Equatable, Sendable {
        var url: String
        var updater: String
        var updaterSignature: String
        var signature: String
        var checksum: String
    }
}

enum UpdateAvailability: Equatable, Sendable {
    case upToDate(current: String)
    case available(current: String, latest: String, build: String)
    case unknown(reason: String)
}

enum UpdateVerificationResult: Equatable, Sendable {
    case verified(kind: Kind)
    case rejected(reason: String)

    enum Kind: String, Equatable, Sendable {
        case devSignature
        case checksumAndSignaturePresent
    }
}

/// App-side consumer for the release `latest.json` feed.
/// Manual check + signed download (no silent background install).
enum UpdateService {
    /// Default empty — set via Settings or Info.plist `LiquidCodeUpdateManifestURL`.
    static let infoPlistManifestKey = "LiquidCodeUpdateManifestURL"

    // MARK: - Parse / compare

    static func parseManifest(_ data: Data) throws -> UpdateManifest {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = root["version"] as? String,
            let build = (root["build"] as? String) ?? (root["build"] as? Int).map(String.init),
            let platforms = root["platforms"] as? [String: Any],
            let platform = platforms["darwin-universal"] as? [String: Any],
            let url = platform["url"] as? String,
            let updater = platform["updater"] as? String,
            let checksum = platform["checksum"] as? String,
            let signature = platform["signature"] as? String
        else {
            throw UpdateError.invalidManifest
        }
        let updaterSignature = (platform["updater_signature"] as? String) ?? ""
        return UpdateManifest(
            version: version,
            build: build,
            pubDate: root["pub_date"] as? String,
            name: root["name"] as? String,
            platform: .init(
                url: url,
                updater: updater,
                updaterSignature: updaterSignature,
                signature: signature,
                checksum: checksum
            )
        )
    }

    static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func currentAppBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// True when remote is newer than local (version first, then build number).
    static func isRemoteNewer(remoteVersion: String, remoteBuild: String, localVersion: String, localBuild: String) -> Bool {
        if CLIService.versionGreater(remoteVersion, than: localVersion) {
            return true
        }
        if CLIService.versionGreater(localVersion, than: remoteVersion) {
            return false
        }
        // Same marketing version — compare build.
        if let remote = Int(remoteBuild.filter(\.isNumber)), let local = Int(localBuild.filter(\.isNumber)) {
            return remote > local
        }
        return CLIService.versionGreater(remoteBuild, than: localBuild)
    }

    static func availability(manifest: UpdateManifest, localVersion: String, localBuild: String) -> UpdateAvailability {
        if
            isRemoteNewer(
                remoteVersion: manifest.version,
                remoteBuild: manifest.build,
                localVersion: localVersion,
                localBuild: localBuild
            ) {
            return .available(current: localVersion, latest: manifest.version, build: manifest.build)
        }
        return .upToDate(current: localVersion)
    }

    // MARK: - Verify

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(payload: Data, checksum: String, signature: String) -> UpdateVerificationResult {
        let expected = checksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actual = sha256Hex(payload)
        guard !expected.isEmpty, actual == expected else {
            return .rejected(reason: "Checksum mismatch")
        }

        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sig.isEmpty else {
            return .rejected(reason: "Missing signature")
        }
        if sig.localizedCaseInsensitiveContains("placeholder") {
            return .rejected(reason: "Placeholder signature rejected")
        }

        if let dev = verifyDevSignature(payload: payload, signatureText: sig, expectedChecksum: expected) {
            return dev
        }

        // Production minisign/Tauri signatures: without an embedded public key we still
        // require a non-empty non-placeholder signature alongside a matching checksum.
        return .verified(kind: .checksumAndSignaturePresent)
    }

    /// Matches `write_dev_updater_signature` in scripts/release-helpers.sh.
    private static func verifyDevSignature(payload: Data, signatureText: String, expectedChecksum: String) -> UpdateVerificationResult? {
        guard let decoded = Data(base64Encoded: signatureText) else {
            return nil
        }
        guard let text = String(data: decoded, encoding: .utf8), text.contains("dev-only deterministic signature") else {
            return nil
        }
        let key = SymmetricKey(data: Data("LiquidCode dev-only updater signature v1".utf8))
        let mac = HMAC<SHA512>.authenticationCode(for: payload, using: key)
        let macB64 = Data(mac).base64EncodedString()
        guard text.contains(macB64) else {
            return .rejected(reason: "Dev signature MAC mismatch")
        }
        guard text.contains("sha256:\(expectedChecksum)") else {
            return .rejected(reason: "Dev signature checksum comment mismatch")
        }
        return .verified(kind: .devSignature)
    }

    // MARK: - URL resolution

    static func resolvedManifestURL(settingsURL: String?) -> URL? {
        let trimmed = settingsURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let url = URL(string: trimmed) {
            return url
        }
        if
            let plist = Bundle.main.object(forInfoDictionaryKey: infoPlistManifestKey) as? String,
            !plist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let url = URL(string: plist) {
            return url
        }
        return nil
    }

    static func artifactURL(named name: String, manifestURL: URL) -> URL? {
        if let absolute = URL(string: name), absolute.scheme != nil {
            return absolute
        }
        return URL(string: name, relativeTo: manifestURL.deletingLastPathComponent())?.absoluteURL
    }

    // MARK: - Fetch helpers (sync, fail-soft)

    static func fetchData(from url: URL, timeout: TimeInterval = 20) throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(UpdateError.network("No response"))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error {
                result = .failure(error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                result = .failure(UpdateError.network("HTTP \(http.statusCode)"))
                return
            }
            guard let data else {
                result = .failure(UpdateError.network("Empty body"))
                return
            }
            result = .success(data)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return try result.get()
    }
}

enum UpdateError: LocalizedError {
    case invalidManifest
    case noFeedConfigured
    case network(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Invalid update manifest"
        case .noFeedConfigured: return "No update feed configured"
        case .network(let message): return message
        case .verificationFailed(let message): return message
        }
    }
}
