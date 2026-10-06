import AppKit

@MainActor
struct ToastContentLayout {
    private static let horizontalPadding: CGFloat = 20
    private static let verticalPadding: CGFloat = 21
    private static let compactIconSize: CGFloat = 96
    private static let imagePreviewSize: CGFloat = 192
    private static let iconSpacing: CGFloat = 14
    private static let detailSpacing: CGFloat = 4
    private static let sourceSpacing: CGFloat = 8

    let contentView: NSView
    let iconView: NSImageView
    let summaryLabel: NSTextField
    let detailLabel: NSTextField
    let sourceLabel: NSTextField

    func measuredContentSize(maximumSize: CGSize, showsImagePreview: Bool) -> CGSize {
        let iconSize = displayedIconSize(showsImagePreview: showsImagePreview)
        let iconWidth = iconSize == 0 ? 0 : iconSize + Self.iconSpacing
        let maximumTextWidth = max(0, maximumSize.width - (Self.horizontalPadding * 2) - iconWidth)
        let hasDetail = !detailLabel.stringValue.isEmpty
        let hasSource = !sourceLabel.stringValue.isEmpty
        let detailSize = Self.wrappedTextSize(for: detailLabel, width: maximumTextWidth)
        let sourceSize = Self.wrappedTextSize(for: sourceLabel, width: maximumTextWidth)
        let detailHeight = hasDetail ? ceil(detailSize.height) : 0
        let sourceHeight = hasSource ? ceil(sourceSize.height) : 0
        let maximumSummarySize = maximumSummarySize(
            in: maximumSize,
            iconWidth: iconWidth
        )
        let summarySize = Self.summarySize(for: summaryLabel, maximumSize: maximumSummarySize)
        let textHeight = min(maximumSummarySize.height, ceil(summarySize.height))
            + (hasDetail ? Self.detailSpacing + detailHeight : 0)
            + (hasSource ? Self.sourceSpacing + sourceHeight : 0)
        let textWidth = min(
            maximumTextWidth,
            max(ceil(summarySize.width), ceil(detailSize.width), ceil(sourceSize.width))
        )
        return CGSize(
            width: min(maximumSize.width, textWidth + iconWidth + (Self.horizontalPadding * 2)),
            height: min(maximumSize.height, max(textHeight, iconSize) + (Self.verticalPadding * 2))
        )
    }

    func layout(size: CGSize, showsImagePreview: Bool) {
        contentView.frame = CGRect(origin: .zero, size: size)
        let iconSize = displayedIconSize(showsImagePreview: showsImagePreview)
        let iconWidth = iconSize == 0 ? 0 : iconSize + Self.iconSpacing
        iconView.frame = CGRect(
            x: Self.horizontalPadding,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        let textX = Self.horizontalPadding + iconWidth
        let textWidth = max(0, size.width - textX - Self.horizontalPadding)
        let detailHeight = detailLabel.stringValue.isEmpty
            ? 0
            : ceil(detailLabel.intrinsicContentSize.height)
        let sourceHeight = sourceLabel.stringValue.isEmpty
            ? 0
            : ceil(sourceLabel.intrinsicContentSize.height)
        let detailY = Self.verticalPadding
            + (sourceHeight > 0 ? sourceHeight + Self.sourceSpacing : 0)
        let summaryY = detailY
            + (detailHeight > 0 ? detailHeight + Self.detailSpacing : 0)
        summaryLabel.frame = CGRect(
            x: textX,
            y: summaryY,
            width: textWidth,
            height: max(0, size.height - Self.verticalPadding - summaryY)
        )
        detailLabel.frame = CGRect(
            x: textX,
            y: detailY,
            width: textWidth,
            height: detailHeight
        )
        sourceLabel.frame = CGRect(
            x: textX,
            y: Self.verticalPadding,
            width: textWidth,
            height: sourceHeight
        )
    }

    static func summarySize(for label: NSTextField, maximumSize: CGSize) -> CGSize {
        label.preferredMaxLayoutWidth = maximumSize.width
        return label.sizeThatFits(maximumSize)
    }

    static func displayedIconSize(hasIcon: Bool, showsImagePreview: Bool) -> CGFloat {
        guard hasIcon else { return 0 }
        return showsImagePreview ? imagePreviewSize : compactIconSize
    }

    private func displayedIconSize(showsImagePreview: Bool) -> CGFloat {
        Self.displayedIconSize(
            hasIcon: iconView.image != nil,
            showsImagePreview: showsImagePreview
        )
    }

    private func maximumSummarySize(in maximumSize: CGSize, iconWidth: CGFloat) -> CGSize {
        let textWidth = max(0, maximumSize.width - (Self.horizontalPadding * 2) - iconWidth)
        let textHeight = max(0, maximumSize.height - (Self.verticalPadding * 2))
        let hasDetail = !detailLabel.stringValue.isEmpty
        let hasSource = !sourceLabel.stringValue.isEmpty
        let detailHeight = hasDetail ? ceil(detailLabel.intrinsicContentSize.height) : 0
        let sourceHeight = hasSource ? ceil(sourceLabel.intrinsicContentSize.height) : 0
        return CGSize(
            width: textWidth,
            height: max(
                0,
                textHeight - detailHeight - (hasDetail ? Self.detailSpacing : 0)
                    - sourceHeight - (hasSource ? Self.sourceSpacing : 0)
            )
        )
    }

    private static func wrappedTextSize(for label: NSTextField, width: CGFloat) -> CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        label.preferredMaxLayoutWidth = width
        return label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
