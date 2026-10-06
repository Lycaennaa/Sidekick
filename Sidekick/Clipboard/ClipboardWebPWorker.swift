import Foundation

nonisolated final class ClipboardWebPWorker: Sendable {
    enum Result: Sendable {
        case success(URL)
        case failure(ClipboardWebPConversionFailure)
        case cancelled
    }

    typealias Completion = @MainActor @Sendable (Result) -> Void
    typealias Cleanup = @MainActor @Sendable (URL) -> Void
    typealias Convert = @Sendable (
        ClipboardWebPSource,
        URL,
        @Sendable () -> Bool
    ) throws -> URL
    private typealias ConversionResult = Result

    private struct Work: Sendable {
        let source: ClipboardWebPSource
        let outputDirectory: URL
        let cleanup: Cleanup
        let completion: Completion
    }

    private let coordinator: ClipboardBackgroundWorkCoordinator<Work, ConversionResult>
    private let convert: Convert

    init(
        convert: @escaping Convert = { source, outputDirectory, isCancelled in
            try ClipboardWebPTranscoder.convert(
                source,
                outputDirectory: outputDirectory,
                isCancelled: isCancelled
            )
        }
    ) {
        self.convert = convert
        coordinator = ClipboardBackgroundWorkCoordinator(
            label: "com.lycaennaa.sidekick.clipboard-webp"
        )
    }

    convenience init(
        convert: @escaping @Sendable (ClipboardWebPSource, URL) throws -> URL
    ) {
        self.init(convert: { source, outputDirectory, _ in
            try convert(source, outputDirectory)
        })
    }

    func enqueue(
        source: ClipboardWebPSource,
        outputDirectory: URL,
        cleanup: @escaping Cleanup,
        completion: @escaping Completion
    ) {
        let work = Work(
            source: source,
            outputDirectory: outputDirectory,
            cleanup: cleanup,
            completion: completion
        )
        coordinator.enqueue(
            work,
            operation: { [convert] work, isCancelled in
                do {
                    return .success(try convert(work.source, work.outputDirectory, isCancelled))
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

    private static func failure(for error: any Error) -> ClipboardWebPConversionFailure {
        if let conversionError = error as? ClipboardWebPConversionError {
            return .conversion(conversionError)
        }

        let description = error.localizedDescription
        return .unexpected(description.isEmpty ? String(describing: error) : description)
    }

    func cancelAll() {
        coordinator.cancelAll()
    }
}
