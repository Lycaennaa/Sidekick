import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardImageOpeningApplicationPickerView: NSView {
    private static let defaultSelectionMarker = NSNull()

    private let settings: AppSettings
    private let popupButton = NSPopUpButton()
    private let selectionDescription = NSTextField(wrappingLabelWithString: "")

    init(settings: AppSettings) {
        self.settings = settings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        let selectedURL = settings.clipboardImageOpeningApplicationURL?.standardizedFileURL
        let selectedApplicationPath = selectedURL?.path
        let previewApplication = ClipboardImageOpeningApplications.previewApplication()
        let previewApplicationPath = previewApplication?.url.standardizedFileURL.path
        let advertisedApplications = ClipboardImageOpeningApplications.advertised().filter { application in
            guard let previewApplicationPath else { return true }
            return application.url.standardizedFileURL.path != previewApplicationPath
        }
        let isSystemDefaultSelection = selectedApplicationPath == nil
            || selectedApplicationPath == previewApplicationPath
        var selectedIndex = 0

        popupButton.removeAllItems()
        popupButton.addItem(
            withTitle: previewApplication.map { "\($0.name).app (System Default)" } ?? "System Default"
        )
        popupButton.item(at: 0)?.representedObject = Self.defaultSelectionMarker

        for application in advertisedApplications {
            popupButton.addItem(withTitle: application.name)
            let item = popupButton.item(at: popupButton.numberOfItems - 1)
            item?.representedObject = application.url as NSURL
            item?.image = NSWorkspace.shared.icon(forFile: application.url.path)
            item?.image?.size = NSSize(width: 16, height: 16)
            if application.url.standardizedFileURL.path == selectedApplicationPath {
                selectedIndex = popupButton.numberOfItems - 1
            }
        }

        if let selectedURL,
           !isSystemDefaultSelection,
           !advertisedApplications.contains(where: { $0.url.standardizedFileURL.path == selectedApplicationPath }) {
            let application = ClipboardImageOpeningApplication(
                url: selectedURL,
                name: ClipboardImageOpeningApplications.applicationName(for: selectedURL)
            )
            popupButton.insertItem(withTitle: "Custom: \(application.name)", at: 1)
            let item = popupButton.item(at: 1)
            item?.representedObject = application.url as NSURL
            item?.image = NSWorkspace.shared.icon(forFile: application.url.path)
            item?.image?.size = NSSize(width: 16, height: 16)
            selectedIndex = 1
        }

        popupButton.menu?.addItem(.separator())
        let chooseItem = NSMenuItem(
            title: "Choose Other Application…",
            action: #selector(chooseOtherApplication),
            keyEquivalent: ""
        )
        chooseItem.target = self
        popupButton.menu?.addItem(chooseItem)
        popupButton.selectItem(at: selectedIndex)
        selectionDescription.stringValue = isSystemDefaultSelection
            ? "Uses Preview when available, then the system default."
            : "Selected application opens copied image previews."
    }

    @objc private func selectionChanged() {
        guard let representedObject = popupButton.selectedItem?.representedObject else { return }
        if representedObject is NSNull {
            settings.clipboardImageOpeningApplicationURL = nil
        } else if let applicationURL = representedObject as? NSURL {
            settings.clipboardImageOpeningApplicationURL = applicationURL as URL
        } else {
            refresh()
            return
        }
        refresh()
    }

    @objc private func chooseOtherApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose"
        panel.message = "Choose an application for copied image previews."
        panel.begin { [weak self] response in
            guard let self,
                  response == .OK,
                  let applicationURL = panel.url,
                  applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                return
            }
            self.settings.clipboardImageOpeningApplicationURL = applicationURL
            self.refresh()
        }
    }

    private func buildView() {
        let titleLabel = NSTextField(labelWithString: "Copied Image Preview")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .left

        let detailLabel = NSTextField(
            wrappingLabelWithString:
                "Choose which application opens the image when you double-click "
                + "its clipboard toast."
        )
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left

        let pickerLabel = NSTextField(labelWithString: "Open images in:")
        pickerLabel.alignment = .left
        popupButton.target = self
        popupButton.action = #selector(selectionChanged)
        popupButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popupButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [pickerLabel, popupButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        selectionDescription.textColor = .secondaryLabelColor
        selectionDescription.font = .systemFont(ofSize: 12)
        selectionDescription.alignment = .left

        let stack = NSStackView(views: [titleLabel, detailLabel, row, selectionDescription])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selectionDescription.widthAnchor.constraint(equalTo: stack.widthAnchor),
            popupButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }
}
