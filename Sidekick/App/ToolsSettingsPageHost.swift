import AppKit

@MainActor
final class ToolsSettingsPageHost: NSView {
    private let pages: [(ToolsSettingsPage, NSView)]
    private(set) var selectedPage: ToolsSettingsPage

    init(pages: [(ToolsSettingsPage, NSView)], selectedPage: ToolsSettingsPage) {
        self.pages = pages
        self.selectedPage = selectedPage
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for (page, pageView) in pages {
            pageView.identifier = NSUserInterfaceItemIdentifier(page.title)
            pageView.isHidden = page != selectedPage
            pageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pageView)
            NSLayoutConstraint.activate([
                pageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                pageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                pageView.topAnchor.constraint(equalTo: topAnchor),
                pageView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func select(_ page: ToolsSettingsPage) {
        selectedPage = page
        for (pageType, pageView) in pages {
            pageView.isHidden = pageType != page
        }
    }
}
