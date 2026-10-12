import Foundation
import UniformTypeIdentifiers
private func defaultClipboardImagePreviewDirectory() -> URL {
    let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return applicationSupportDirectory.appendingPathComponent(
        "Sidekick/ClipboardPreview",
        isDirectory: true
    )
}

@MainActor
final class ClipboardImagePreviewArtifactStore {
    private struct Materialization: Sendable {
        let data: Data
        let destination: URL
    }
    private struct ArtifactInfo {
        let url: URL
        let byteCount: Int
        let modificationDate: Date
    }

    typealias Completion = @MainActor (URL?) -> Void
    typealias WriteData = @Sendable (
        Data,
        URL,
        @Sendable () -> Bool
    ) throws -> Void
    typealias RemoveItem = @Sendable (URL) -> Bool

    private static let filePrefix = "Sidekick-ClipboardPreview-"
    private static let previewArtifactRetention: TimeInterval = 24 * 60 * 60
    private static let handoffProtectionInterval: TimeInterval = 10 * 60
    private static let maximumArtifactCount = 16
    private static let maximumArtifactBytes = 512 * 1_024 * 1_024
    private static let cleanupInterval: TimeInterval = 60 * 60
    private static let cleanupRetryInterval: TimeInterval = 1
    private static let maximumCleanupRetries = 5

    private let outputDirectory: URL
    private let writeData: WriteData
    private let removeItem: RemoveItem
    private let coordinator = ClipboardBackgroundWorkCoordinator<Materialization, Bool>(
        label: "com.lycaennaa.sidekick.clipboard-image-preview"
    )
    private var cleanupTimer: Timer?
    private var retryTimer: Timer?
    private var pendingDeletionURLs: Set<URL> = []
    private var protectedURLs: [URL: Date] = [:]
    private var reservations: [URL: Int] = [:]
    private var cleanupRetryCount = 0
    private var isTerminated = false

    init(
        outputDirectory: URL = defaultClipboardImagePreviewDirectory(),
        writeData: @escaping WriteData = { data, url, isCancelled in
            try ClipboardImageConversionFileService.writeOutput(
                data,
                to: url,
                isCancelled: isCancelled
            )
        },
        removeItem: @escaping RemoveItem = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                return false
            }
        }
    ) {
        self.outputDirectory = outputDirectory
        self.writeData = writeData
        self.removeItem = removeItem
        self.isTerminated = false
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        removeExpiredPreviewFiles()
        scheduleCleanupTimer()
    }

    func materialize(
        data: Data,
        typeIdentifier: String,
        completion: @escaping Completion
    ) {
        guard !isTerminated,
              data.count <= ClipboardImageDecoder.maximumSourceBytes,
              prepareForMaterialization(byteCount: data.count),
              let destination = destination(for: typeIdentifier) else {
            completion(nil)
            return
        }

        reservations[destination] = data.count
        let work = Materialization(data: data, destination: destination)
        coordinator.enqueue(
            work,
            operation: { [writeData] work, isCancelled in
                do {
                    try writeData(work.data, work.destination, isCancelled)
                    return true
                } catch {
                    return false
                }
            },
            onResult: { [weak self] work, succeeded in
                guard let self else { return }
                guard succeeded else {
                    self.releaseReservation(for: work.destination)
                    self.removeOwnedFile(at: work.destination)
                    completion(nil)
                    return
                }
                guard !self.isTerminated else {
                    self.releaseReservation(for: work.destination)
                    self.removeOwnedFile(at: work.destination)
                    return
                }
                self.protectedURLs[work.destination] = Date().addingTimeInterval(
                    Self.handoffProtectionInterval
                )
                self.releaseReservation(for: work.destination)
                self.enforceStorageBudget(reservingByteCount: 0)
                completion(work.destination)
            },
            onPendingCancelled: { [weak self] work in
                self?.releaseReservation(for: work.destination)
            },
            onDiscarded: { [weak self] work, _ in
                guard let self else { return }
                self.releaseReservation(for: work.destination)
                self.removeOwnedFile(at: work.destination)
            }
        )
    }

    func remove(_ url: URL) {
        removeOwnedFile(at: url)
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        protectedURLs.removeAll()
        coordinator.cancelAll()
    }

}

extension ClipboardImagePreviewArtifactStore {
    private func releaseReservation(for url: URL) {
        reservations.removeValue(forKey: url)
    }

    private func prepareForMaterialization(byteCount: Int) -> Bool {
        guard byteCount <= Self.maximumArtifactBytes else { return false }
        let reservedByteCount = reservations.values.reduce(0, +)
        let reservedArtifactCount = reservations.count
        guard reservedByteCount <= Self.maximumArtifactBytes - byteCount,
              reservedArtifactCount < Self.maximumArtifactCount else {
            return false
        }
        pruneExpiredProtections()
        enforceStorageBudget(
            reservingByteCount: reservedByteCount + byteCount,
            reservingArtifactCount: reservedArtifactCount + 1
        )
        let artifacts = artifactInfos()
        let totalBytes = artifacts.reduce(0) { $0 + $1.byteCount }
        return artifacts.count + reservedArtifactCount + 1 <= Self.maximumArtifactCount
            && totalBytes + reservedByteCount + byteCount <= Self.maximumArtifactBytes
    }

    private func artifactInfos() -> [ArtifactInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard Self.isOwnedPreviewURL(url, in: outputDirectory),
                  let values = try? url.resourceValues(
                      forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                  ),
                  values.isDirectory != true,
                  let byteCount = values.fileSize,
                  byteCount >= 0,
                  let modificationDate = values.contentModificationDate else {
                return nil
            }
            return ArtifactInfo(
                url: url,
                byteCount: byteCount,
                modificationDate: modificationDate
            )
        }
    }

    private func enforceStorageBudget(
        reservingByteCount: Int,
        reservingArtifactCount: Int = 0
    ) {
        let artifacts = artifactInfos().sorted {
            if $0.modificationDate == $1.modificationDate {
                return $0.url.path < $1.url.path
            }
            return $0.modificationDate < $1.modificationDate
        }
        var totalBytes = artifacts.reduce(0) { $0 + $1.byteCount }
        var artifactCount = artifacts.count
        for artifact in artifacts {
            guard artifactCount + reservingArtifactCount > Self.maximumArtifactCount
                    || totalBytes + reservingByteCount > Self.maximumArtifactBytes else {
                break
            }
            guard !isProtected(artifact.url) else { continue }
            let existed = FileManager.default.fileExists(atPath: artifact.url.path)
            removeOwnedFile(at: artifact.url)
            if existed,
               !FileManager.default.fileExists(atPath: artifact.url.path) {
                artifactCount -= 1
                totalBytes -= artifact.byteCount
            }
        }
    }

    private func pruneExpiredProtections(now: Date = Date()) {
        protectedURLs = protectedURLs.filter { $0.value > now }
    }

    private func isProtected(_ url: URL) -> Bool {
        if let expiration = protectedURLs[url] {
            return expiration > Date()
        }
        if reservations[url] != nil {
            return true
        }
        return reservations.keys.contains {
            url.path.hasPrefix($0.path + ".")
        }
    }

    private func destination(for typeIdentifier: String) -> URL? {
        guard let type = UTType(typeIdentifier), type.conforms(to: .image) else {
            return nil
        }
        let fileExtension = Self.safeFileExtension(type.preferredFilenameExtension) ?? "png"
        return outputDirectory.appendingPathComponent(
            "\(Self.filePrefix)\(UUID().uuidString).\(fileExtension)"
        )
    }

    private func scheduleCleanupTimer() {
        guard !isTerminated, cleanupTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.cleanupInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTerminated else { return }
                self.pruneExpiredProtections()
                self.removeExpiredPreviewFiles()
                self.enforceStorageBudget(reservingByteCount: 0)
                self.retryPendingDeletions(resetRetryCount: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func removeExpiredPreviewFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else {
            return
        }
        let now = Date()
        for url in urls where Self.isOwnedPreviewFileURL(url, in: outputDirectory) {
            guard !isProtected(url) else { continue }
            if Self.isOwnedPreviewPartialURL(url, in: outputDirectory) {
                removeOwnedFile(at: url)
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modificationDate = values.contentModificationDate,
                  now.timeIntervalSince(modificationDate) >= Self.previewArtifactRetention else {
                continue
            }
            removeOwnedFile(at: url)
        }
    }

    private func removeOwnedFile(at url: URL) {
        guard Self.isOwnedPreviewFileURL(url, in: outputDirectory) else { return }
        protectedURLs.removeValue(forKey: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            pendingDeletionURLs.remove(url)
            return
        }
        if removeItem(url) {
            pendingDeletionURLs.remove(url)
        } else {
            pendingDeletionURLs.insert(url)
            scheduleCleanupRetry()
        }
        if pendingDeletionURLs.isEmpty {
            retryTimer?.invalidate()
            retryTimer = nil
            cleanupRetryCount = 0
        }
    }

    private func scheduleCleanupRetry() {
        guard !isTerminated,
              retryTimer == nil,
              cleanupRetryCount < Self.maximumCleanupRetries else {
            return
        }
        cleanupRetryCount += 1
        let timer = Timer(
            timeInterval: Self.cleanupRetryInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                self.retryPendingDeletions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func retryPendingDeletions(resetRetryCount: Bool = false) {
        guard !isTerminated else { return }
        if resetRetryCount {
            cleanupRetryCount = 0
        }
        let urls = pendingDeletionURLs
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                pendingDeletionURLs.remove(url)
                continue
            }
            if removeItem(url) {
                pendingDeletionURLs.remove(url)
            }
        }
        if pendingDeletionURLs.isEmpty {
            retryTimer?.invalidate()
            retryTimer = nil
            cleanupRetryCount = 0
        } else {
            scheduleCleanupRetry()
        }
    }

    private static func isOwnedPreviewURL(_ url: URL, in outputDirectory: URL) -> Bool {
        isOwnedPreviewFileURL(url, in: outputDirectory)
            && !isOwnedPreviewPartialURL(url, in: outputDirectory)
    }

    private static func isOwnedPreviewPartialURL(_ url: URL, in outputDirectory: URL) -> Bool {
        guard isOwnedPreviewFileURL(url, in: outputDirectory),
              let marker = url.lastPathComponent.range(
                  of: ".partial-",
                  options: .backwards
              ),
              !url.lastPathComponent[marker.upperBound...].isEmpty else {
            return false
        }
        return true
    }

    private static func isOwnedPreviewFileURL(_ url: URL, in outputDirectory: URL) -> Bool {
        guard url.isFileURL, outputDirectory.isFileURL else { return false }
        let candidateDirectory = url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let expectedDirectory = outputDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidateDirectory.path == expectedDirectory.path,
              url.lastPathComponent.hasPrefix(Self.filePrefix),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else {
            return false
        }
        return true
    }

    private static func safeFileExtension(_ fileExtension: String?) -> String? {
        guard let fileExtension,
              !fileExtension.isEmpty,
              fileExtension.count <= 12,
              fileExtension.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value)
                      || (65...90).contains(value)
                      || (97...122).contains(value)
              })
        else {
            return nil
        }
        return fileExtension.lowercased()
    }
}
