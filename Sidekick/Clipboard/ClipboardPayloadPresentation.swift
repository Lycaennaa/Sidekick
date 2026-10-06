import AppKit

@MainActor
enum ClipboardPayloadPresentation {
    static func toastModel(
        from classification: ClipboardPayloadClassification,
        textMetrics: ClipboardTextMetrics? = nil
    ) -> ToastModel {
        switch classification {
        case .files:
            return fileToast(from: classification)
        case .image:
            return imageToast(from: classification)
        case .text:
            return textToast(from: classification, textMetrics: textMetrics)
        case .generic:
            return genericToast(from: classification)
        case .unavailable:
            return unavailableToast(from: classification)
        }
    }

    private static func fileToast(from classification: ClipboardPayloadClassification) -> ToastModel {
        guard case let .files(
            generation,
            firstName,
            count,
            overflow,
            uncertain,
            representativeFileURL,
            _
        ) = classification else {
            preconditionFailure("Expected file classification")
        }
        let (summary, detail) = fileSummary(
            firstName: firstName,
            count: count,
            overflow: overflow,
            uncertain: uncertain
        )
        let icon = representativeFileURL
            .flatMap { fileURL in
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
                return NSWorkspace.shared.icon(forFile: fileURL.path)
            }
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: "File")
        return ToastModel(
            generation: generation,
            presentationStyle: .files,
            summary: summary,
            detail: detail,
            icon: icon,
            footer: nil
        )
    }

    private static func imageToast(from classification: ClipboardPayloadClassification) -> ToastModel {
        guard case let .image(generation, byteCount, _, screenshotDynamicRange) = classification else {
            preconditionFailure("Expected image classification")
        }
        let summary = screenshotDynamicRange.map {
            "Copied image • \($0.toastLabel)"
        } ?? "Copied image"
        return ToastModel(
            generation: generation,
            presentationStyle: .image,
            summary: summary,
            detail: nil,
            icon: NSImage(systemSymbolName: "photo", accessibilityDescription: "Image"),
            footer: byteCount.map(byteCountLabel)
        )
    }

    private static func textToast(
        from classification: ClipboardPayloadClassification,
        textMetrics: ClipboardTextMetrics?
    ) -> ToastModel {
        guard case let .text(generation, preview, oversizedByteCount) = classification else {
            preconditionFailure("Expected text classification")
        }
        let summary = oversizedByteCount.map {
            "Copied text • \(byteCountLabel($0))"
        } ?? preview ?? "Copied text"
        return ToastModel(
            generation: generation,
            presentationStyle: .text,
            summary: summary,
            detail: nil,
            icon: NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Text"),
            footer: textMetrics.map(\.formattedDescription)
        )
    }

    private static func genericToast(from classification: ClipboardPayloadClassification) -> ToastModel {
        guard case let .generic(generation, typeDescription) = classification else {
            preconditionFailure("Expected generic classification")
        }
        return ToastModel(
            generation: generation,
            presentationStyle: .generic,
            summary: typeDescription.map { "Copied \($0)" } ?? "Copied item",
            detail: nil,
            icon: NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Copied item"),
            footer: nil
        )
    }

    private static func unavailableToast(from classification: ClipboardPayloadClassification) -> ToastModel {
        guard case let .unavailable(generation) = classification else {
            preconditionFailure("Expected unavailable classification")
        }
        return ToastModel(
            generation: generation,
            presentationStyle: .generic,
            summary: "Clipboard payload unavailable",
            detail: "Native provider data cannot be read safely",
            icon: NSImage(
                systemSymbolName: "clipboard.badge.exclamationmark",
                accessibilityDescription: "Clipboard payload unavailable"
            ),
            footer: nil
        )
    }

    private static func fileSummary(
        firstName: String,
        count: Int,
        overflow: Bool,
        uncertain: Bool
    ) -> (String, String?) {
        let firstName = ClipboardPayloadClassifier.normalizedPreview(firstName).nilIfEmpty ?? "file"
        if uncertain {
            return ("Copied \(firstName) + more", "More files not inspected")
        }
        if overflow {
            return ("Copied \(firstName) + 9,999+ more", "10,000+ files")
        }
        if count == 1 {
            return ("Copied \(firstName)", nil)
        }
        return ("Copied \(firstName) + \(count - 1) more", "\(count) files")
    }
}

@MainActor
enum ClipboardMarkdownPresentation {
    struct ToastContent: Equatable {
        let message: String
        let footer: String?
        let acknowledgedChangeCount: Int?
    }

    static func toastContent(
        for result: ClipboardMarkdownController.Result
    ) -> ToastContent? {
        switch result {
        case let .cleaned(changeCount, metrics):
            return ToastContent(
                message: "Cleaned Markdown",
                footer: metricsFooter(metrics),
                acknowledgedChangeCount: changeCount
            )
        case .noText:
            return ToastContent(
                message: "No text to clean",
                footer: nil,
                acknowledgedChangeCount: nil
            )
        case .unavailable:
            return ToastContent(
                message: "Clipboard text unavailable",
                footer: nil,
                acknowledgedChangeCount: nil
            )
        case .tooLarge:
            return ToastContent(
                message: "Clipboard text is too large",
                footer: nil,
                acknowledgedChangeCount: nil
            )
        case .stale:
            return ToastContent(
                message: "Clipboard changed before cleaning",
                footer: nil,
                acknowledgedChangeCount: nil
            )
        case .cancelled:
            return nil
        case .failed:
            return ToastContent(
                message: "Couldn’t clean Markdown",
                footer: nil,
                acknowledgedChangeCount: nil
            )
        case .restoreFailed:
            return ToastContent(
                message: "Couldn’t restore clipboard",
                footer: nil,
                acknowledgedChangeCount: nil
            )
        }
    }

    private static func metricsFooter(_ metrics: ClipboardMarkdownMetrics) -> String? {
        let lines = [
            metrics.before.map { "Before: \($0.formattedDescription)" },
            metrics.after.map { "After: \($0.formattedDescription)" }
        ].compactMap(\.self)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
