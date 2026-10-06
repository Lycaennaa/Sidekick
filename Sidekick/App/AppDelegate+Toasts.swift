import AppKit

extension AppDelegate {
    func nextUtilityToastPresentationToken() -> UInt64 {
        utilityToastPresentationToken &+= 1
        return utilityToastPresentationToken
    }

    func presentGeneralToast(
        _ model: ToastModel,
        duration: TimeInterval,
        utilityToastPresentationToken: UInt64? = nil
    ) {
        let presentationToken = utilityToastPresentationToken ?? nextUtilityToastPresentationToken()
        self.utilityToastPresentationToken = presentationToken
        toastPresentationCoordinator?.presentGeneral(
            model,
            duration: duration,
            onDismiss: { [weak self] generation in
                guard let self else { return }
                if self.utilityToastPresentationToken == presentationToken {
                    self.utilityToastPresentationToken &+= 1
                }
                self.clipboardToastController?.toastDidDismiss(generation: generation)
            }
        )
    }

    func presentUtilityToast(
        _ message: String,
        style: ToastPresentationStyle,
        symbolName: String,
        footer: String? = nil,
        duration: TimeInterval? = nil
    ) {
        presentUtilityToast(
            message,
            style: style,
            symbolName: symbolName,
            footer: footer,
            duration: duration,
            expectedGeneration: nil
        )
    }

    func presentUtilityToast(
        _ message: String,
        style: ToastPresentationStyle,
        symbolName: String,
        footer: String?,
        duration: TimeInterval? = nil,
        expectedGeneration: UInt64?,
        interruptsPendingOperations: Bool = true
    ) {
        if let expectedGeneration,
           utilityToastGeneration != expectedGeneration {
            return
        }
        clipboardToastController?.dismissCurrentToast()
        let generation = interruptsPendingOperations
            ? beginUtilityOperation()
            : utilityToastGeneration
        let presentationToken = nextUtilityToastPresentationToken()
        presentGeneralToast(
            ToastModel(
                generation: generation,
                presentationStyle: style,
                summary: message,
                detail: nil,
                icon: NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: message
                ),
                footer: footer
            ),
            duration: duration ?? settings.toastDuration,
            utilityToastPresentationToken: presentationToken
        )
    }

    func presentTemporaryVolumeToast(
        _ message: String,
        symbolName: String,
        duration: TimeInterval
    ) {
        toastPresentationCoordinator?.presentTemporaryVolume(
            ToastModel(
                generation: utilityToastGeneration,
                presentationStyle: .text,
                summary: message,
                detail: nil,
                icon: NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: message
                ),
                footer: nil
            ),
            duration: duration
        )
    }
}
