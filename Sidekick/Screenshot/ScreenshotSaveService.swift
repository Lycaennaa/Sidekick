import Foundation

nonisolated enum ScreenshotFilenameTemplate {
    static let defaultTemplate = "Screenshot-{date}-{time}"

    static func baseName(
        template: String,
        date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateValue = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "HH-mm-ss"
        let timeValue = dateFormatter.string(from: date)
        return sanitizedBaseName(
            template
                .replacingOccurrences(of: "{date}", with: dateValue)
                .replacingOccurrences(of: "{time}", with: timeValue)
                .replacingOccurrences(of: "{windowTitle}", with: "")
        )
    }

    static func sanitizedBaseName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        var result = String.UnicodeScalarView()
        var previousWasSeparator = false
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.append(scalar)
                previousWasSeparator = scalar == "-"
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        let trimmed = String(result).trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        var bounded = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in trimmed.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard byteCount + scalarByteCount <= 180 else { break }
            bounded.append(scalar)
            byteCount += scalarByteCount
        }
        let safeName = String(bounded).trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return safeName.isEmpty ? "Screenshot" : safeName
    }
}

nonisolated enum ScreenshotSaveService {
    enum Failure: Error, Equatable {
        case invalidDirectory
        case filenameCollision
    }

    struct Prepared: Sendable {
        fileprivate let stagingURL: URL
        fileprivate let directoryURL: URL
        fileprivate let baseName: String
        let imageFormat: ClipboardImageFormat
        let imageData: Data
    }

    static func prepareInBackground(
        pngData: Data,
        directory: URL,
        baseName: String,
        format: ClipboardImageFormat = .webP
    ) async throws -> Prepared {
        let worker = Task.detached(priority: .utility) {
            try prepare(pngData: pngData, directory: directory, baseName: baseName, format: format) {
                Task.isCancelled
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func prepare(
        pngData: Data,
        directory: URL,
        baseName: String,
        format: ClipboardImageFormat = .webP,
        isCancelled: ClipboardImageConversionPolicy.CancellationCheck
    ) throws -> Prepared {
        try checkCancellation(isCancelled)
        guard directory.isFileURL,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure.invalidDirectory
        }
        let imageData = try ClipboardImageEncoder.encode(pngData, format: format, isCancelled: isCancelled)
        try checkCancellation(isCancelled)
        let normalizedDirectory = directory.standardizedFileURL
        let stagingURL = normalizedDirectory.appendingPathComponent(
            ".sidekick-screenshot-\(UUID().uuidString).partial",
            isDirectory: false
        )
        do {
            try ClipboardImageConversionFileService.writeOutput(imageData, to: stagingURL, isCancelled: isCancelled)
            try checkCancellation(isCancelled)
            return Prepared(
                stagingURL: stagingURL,
                directoryURL: normalizedDirectory,
                baseName: ScreenshotFilenameTemplate.sanitizedBaseName(baseName),
                imageFormat: format,
                imageData: imageData
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    static func commit(_ prepared: Prepared) throws -> URL {
        guard prepared.directoryURL.isFileURL,
              (try? prepared.directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              prepared.stagingURL.deletingLastPathComponent().standardizedFileURL.path
                == prepared.directoryURL.standardizedFileURL.path else {
            throw Failure.invalidDirectory
        }
        for suffix in 1...10_000 {
            let suffixText = suffix == 1 ? "" : " (\(suffix))"
            let outputURL = prepared.directoryURL.appendingPathComponent(
                "\(prepared.baseName)\(suffixText).\(prepared.imageFormat.fileExtension)"
            )
            do {
                try FileManager.default.moveItem(at: prepared.stagingURL, to: outputURL)
                return outputURL
            } catch {
                guard FileManager.default.fileExists(atPath: outputURL.path), suffix < 10_000 else {
                    throw error
                }
            }
        }
        throw Failure.filenameCollision
    }

    static func discard(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.stagingURL)
    }

    private static func checkCancellation(_ isCancelled: ClipboardImageConversionPolicy.CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
