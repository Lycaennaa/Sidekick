import Foundation

typealias ClipboardImageEnrichmentCompletion = @MainActor @Sendable (ClipboardImageEnrichment) -> Void
typealias ClipboardOptionalImageEnrichmentCompletion = @MainActor @Sendable (ClipboardImageEnrichment?) -> Void

nonisolated protocol ClipboardImageEnriching: Sendable {
    func enqueue(
        _ request: ClipboardImageEnrichmentRequest,
        completion: @escaping ClipboardImageEnrichmentCompletion
    )
    func cancelAll()
}

nonisolated final class ClipboardImageEnrichmentWorker: ClipboardImageEnriching, Sendable {
    typealias Completion = ClipboardImageEnrichmentCompletion
    typealias Decode = @Sendable (
        ClipboardImageEnrichmentRequest,
        @Sendable () -> Bool
    ) -> ClipboardImageEnrichment?

    private enum DecodeResult: @unchecked Sendable {
        case enriched(ClipboardImageEnrichment)
        case unavailable
    }

    private let coordinator: ClipboardBackgroundWorkCoordinator<
        ClipboardImageEnrichmentRequest,
        DecodeResult
    >
    private let decode: Decode

    init(
        decode: @escaping Decode = { request, isCancelled in
            ClipboardImageDecoder.decode(request, isCancelled: isCancelled)
        }
    ) {
        self.decode = decode
        coordinator = ClipboardBackgroundWorkCoordinator(
            label: "com.lycaennaa.sidekick.clipboard-image-decode"
        )
    }

    func enqueue(
        _ request: ClipboardImageEnrichmentRequest,
        completion: @escaping Completion
    ) {
        enqueueOptional(request) { enrichment in
            if let enrichment {
                completion(enrichment)
            }
        }
    }

    func enqueueOptional(
        _ request: ClipboardImageEnrichmentRequest,
        completion: @escaping ClipboardOptionalImageEnrichmentCompletion
    ) {
        coordinator.enqueue(
            request,
            operation: { [decode] request, isCancelled in
                decode(request, isCancelled).map(DecodeResult.enriched) ?? .unavailable
            },
            onResult: { _, result in
                switch result {
                case let .enriched(enrichment):
                    completion(enrichment)
                case .unavailable:
                    completion(nil)
                }
            }
        )
    }

    func cancelAll() {
        coordinator.cancelAll()
    }
}
