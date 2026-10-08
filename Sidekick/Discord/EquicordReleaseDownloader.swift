import Foundation

nonisolated enum EquicordArtifactLifetime: Equatable, Sendable {
    case temporary
    case retainedSource
}

nonisolated
struct EquicordReleaseArtifact: Sendable {
    let fileURL: URL
    let version: String
    let lifetime: EquicordArtifactLifetime

    nonisolated init(
        fileURL: URL,
        version: String,
        lifetime: EquicordArtifactLifetime = .temporary
    ) throws {
        let normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
        guard !normalizedVersion.isEmpty,
              normalizedVersion.count <= 128,
              normalizedVersion.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw EquicordReleaseError.invalidRelease
        }
        _ = try EquicordAsarArchive.inspect(
            fileAt: fileURL,
            maximumAcceptedBytes: 512 * 1024 * 1024
        )
        self.fileURL = fileURL
        self.version = normalizedVersion
        self.lifetime = lifetime
    }
}

nonisolated
enum EquicordReleaseError: LocalizedError {
    case invalidRelease
    case unavailableAsset
    case unexpectedResponse
    case temporaryFileCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease:
            "GitHub returned an invalid Equicord release or ASAR file."
        case .unavailableAsset:
            "The latest Equicord release does not contain desktop.asar."
        case .unexpectedResponse:
            "GitHub returned an unexpected response while downloading Equicord."
        case .temporaryFileCleanupFailed(let path):
            "The temporary Equicord download remains at \(path)."
        }
    }
}

nonisolated
private struct EquicordReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

nonisolated
private struct EquicordRelease: Decodable {
    let tagName: String
    let assets: [EquicordReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

actor EquicordReleaseDownloader {

    private let session: URLSession
    private let releaseURL = URL(string: "https://api.github.com/repos/Equicord/Equicord/releases/latest")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func downloadLatest() async throws -> EquicordReleaseArtifact {
        var request = URLRequest(url: releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sidekick Discord installer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (releaseData, releaseResponse) = try await session.data(for: request)
        guard let response = releaseResponse as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == "api.github.com",
              releaseData.count <= 2 * 1024 * 1024 else {
            throw EquicordReleaseError.unexpectedResponse
        }
        let release = try JSONDecoder().decode(EquicordRelease.self, from: releaseData)
        guard let asset = release.assets.first(where: { $0.name == "desktop.asar" }) else {
            throw EquicordReleaseError.unavailableAsset
        }
        let assetURL = asset.browserDownloadURL
        guard assetURL.scheme?.lowercased() == "https",
              assetURL.host?.lowercased() == "github.com",
              assetURL.user == nil,
              assetURL.password == nil,
              assetURL.port == nil,
              assetURL.query == nil,
              assetURL.fragment == nil,
              assetURL.path.hasPrefix("/Equicord/Equicord/releases/download/"),
              assetURL.path.hasSuffix("/desktop.asar") else {
            throw EquicordReleaseError.unavailableAsset
        }

        var assetRequest = URLRequest(url: assetURL)
        assetRequest.setValue("Sidekick Discord installer", forHTTPHeaderField: "User-Agent")
        assetRequest.timeoutInterval = 120
        let (downloadURL, assetResponse) = try await session.download(for: assetRequest)
        guard let httpResponse = assetResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              httpResponse.url?.scheme?.lowercased() == "https",
              let finalHost = httpResponse.url?.host?.lowercased(),
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(finalHost) else {
            try removeTemporaryDownload(at: downloadURL)
            throw EquicordReleaseError.unexpectedResponse
        }

        do {
            return try EquicordReleaseArtifact(fileURL: downloadURL, version: release.tagName)
        } catch {
            try removeTemporaryDownload(at: downloadURL)
            throw error
        }
    }

    private func removeTemporaryDownload(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw EquicordReleaseError.temporaryFileCleanupFailed(url.path)
        }
    }
}
