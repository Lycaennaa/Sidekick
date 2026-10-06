import AppKit
import CoreServices
import UniformTypeIdentifiers
@MainActor
final class ClipboardImagePreviewOpener {
    typealias PreviewApplicationResolver = @MainActor () -> URL?
    typealias OpenInApplication = @MainActor @Sendable (
        [URL],
        URL,
        @escaping @Sendable (NSRunningApplication?, Error?) -> Void
    ) -> Void
    typealias OpenWithDefaultApplication = @MainActor @Sendable (
        URL,
        @escaping @Sendable (NSRunningApplication?, Error?) -> Void
    ) -> Void
    typealias OpenResultHandler = @MainActor (Bool) -> Void
    // Raw completion supports owned-process cleanup; result callback remains lifecycle-gated.
    typealias ApplicationResolutionHandler = @MainActor (NSRunningApplication?) async -> Void
    typealias RequestValidity = @MainActor @Sendable () -> Bool

    private let settings: AppSettings
    private let artifactStore: ClipboardImagePreviewArtifactStore
    private let resolvePreviewApplication: PreviewApplicationResolver
    private let openInApplication: OpenInApplication
    private let openWithDefaultApplication: OpenWithDefaultApplication
    private let onApplicationResolved: ApplicationResolutionHandler
    private let onOpenResult: OpenResultHandler
    private let onFailure: @MainActor () -> Void
    private var isTerminated = false

    init(
        settings: AppSettings,
        artifactStore: ClipboardImagePreviewArtifactStore? = nil,
        resolvePreviewApplication: @escaping PreviewApplicationResolver = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        },
        openInApplication: @escaping OpenInApplication = { urls, applicationURL, completion in
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: { application, error in completion(application, error) }
            )
        },
        openWithDefaultApplication: @escaping OpenWithDefaultApplication = { url, completion in
            NSWorkspace.shared.open(
                url,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: completion
            )
        },
        onApplicationResolved: @escaping ApplicationResolutionHandler = { _ in },
        onOpenResult: @escaping OpenResultHandler = { _ in },
        onFailure: @escaping @MainActor () -> Void = {}
    ) {
        self.settings = settings
        self.artifactStore = artifactStore ?? ClipboardImagePreviewArtifactStore()
        self.resolvePreviewApplication = resolvePreviewApplication
        self.openInApplication = openInApplication
        self.openWithDefaultApplication = openWithDefaultApplication
        self.onApplicationResolved = onApplicationResolved
        self.onOpenResult = onOpenResult
        self.onFailure = onFailure
        self.isTerminated = false
    }

    func open(
        _ request: ClipboardImageEnrichmentRequest,
        isCurrent: @escaping RequestValidity = { true }
    ) {
        guard !isTerminated, isCurrent() else { return }

        switch request.source {
        case let .data(data, typeIdentifier):
            artifactStore.materialize(data: data, typeIdentifier: typeIdentifier) { [weak self] url in
                guard let self else { return }
                guard let url else {
                    self.reportFailure(isCurrent: isCurrent)
                    return
                }
                guard !self.isTerminated, isCurrent() else {
                    self.artifactStore.remove(url)
                    return
                }
                self.openInPreview(
                    url,
                    removeArtifactOnFailure: true,
                    isCurrent: isCurrent
                )
            }
        case let .localFile(url, typeIdentifier):
            guard isLocalFileURL(url),
                  UTType(typeIdentifier)?.conforms(to: .image) == true,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                reportFailure(isCurrent: isCurrent)
                return
            }
            openInPreview(
                url,
                removeArtifactOnFailure: false,
                isCurrent: isCurrent
            )
        }
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        artifactStore.terminate()
    }

    private func openInPreview(
        _ url: URL,
        removeArtifactOnFailure: Bool,
        isCurrent: @escaping RequestValidity
    ) {
        let onApplicationResolved = self.onApplicationResolved
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    await onApplicationResolved(application)
                    return
                }
                let succeeded = error == nil
                if !succeeded,
                   removeArtifactOnFailure {
                    self.artifactStore.remove(url)
                }
                await onApplicationResolved(application)
                guard !self.isTerminated, isCurrent() else { return }
                self.onOpenResult(succeeded)
                if !succeeded {
                    self.reportFailure(isCurrent: isCurrent)
                }
            }
        }
        if let applicationURL = resolveOpeningApplication() {
            openInApplication([url], applicationURL, completion)
        } else {
            openWithDefaultApplication(url, completion)
        }
    }
    private func resolveOpeningApplication() -> URL? {
        if let applicationURL = settings.clipboardImageOpeningApplicationURL {
            return applicationURL
        }
        return resolvePreviewApplication()
    }
    private func reportFailure(isCurrent: @escaping RequestValidity) {
        guard !isTerminated, isCurrent() else { return }
        onFailure()
    }
}

struct ClipboardImageOpeningApplication: Equatable {
    let url: URL
    let name: String
}

struct ClipboardImageOpeningApplicationMetadata: Equatable {
    let name: String
    let handlesWebURLs: Bool
}

struct ClipboardImageOpeningApplicationCandidate: Equatable {
    let application: ClipboardImageOpeningApplication
    let isTextHandler: Bool
    let handlesWebURLs: Bool
}

enum ClipboardImageOpeningApplicationPolicy {
    static func filtered(
        candidates: [ClipboardImageOpeningApplicationCandidate]
    ) -> [ClipboardImageOpeningApplication] {
        var seenPaths = Set<String>()
        return candidates
            .compactMap { candidate in
                guard !candidate.isTextHandler,
                      !candidate.handlesWebURLs,
                      seenPaths.insert(candidate.application.url.standardizedFileURL.path).inserted
                else {
                    return nil
                }
                return candidate.application
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

@MainActor
enum ClipboardImageOpeningApplications {
    private static let defaultDiscovery = ClipboardImageOpeningApplicationDiscovery()

    static func advertised() -> [ClipboardImageOpeningApplication] {
        ClipboardImageOpeningApplicationPolicy.filtered(
            candidates: defaultDiscovery.discover()
        )
    }

    static func previewApplication() -> ClipboardImageOpeningApplication? {
        defaultDiscovery.previewApplication()
    }

    static func applicationName(for url: URL) -> String {
        ClipboardImageOpeningApplicationDiscovery.applicationName(for: url)
    }
}

@MainActor
struct ClipboardImageOpeningApplicationDiscovery {
    typealias HandlerQuery = @MainActor (String) -> [String]
    typealias ApplicationURLQuery = @MainActor (String) -> URL?
    typealias MetadataQuery = @MainActor (URL) -> ClipboardImageOpeningApplicationMetadata

    private static let imageContentTypes: [UTType] = [
        .image,
        .png,
        .jpeg,
        .heic,
        .gif,
        .tiff,
        .webP,
        .svg,
        .bmp,
        .ico,
        .rawImage,
        .heif,
        UTType(importedAs: "public.jpeg-2000", conformingTo: .image),
        UTType(importedAs: "com.apple.icns", conformingTo: .image),
        UTType(importedAs: "public.avif", conformingTo: .image)
    ]
    private static let textContentTypes: [UTType] = [
        .text,
        .plainText,
        .sourceCode,
        .html,
        .xml,
        .json,
        .rtf,
        UTType(importedAs: "net.daringfireball.markdown", conformingTo: .text)
    ]
    private static let webURLSchemes: Set<String> = ["http", "https"]

    private let handlerQuery: HandlerQuery
    private let applicationURLQuery: ApplicationURLQuery
    private let metadataQuery: MetadataQuery

    init(
        handlerQuery: @escaping HandlerQuery = { contentTypeIdentifier in
            Self.defaultHandlerBundleIdentifiers(for: contentTypeIdentifier)
        },
        applicationURLQuery: @escaping ApplicationURLQuery = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        metadataQuery: @escaping MetadataQuery = { applicationURL in
            Self.defaultApplicationMetadata(for: applicationURL)
        }
    ) {
        self.handlerQuery = handlerQuery
        self.applicationURLQuery = applicationURLQuery
        self.metadataQuery = metadataQuery
    }

    func discover() -> [ClipboardImageOpeningApplicationCandidate] {
        let textHandlerBundleIdentifiers = Set(
            Self.textContentTypes.flatMap { handlerQuery($0.identifier) }
        )
        let handlerBundleIdentifiers = Self.imageContentTypes.flatMap {
            handlerQuery($0.identifier)
        }
        return handlerBundleIdentifiers.compactMap { bundleIdentifier in
            guard let url = applicationURLQuery(bundleIdentifier) else {
                return nil
            }
            let normalizedURL = url.standardizedFileURL
            let metadata = metadataQuery(normalizedURL)
            return ClipboardImageOpeningApplicationCandidate(
                application: ClipboardImageOpeningApplication(
                    url: normalizedURL,
                    name: metadata.name
                ),
                isTextHandler: textHandlerBundleIdentifiers.contains(bundleIdentifier),
                handlesWebURLs: metadata.handlesWebURLs
            )
        }
    }

    func previewApplication() -> ClipboardImageOpeningApplication? {
        guard let url = applicationURLQuery("com.apple.Preview") else {
            return nil
        }
        let normalizedURL = url.standardizedFileURL
        return ClipboardImageOpeningApplication(
            url: normalizedURL,
            name: metadataQuery(normalizedURL).name
        )
    }

    static func applicationName(for url: URL) -> String {
        let bundle = Bundle(url: url)
        let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        if let bundleName {
            let trimmedName = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                return trimmedName
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func defaultApplicationMetadata(
        for applicationURL: URL
    ) -> ClipboardImageOpeningApplicationMetadata {
        ClipboardImageOpeningApplicationMetadata(
            name: applicationName(for: applicationURL),
            handlesWebURLs: handlesWebURLs(at: applicationURL)
        )
    }

    private static func handlesWebURLs(at applicationURL: URL) -> Bool {
        guard let urlTypes = Bundle(url: applicationURL)?.object(
            forInfoDictionaryKey: "CFBundleURLTypes"
        ) as? [[String: Any]] else {
            return false
        }
        return urlTypes.contains { urlType in
            let schemes = urlType["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains { webURLSchemes.contains($0.lowercased()) }
        }
    }

    private static func defaultHandlerBundleIdentifiers(for contentTypeIdentifier: String) -> [String] {
        guard let handlers = LSCopyAllRoleHandlersForContentType(
            contentTypeIdentifier as CFString,
            LSRolesMask.all
        )?.takeRetainedValue() as? [String] else {
            return []
        }
        return handlers
    }
}
