import Foundation

nonisolated enum ClipboardWebPFileService {
    typealias CancellationCheck = @Sendable () -> Bool
    private static let ioChunkSize = 1 * 1_024 * 1_024

    static func prepareOutputDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    static func sourceData(
        _ url: URL,
        maximumBytes: Int,
        isCancelled: CancellationCheck
    ) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try checkCancellation(isCancelled)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ClipboardWebPConversionError.invalidImage
        }
        guard let fileSize = values.fileSize,
              fileSize <= ClipboardWebPConfiguration.maximumSourceBytes,
              fileSize <= maximumBytes else {
            throw ClipboardWebPConversionError.tooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(fileSize)
        while data.count < fileSize {
            try checkCancellation(isCancelled)
            let readLength = min(Self.ioChunkSize, fileSize - data.count)
            guard let chunk = try handle.read(upToCount: readLength), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        try checkCancellation(isCancelled)
        guard data.count <= ClipboardWebPConfiguration.maximumSourceBytes,
              data.count <= maximumBytes else {
            throw ClipboardWebPConversionError.tooLarge
        }
        return data
    }

    static func writeOutput(
        _ data: Data,
        to outputURL: URL,
        isCancelled: CancellationCheck
    ) throws {
        try checkCancellation(isCancelled)
        let temporaryURL = outputURL.appendingPathExtension(
            "partial-\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw ClipboardWebPConversionError.cannotWrite
        }

        var handle: FileHandle?
        do {
            handle = try FileHandle(forWritingTo: temporaryURL)
            guard let writableHandle = handle else {
                throw ClipboardWebPConversionError.cannotWrite
            }
            var offset = 0
            while offset < data.count {
                try checkCancellation(isCancelled)
                let end = min(offset + Self.ioChunkSize, data.count)
                try writableHandle.write(contentsOf: data.subdata(in: offset..<end))
                offset = end
            }
            try checkCancellation(isCancelled)
            try writableHandle.synchronize()
            try writableHandle.close()
            handle = nil
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            if let handle {
                try? handle.close()
            }
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func isOwnedOutputURL(_ url: URL, in directory: URL) -> Bool {
        guard url.isFileURL, directory.isFileURL else { return false }
        let candidateDirectory = url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let outputDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidateDirectory.path == outputDirectory.path else { return false }

        let filename = url.lastPathComponent
        let suffix = filename
        let hasValidIdentifier = suffix.prefix(7).allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
        guard suffix.count >= 12,
              hasValidIdentifier,
              suffix.dropFirst(7).hasPrefix(".webp") else {
            return false
        }

        let remainder = suffix.dropFirst(12)
        guard !remainder.isEmpty else { return true }
        guard remainder.hasPrefix(".partial-") else { return false }
        return !remainder.dropFirst(".partial-".count).isEmpty
    }

    static func uniqueOutputURL(
        in directory: URL,
        isCancelled: CancellationCheck
    ) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<32 {
            try checkCancellation(isCancelled)
            let url = directory.appendingPathComponent(randomFilename(using: &generator))
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw ClipboardWebPConversionError.cannotCreateFilename
    }

    private static func randomFilename<R: RandomNumberGenerator>(using generator: inout R) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<7).map { _ in alphabet.randomElement(using: &generator) ?? "a" })
            + ".webp"
    }

    private static func checkCancellation(_ isCancelled: CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
