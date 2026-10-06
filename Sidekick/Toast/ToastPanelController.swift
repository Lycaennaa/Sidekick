import AppKit

@MainActor
final class ToastPanelController: NSObject {
    private static let cornerRadius: CGFloat = 21
    private static let slideDistance: CGFloat = 8
    private static let fadeInDuration: TimeInterval = 0.18
    private static let fadeOutDuration: TimeInterval = 0.16

    private let panel: ToastPanel
    private let contentView: ToastContentView
    private let iconView: NSImageView
    private let summaryLabel: NSTextField
    private let detailLabel: NSTextField
    private let sourceLabel: NSTextField
    private let contentLayout: ToastContentLayout
    private let onDismiss: (UInt64) -> Void
    private let onUserDismiss: () -> Void
    private let onDismissComplete: () -> Void
    private let reduceMotion: () -> Bool
    private var userAction: (@MainActor () -> Void)?
    private var currentModel: ToastModel?
    private var currentDuration = TimeInterval.infinity
    private var dismissalDeadline: Date?
    private var currentMaximumSize = ToastLayout.maximumSize
    private var currentVisibleFrame: CGRect?
    private var currentScreen: NSScreen?
    private var currentBottomOffset: CGFloat = 0
    private var isDismissing = false
    private var dismissalTimer: Timer?
    private var animationToken: UInt64 = 0

    init(
        onDismiss: @escaping (UInt64) -> Void = { _ in },
        onUserDismiss: @escaping () -> Void = {},
        onDismissComplete: @escaping () -> Void = {},
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.onDismiss = onDismiss
        self.onUserDismiss = onUserDismiss
        self.onDismissComplete = onDismissComplete
        self.reduceMotion = reduceMotion

        let panel = ToastPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let contentView = ToastContentView(frame: .zero)
        let iconView = NSImageView(frame: .zero)
        let summaryLabel = NSTextField(labelWithString: "")
        let detailLabel = NSTextField(labelWithString: "")
        let sourceLabel = NSTextField(labelWithString: "")
        self.panel = panel
        self.contentView = contentView
        self.iconView = iconView
        self.summaryLabel = summaryLabel
        self.detailLabel = detailLabel
        self.sourceLabel = sourceLabel
        self.contentLayout = ToastContentLayout(
            contentView: contentView,
            iconView: iconView,
            summaryLabel: summaryLabel,
            detailLabel: detailLabel,
            sourceLabel: sourceLabel
        )
        super.init()

        configurePanel()
        configureContent()
    }

    func present(
        _ model: ToastModel,
        duration: TimeInterval,
        maximumSize: CGSize = ToastLayout.maximumSize,
        visibleFrame: CGRect? = nil,
        screen: NSScreen? = nil,
        bottomOffset: CGFloat = 0
    ) {
        let wasVisible = panel.isVisible
        animationToken &+= 1
        currentModel = model
        currentDuration = duration
        dismissalDeadline = duration.isFinite
            ? Date().addingTimeInterval(duration)
            : nil
        currentMaximumSize = maximumSize
        currentScreen = screen ?? (visibleFrame == nil ? presentationScreen() : nil)
        currentVisibleFrame = visibleFrame ?? currentScreen?.visibleFrame
        guard currentVisibleFrame != nil else {
            stopDismissalTimer()
            isDismissing = false
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        setUserAction(model.onUserAction)
        currentBottomOffset = bottomOffset
        isDismissing = false
        stopDismissalTimer()
        updateContent(for: model)
        layoutCurrentPanel()
        panel.invalidateShadow()

        if wasVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            animateIn(to: panel.frame)
        }

        scheduleDismissal(after: duration)
    }

    func update(_ model: ToastModel) {
        guard !isDismissing,
              currentModel?.generation == model.generation else { return }
        currentModel = model
        setUserAction(model.onUserAction)
        guard panel.isVisible else { return }
        updateContent(for: model)
        relayout(bottomOffset: currentBottomOffset)
    }

    func relayout(bottomOffset: CGFloat) {
        guard hasActiveToast else { return }
        currentBottomOffset = bottomOffset
        layoutCurrentPanel()
        panel.invalidateShadow()
    }

    func hide() {
        animationToken &+= 1
        stopDismissalTimer()
        currentModel = nil
        currentDuration = .infinity
        dismissalDeadline = nil
        currentMaximumSize = ToastLayout.maximumSize
        currentVisibleFrame = nil
        currentBottomOffset = 0
        currentScreen = nil
        isDismissing = false
        panel.orderOut(nil)
        panel.alphaValue = 1
        setUserAction(nil)
        clearContent()
    }
    func setUserAction(_ action: (@MainActor () -> Void)?) {
        userAction = action
        contentView.isActionAvailable = action != nil
    }

    @discardableResult
    func dismiss() -> Bool {
        guard !isDismissing else { return false }
        stopDismissalTimer()
        guard let generation = currentModel?.generation else { return false }
        isDismissing = true
        animateOut(generation: generation)
        return true
    }

    var presentedFrame: CGRect {
        panel.frame
    }

    var hasActiveToast: Bool {
        currentModel != nil && panel.isVisible
    }
    var hasRecoverableToast: Bool {
        currentModel != nil
    }

    func recoverIfPossible() -> UInt64? {
        guard !panel.isVisible,
              let model = currentModel,
              let screen = currentScreen,
              let visibleFrame = currentVisibleFrame else { return nil }
        if let dismissalDeadline, dismissalDeadline <= Date() {
            let generation = model.generation
            hide()
            return generation
        }
        let duration = dismissalDeadline.map {
            max(0, $0.timeIntervalSinceNow)
        } ?? currentDuration
        present(
            model,
            duration: duration,
            maximumSize: currentMaximumSize,
            visibleFrame: visibleFrame,
            screen: screen,
            bottomOffset: currentBottomOffset
        )
        return nil
    }
    var isVisible: Bool {
        panel.isVisible
    }
    var isDismissingToast: Bool {
        isDismissing
    }

    var presentedVisibleFrame: CGRect? {
        currentScreen?.visibleFrame ?? currentVisibleFrame
    }

    var presentedScreen: NSScreen? {
        currentScreen
    }

    func refreshScreenFrame() {
        guard currentModel != nil else { return }
        let screen = currentScreen.flatMap { NSScreen.screens.contains($0) ? $0 : nil }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        currentScreen = screen
        currentVisibleFrame = screen?.visibleFrame
    }

    var activeGeneration: UInt64? {
        currentModel?.generation
    }

    func requiredHeight(in visibleFrame: CGRect) -> CGFloat {
        let availableSize = ToastLayout.availableSize(
            in: visibleFrame,
            maximumSize: currentMaximumSize
        )
        return measuredContentSize(maximumSize: availableSize).height
    }

}

extension ToastPanelController {
    private func layoutCurrentPanel() {
        guard let visibleFrame = currentScreen?.visibleFrame
                ?? currentVisibleFrame
                ?? presentationScreen()?.visibleFrame else {
            panel.orderOut(nil)
            return
        }
        let availableSize = ToastLayout.availableSize(
            in: visibleFrame,
            maximumSize: currentMaximumSize,
            bottomOffset: currentBottomOffset
        )
        let frame = ToastLayout.frame(
            contentSize: measuredContentSize(maximumSize: availableSize),
            in: visibleFrame,
            maximumSize: currentMaximumSize,
            bottomOffset: currentBottomOffset
        )
        layoutContent(size: frame.size)
        panel.setFrame(frame, display: true)
    }

    private func configurePanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.contentView = contentView
    }

    private func configureContent() {
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = AppTheme.surface.cgColor
        contentView.layer?.borderColor = AppTheme.border.cgColor
        contentView.layer?.borderWidth = 1
        contentView.layer?.cornerRadius = Self.cornerRadius
        contentView.layer?.masksToBounds = true
        contentView.onPress = { [weak self] in self?.dismissFromUserInteraction() }
        contentView.onAction = { [weak self] in self?.performUserAction() }
        contentView.setAccessibilityElement(true)
        contentView.setAccessibilityRole(.button)
        contentView.setAccessibilityLabel("Dismiss notification")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.unregisterDraggedTypes()
        contentView.addSubview(iconView)

        summaryLabel.font = .systemFont(ofSize: 15.75, weight: .semibold)
        summaryLabel.textColor = AppTheme.primaryText
        summaryLabel.backgroundColor = .clear
        summaryLabel.isBordered = false
        summaryLabel.isEditable = false
        summaryLabel.isSelectable = false
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.cell?.wraps = true
        summaryLabel.cell?.usesSingleLineMode = false
        summaryLabel.cell?.truncatesLastVisibleLine = true
        contentView.addSubview(summaryLabel)

        detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = AppTheme.secondaryText
        detailLabel.backgroundColor = .clear
        detailLabel.isBordered = false
        detailLabel.isEditable = false
        detailLabel.isSelectable = false
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        contentView.addSubview(detailLabel)

        sourceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sourceLabel.textColor = AppTheme.primaryText
        sourceLabel.backgroundColor = .clear
        sourceLabel.isBordered = false
        sourceLabel.isEditable = false
        sourceLabel.isSelectable = false
        sourceLabel.lineBreakMode = .byWordWrapping
        sourceLabel.maximumNumberOfLines = 0
        contentView.addSubview(sourceLabel)
    }

    private func updateContent(for model: ToastModel) {
        iconView.image = model.icon
        summaryLabel.stringValue = model.summary
        detailLabel.stringValue = model.detail ?? ""
        sourceLabel.stringValue = model.footer?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        summaryLabel.setAccessibilityLabel(model.summary)
        detailLabel.setAccessibilityLabel(model.detail)
        sourceLabel.setAccessibilityLabel(
            sourceLabel.stringValue.isEmpty ? nil : sourceLabel.stringValue
        )
    }

    private func measuredContentSize(maximumSize: CGSize) -> CGSize {
        contentLayout.measuredContentSize(
            maximumSize: maximumSize,
            showsImagePreview: currentModel?.showsImagePreview == true
        )
    }

    static func summarySize(for label: NSTextField, maximumSize: CGSize) -> CGSize {
        ToastContentLayout.summarySize(for: label, maximumSize: maximumSize)
    }

    static func displayedIconSize(hasIcon: Bool, showsImagePreview: Bool) -> CGFloat {
        ToastContentLayout.displayedIconSize(
            hasIcon: hasIcon,
            showsImagePreview: showsImagePreview
        )
    }

    private func layoutContent(size: CGSize) {
        contentLayout.layout(
            size: size,
            showsImagePreview: currentModel?.showsImagePreview == true
        )
    }

    private func presentationScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func animateIn(to finalFrame: CGRect) {
        panel.setFrame(finalFrame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func animateOut(generation: UInt64) {
        animationToken &+= 1
        let token = animationToken
        let reduceMotion = reduceMotion()
        let finalFrame = reduceMotion
            ? panel.frame
            : panel.frame.offsetBy(dx: 0, dy: Self.slideDistance)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !reduceMotion {
                panel.animator().setFrame(finalFrame, display: true)
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationToken == token else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.currentModel = nil
                self.dismissalDeadline = nil
                self.currentDuration = .infinity
                self.currentVisibleFrame = nil
                self.currentBottomOffset = 0
                self.isDismissing = false
                self.setUserAction(nil)
                self.clearContent()
                self.onDismissComplete()
            }
        }

        onDismiss(generation)
    }

    private func scheduleDismissal(after duration: TimeInterval) {
        guard duration.isFinite else { return }
        let timer = Timer(
            timeInterval: duration,
            target: self,
            selector: #selector(dismissalTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        dismissalTimer = timer
    }

    private func stopDismissalTimer() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
    }

    private func clearContent() {
        iconView.image = nil
        summaryLabel.stringValue = ""
        detailLabel.stringValue = ""
        sourceLabel.stringValue = ""
        summaryLabel.setAccessibilityLabel(nil)
        detailLabel.setAccessibilityLabel(nil)
        sourceLabel.setAccessibilityLabel(nil)
    }

    private func performUserAction() {
        guard let userAction,
              !isDismissing,
              let generation = currentModel?.generation else { return }
        let interactionToken = animationToken
        userAction()
        guard animationToken == interactionToken,
              currentModel?.generation == generation,
              !isDismissing else { return }
        dismissFromUserInteraction()
    }

    private func dismissFromUserInteraction() {
        guard dismiss() else { return }
        onUserDismiss()
    }

    @objc private func dismissalTimerFired() {
        dismissalTimer = nil
        dismiss()
    }
}
