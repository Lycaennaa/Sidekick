import Foundation

nonisolated enum ClipboardWebPTranscoder {
    typealias CancellationCheck = @Sendable () -> Bool
    typealias ConversionError = ClipboardWebPConversionError

    static func convert(
        _ source: ClipboardWebPSource,
        outputDirectory: URL,
        aggregateSourceBytes: Int = ClipboardWebPConfiguration.maximumAggregateSourceBytes,
        isCancelled: CancellationCheck = { false }
    ) throws -> URL {
        try checkCancellation(isCancelled)
        let outputData = try encodedData(
            source,
            aggregateSourceBytes: max(0, aggregateSourceBytes),
            isCancelled: isCancelled
        )
        try checkCancellation(isCancelled)
        guard outputData.count <= ClipboardWebPConfiguration.maximumOutputBytes else {
            throw ConversionError.tooLarge
        }

        try checkCancellation(isCancelled)
        try ClipboardWebPFileService.prepareOutputDirectory(outputDirectory)
        try checkCancellation(isCancelled)
        let outputURL = try ClipboardWebPFileService.uniqueOutputURL(
            in: outputDirectory,
            isCancelled: isCancelled
        )
        try ClipboardWebPFileService.writeOutput(
            outputData,
            to: outputURL,
            isCancelled: isCancelled
        )
        return outputURL
    }

    private static func encodedData(
        _ source: ClipboardWebPSource,
        aggregateSourceBytes: Int,
        isCancelled: CancellationCheck
    ) throws -> Data {
        try checkCancellation(isCancelled)
        switch source {
        case let .data(data):
            guard data.count <= ClipboardWebPConfiguration.maximumSourceBytes,
                  data.count <= aggregateSourceBytes else {
                throw ConversionError.tooLarge
            }
            return try ClipboardWebPEncoder.encode(data, isCancelled: isCancelled)
        case let .files(urls, fallback):
            var remainingSourceBytes = aggregateSourceBytes
            var lastError: Error?
            for url in urls {
                try checkCancellation(isCancelled)
                guard remainingSourceBytes > 0 else { break }
                do {
                    let data = try ClipboardWebPFileService.sourceData(
                        url,
                        maximumBytes: remainingSourceBytes,
                        isCancelled: isCancelled
                    )
                    remainingSourceBytes -= data.count
                    return try ClipboardWebPEncoder.encode(data, isCancelled: isCancelled)
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
                guard fallback.count <= ClipboardWebPConfiguration.maximumSourceBytes,
                      fallback.count <= remainingSourceBytes else {
                    throw ConversionError.tooLarge
                }
                remainingSourceBytes -= fallback.count
                return try ClipboardWebPEncoder.encode(fallback, isCancelled: isCancelled)
            }
            throw lastError ?? ConversionError.invalidImage
        }
    }

    private static func checkCancellation(_ isCancelled: CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
