import Foundation

nonisolated enum ClipboardImageConversionTranscoder {
    typealias CancellationCheck = ClipboardImageConversionPolicy.CancellationCheck
    typealias ConversionError = ClipboardImageConversionError

    static func convert(
        _ source: ClipboardImageSource,
        outputDirectory: URL,
        format: ClipboardImageFormat = .webP,
        aggregateSourceBytes: Int = ClipboardImageConversionPolicy.maximumAggregateSourceBytes,
        isCancelled: CancellationCheck = { false }
    ) throws -> URL {
        try checkCancellation(isCancelled)
        let outputData = try encodedData(
            source,
            format: format,
            aggregateSourceBytes: max(0, aggregateSourceBytes),
            isCancelled: isCancelled
        )
        guard outputData.count <= ClipboardImageConversionPolicy.maximumOutputBytes else {
            throw ConversionError.tooLarge
        }

        try checkCancellation(isCancelled)
        try ClipboardImageConversionFileService.prepareOutputDirectory(outputDirectory)
        try checkCancellation(isCancelled)
        let outputURL = try ClipboardImageConversionFileService.uniqueOutputURL(
            in: outputDirectory,
            format: format,
            isCancelled: isCancelled
        )
        try ClipboardImageConversionFileService.writeOutput(
            outputData,
            to: outputURL,
            isCancelled: isCancelled
        )
        return outputURL
    }

    private static func encodedData(
        _ source: ClipboardImageSource,
        format: ClipboardImageFormat,
        aggregateSourceBytes: Int,
        isCancelled: CancellationCheck
    ) throws -> Data {
        switch source {
        case let .data(data):
            guard data.count <= ClipboardImageConversionPolicy.maximumSourceBytes,
                  data.count <= aggregateSourceBytes else {
                throw ConversionError.tooLarge
            }
            return try ClipboardImageEncoder.encode(data, format: format, isCancelled: isCancelled)
        case let .files(urls, fallback):
            var remainingSourceBytes = aggregateSourceBytes
            var lastError: Error?
            for url in urls {
                try checkCancellation(isCancelled)
                guard remainingSourceBytes > 0 else { break }
                do {
                    let data = try ClipboardImageConversionFileService.sourceData(
                        url,
                        maximumBytes: remainingSourceBytes,
                        isCancelled: isCancelled
                    )
                    remainingSourceBytes -= data.count
                    return try ClipboardImageEncoder.encode(data, format: format, isCancelled: isCancelled)
                } catch is CancellationError {
                    throw CancellationError()
                } catch ConversionError.invalidImage {
                    continue
                } catch {
                    lastError = error
                }
            }
            if let fallback {
                try checkCancellation(isCancelled)
                guard fallback.count <= ClipboardImageConversionPolicy.maximumSourceBytes,
                      fallback.count <= remainingSourceBytes else {
                    throw ConversionError.tooLarge
                }
                remainingSourceBytes -= fallback.count
                return try ClipboardImageEncoder.encode(fallback, format: format, isCancelled: isCancelled)
            }
            throw lastError ?? ConversionError.invalidImage
        }
    }

    private static func checkCancellation(_ isCancelled: CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
