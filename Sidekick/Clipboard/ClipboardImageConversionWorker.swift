import Foundation

nonisolated final class ClipboardImageConversionWorker: Sendable {
    enum Result: Sendable {
        case success(URL)
        case failure(ClipboardImageConversionFailure)
        case cancelled
    }

    typealias Completion = @MainActor @Sendable (Result) -> Void
    typealias Cleanup = @MainActor @Sendable (URL) -> Void
    typealias Convert = @Sendable (
        ClipboardImageSource,
        URL,
        ClipboardImageFormat,
        @Sendable () -> Bool
    ) throws -> URL
    private typealias ConversionResult = Result

    private struct Work: Sendable {
        let source: ClipboardImageSource
        let outputDirectory: URL
        let format: ClipboardImageFormat
        let cleanup: Cleanup
        let completion: Completion
    }

    private let coordinator: ClipboardBackgroundWorkCoordinator<Work, ConversionResult>
    private let convert: Convert

    init(
        convert: @escaping Convert = { source, outputDirectory, format, isCancelled in
            try ClipboardImageConversionTranscoder.convert(
                source,
                outputDirectory: outputDirectory,
                format: format,
                isCancelled: isCancelled
            )
        }
    ) {
        self.convert = convert
        coordinator = ClipboardBackgroundWorkCoordinator(
            label: "com.lycaennaa.sidekick.clipboard-image-conversion"
        )
    }

    convenience init(
        convert: @escaping @Sendable (ClipboardImageSource, URL) throws -> URL
    ) {
        self.init(convert: { source, outputDirectory, _, _ in
            try convert(source, outputDirectory)
        })
    }

    func enqueue(
        source: ClipboardImageSource,
        outputDirectory: URL,
        format: ClipboardImageFormat = .webP,
        cleanup: @escaping Cleanup,
        completion: @escaping Completion
    ) {
        let work = Work(
            source: source,
            outputDirectory: outputDirectory,
            format: format,
            cleanup: cleanup,
            completion: completion
        )
        coordinator.enqueue(
            work,
            operation: { [convert] work, isCancelled in
                do {
                    return .success(try convert(work.source, work.outputDirectory, work.format, isCancelled))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failure(Self.failure(for: error))
                }
            },
            onResult: { work, result in
                work.completion(result)
            },
            onCancelled: { work in
                work.completion(.cancelled)
            },
            onDiscarded: { work, result in
                if case let .success(url) = result {
                    work.cleanup(url)
                }
            }
        )
    }

    private static func failure(for error: any Error) -> ClipboardImageConversionFailure {
        if let conversionError = error as? ClipboardImageConversionError {
            return .conversion(conversionError)
        }

        let description = error.localizedDescription
        return .unexpected(description.isEmpty ? String(describing: error) : description)
    }

    func cancelAll() {
        coordinator.cancelAll()
    }
}
