import Foundation

struct GitHubRelease: Equatable, Sendable {
    var tagName: String
    var name: String?
    var body: String
    var htmlURL: URL
    var publishedAt: Date?
    var draft: Bool
    var prerelease: Bool

    var version: String {
        UpdateService.normalizedVersion(tagName)
    }

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "LiquidCode \(version)" : trimmedName
    }
}

extension GitHubRelease: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
    }
}

enum UpdateAvailability: Equatable, Sendable {
    case upToDate(current: String)
    case available(current: String, release: GitHubRelease)
    case unknown(reason: String)
}

enum UpdateService {
    static let repositoryOwner = "starlight02"
    static let repositoryName = "LiquidCode"
    static let latestReleaseURL: URL = {
        let path = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
        guard let url = URL(string: path) else {
            preconditionFailure("Invalid GitHub latest-release URL: \(path)")
        }
        return url
    }()

    static func parseRelease(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let release = try decoder.decode(GitHubRelease.self, from: data)
            let tag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !tag.isEmpty,
                !release.version.isEmpty,
                release.htmlURL.scheme == "https",
                release.htmlURL.host?.lowercased() == "github.com"
            else {
                throw UpdateError.invalidRelease
            }
            return release
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.invalidRelease
        }
    }

    static func currentAppVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func currentAppBuild(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static func normalizedVersion(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "v" || trimmed.first == "V" else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    static func isRemoteNewer(remoteVersion: String, localVersion: String) -> Bool {
        CLIService.versionGreater(
            normalizedVersion(remoteVersion),
            than: normalizedVersion(localVersion)
        )
    }

    static func availability(release: GitHubRelease, localVersion: String) -> UpdateAvailability {
        guard !release.draft else {
            return .unknown(reason: L("GitHub returned a draft release."))
        }
        guard !release.prerelease else {
            return .unknown(reason: L("GitHub returned a prerelease."))
        }
        if isRemoteNewer(remoteVersion: release.version, localVersion: localVersion) {
            return .available(current: normalizedVersion(localVersion), release: release)
        }
        return .upToDate(current: normalizedVersion(localVersion))
    }

    static func fetchLatestRelease(session: URLSession = .shared) async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LiquidCode/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        if http.statusCode == 403 || http.statusCode == 429, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            let resetAt = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            throw UpdateError.rateLimited(resetAt: resetAt)
        }
        if http.statusCode == 404 {
            throw UpdateError.releaseNotFound
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GitHubErrorResponse.self, from: data).message)
            throw UpdateError.github(statusCode: http.statusCode, message: message)
        }
        return try parseRelease(data)
    }
}

private struct GitHubErrorResponse: Decodable {
    var message: String
}

enum UpdateError: LocalizedError, Equatable {
    case invalidRelease
    case invalidResponse
    case releaseNotFound
    case rateLimited(resetAt: Date?)
    case github(statusCode: Int, message: String?)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease:
            return L("GitHub returned an invalid release response.")
        case .invalidResponse:
            return L("GitHub returned an invalid HTTP response.")
        case .releaseNotFound:
            return L("No published LiquidCode release was found on GitHub.")
        case .rateLimited(let resetAt):
            if let resetAt {
                return LF("GitHub rate limit reached. Try again after %@.", resetAt.formatted(date: .abbreviated, time: .shortened))
            }
            return L("GitHub rate limit reached. Try again later.")
        case .github(let statusCode, let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return detail.isEmpty
                ? LF("GitHub update check failed (HTTP %d).", statusCode)
                : LF("GitHub update check failed (HTTP %d): %@", statusCode, detail)
        case .network(let message):
            return LF("Could not reach GitHub: %@", message)
        }
    }
}
