import CoreGraphics

struct ToastLayout {
    static let maximumSize = CGSize(width: 800, height: 360)
    static let twitchMaximumSize = maximumSize
    static let screenInset: CGFloat = 16
    static let stackSpacing: CGFloat = 12

    static func availableSize(
        in visibleFrame: CGRect,
        maximumSize: CGSize = ToastLayout.maximumSize,
        bottomOffset: CGFloat = 0
    ) -> CGSize {
        let stackOffset = max(0, bottomOffset)
        return CGSize(
            width: min(maximumSize.width, max(0, visibleFrame.width - (screenInset * 2))),
            height: min(
                maximumSize.height,
                max(0, visibleFrame.height - (screenInset * 2) - stackOffset)
            )
        )
    }

    static func frame(
        contentSize: CGSize,
        in visibleFrame: CGRect,
        maximumSize: CGSize = ToastLayout.maximumSize,
        bottomOffset: CGFloat = 0
    ) -> CGRect {
        let availableSize = availableSize(
            in: visibleFrame,
            maximumSize: maximumSize,
            bottomOffset: bottomOffset
        )
        let width = min(availableSize.width, max(0, contentSize.width))
        let height = min(availableSize.height, max(0, contentSize.height))

        return CGRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.minY + screenInset + max(0, bottomOffset),
            width: width,
            height: height
        )
    }
}
