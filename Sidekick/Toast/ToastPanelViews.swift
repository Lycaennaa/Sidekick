import AppKit

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ToastContentView: NSView, NSGestureRecognizerDelegate {
    var onPress: (() -> Void)?
    var onAction: (() -> Void)?
    var isActionAvailable = false {
        didSet {
            previewClickRecognizer?.isEnabled = isActionAvailable
            previewPressRecognizer?.isEnabled = isActionAvailable
            setAccessibilityLabel(
                isActionAvailable ? "Open copied image" : "Dismiss notification"
            )
            setAccessibilityHelp(
                isActionAvailable
                    ? "Double-click or press and hold to open copied image"
                    : nil
            )
            toolTip = isActionAvailable
                ? "Double-click or press and hold to open copied image"
                : nil
        }
    }

    private var clickRecognizer: NSClickGestureRecognizer?
    private var previewClickRecognizer: NSClickGestureRecognizer?
    private var previewPressRecognizer: NSPressGestureRecognizer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        if isActionAvailable, let onAction {
            onAction()
            return true
        }
        guard let onPress else { return false }
        onPress()
        return true
    }

    private func configureInteraction() {
        let clickRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(contentClicked)
        )
        let previewClickRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(contentPreviewClicked(_:))
        )
        previewClickRecognizer.numberOfClicksRequired = 2
        let previewPressRecognizer = NSPressGestureRecognizer(
            target: self,
            action: #selector(contentPreviewPressed(_:))
        )
        previewPressRecognizer.minimumPressDuration = 0.55
        clickRecognizer.delegate = self
        previewClickRecognizer.delegate = self
        previewPressRecognizer.delegate = self
        addGestureRecognizer(clickRecognizer)
        addGestureRecognizer(previewClickRecognizer)
        addGestureRecognizer(previewPressRecognizer)
        self.clickRecognizer = clickRecognizer
        self.previewClickRecognizer = previewClickRecognizer
        self.previewPressRecognizer = previewPressRecognizer
        isActionAvailable = false
    }

    @objc private func contentClicked() {
        onPress?()
    }

    @objc private func contentPreviewClicked(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
        onAction?()
    }

    @objc private func contentPreviewPressed(_ sender: NSPressGestureRecognizer) {
        guard sender.state == .began else { return }
        onAction?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        guard let clickRecognizer,
              let previewClickRecognizer,
              let previewPressRecognizer,
              gestureRecognizer === clickRecognizer,
              otherGestureRecognizer === previewClickRecognizer
                  || otherGestureRecognizer === previewPressRecognizer
        else {
            return false
        }
        return true
    }

}
