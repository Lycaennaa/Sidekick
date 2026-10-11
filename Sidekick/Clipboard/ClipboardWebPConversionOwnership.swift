struct ClipboardWebPConversionOwnership {
    private(set) var automaticGeneration: UInt64?

    mutating func beginAutomaticConversion(generation: UInt64) {
        automaticGeneration = generation
    }

    mutating func completeAutomaticConversion(generation: UInt64) {
        guard automaticGeneration == generation else { return }
        automaticGeneration = nil
    }

    mutating func invalidate() {
        automaticGeneration = nil
    }

    func cancelPendingUtilityOperationIfNotAutomatic(
        utilityGeneration: UInt64,
        cancel: () -> Void
    ) {
        guard automaticGeneration != utilityGeneration else { return }
        cancel()
    }
    func shouldPresentNoImageMessage(utilityGeneration: UInt64) -> Bool {
        automaticGeneration != utilityGeneration
    }
}
