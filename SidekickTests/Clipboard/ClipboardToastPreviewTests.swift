import AppKit
import UniformTypeIdentifiers
import XCTest
@MainActor
final class ClipboardToastPreviewTests: XCTestCase {
    func testImageToastPublishesCapturedPreviewAction() async throws {
        let suiteName = "ClipboardToastPreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let pasteboard = NSPasteboard(name: .init("ClipboardToastPreviewTests.\(UUID().uuidString)"))
        let source = ClipboardSourceApplication(name: "App", bundleIdentifier: "test.app")
        var toast: ToastModel?
        var previewAction: ClipboardImagePreviewAction?
        let presented = expectation(description: "Image toast presented")
        let controller = ClipboardToastController(
            settings: settings,
            pasteboard: pasteboard,
            sourceApplication: { source },
            workspaceNotificationCenter: NotificationCenter(),
            onToastChange: { model in
                guard model?.presentationStyle == .image else { return }
                toast = model
                presented.fulfill()
            },
            onToastUpdate: { _ in },
            onImagePreview: { action in previewAction = action }
        )
        defer { controller.terminate() }

        writeText("baseline", to: pasteboard)
        controller.start()
        writePNG(Data([1, 2, 3]), to: pasteboard)
        controller.poll()
        controller.poll()
        await fulfillment(of: [presented], timeout: 1)

        let model = try XCTUnwrap(toast)
        model.onUserAction?()
        let action = try XCTUnwrap(previewAction)
        let request = action.request
        XCTAssertEqual(request.generation, model.generation)
        controller.toastDidDismiss(generation: model.generation)
        XCTAssertTrue(action.isCurrent())
        writePNG(Data([4, 5, 6]), to: pasteboard)
        XCTAssertFalse(action.isCurrent())
        if case let .data(data, typeIdentifier) = request.source {
            XCTAssertEqual(data, Data([1, 2, 3]))
            XCTAssertEqual(typeIdentifier, NSPasteboard.PasteboardType.png.rawValue)
        } else {
            XCTFail("Expected captured image data")
        }
    }
    func testPresentationCoordinatorDeliversActionToToastPanel() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var actionCount = 0
        let model = ToastModel(
            generation: 1,
            presentationStyle: .image,
            summary: "Copied image",
            detail: nil,
            icon: nil,
            onUserAction: { actionCount += 1 }
        )
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertNotNil(
            coordinator.presentGeneral(
                model,
                duration: .infinity,
                visibleFrame: visibleFrame
            )
        )
        let panel = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? ToastPanel }.last
        )
        let contentView = try XCTUnwrap(panel.contentView as? ToastContentView)

        XCTAssertTrue(contentView.accessibilityPerformPress())
        XCTAssertEqual(actionCount, 1)
        XCTAssertTrue(
            contentView.gestureRecognizers.contains {
                ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2
            }
        )
        XCTAssertTrue(contentView.gestureRecognizers.contains { $0 is NSPressGestureRecognizer })
        coordinator.hideGeneral()
    }
    func testPointerPressDismissesActionToastWithoutOpeningPreview() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var actionCount = 0
        let model = ToastModel(
            generation: 2,
            presentationStyle: .image,
            summary: "Copied image",
            detail: nil,
            icon: nil,
            onUserAction: { actionCount += 1 }
        )
        let id = try XCTUnwrap(
            coordinator.presentGeneral(
                model,
                duration: .infinity,
                visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        )
        let panel = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? ToastPanel }.last
        )
        let contentView = try XCTUnwrap(panel.contentView as? ToastContentView)

        contentView.onPress?()

        XCTAssertEqual(actionCount, 0)
        XCTAssertTrue(stack.isDismissing(id))
        coordinator.hideAll()
    }

    func testDefaultDiscoveryFindsAnApplicationAdvertisingImageOpening() {
        let applications = ClipboardImageOpeningApplications.advertised()

        XCTAssertFalse(applications.isEmpty)
        XCTAssertTrue(applications.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(applications.allSatisfy { $0.url.pathExtension == "app" })
    }

    func testPreviewApplicationIsAvailableAsSystemDefault() throws {
        let previewApplication = try XCTUnwrap(ClipboardImageOpeningApplications.previewApplication())

        XCTAssertEqual(previewApplication.name, "Preview")
        XCTAssertEqual(previewApplication.url.pathExtension, "app")
    }

    func testDiscoveryOmitsKnownTextEditorsAndBrowsers() {
        let discoveredBundleIdentifiers = Set(
            ClipboardImageOpeningApplications.advertised().compactMap {
                Bundle(url: $0.url)?.bundleIdentifier
            }
        )
        let excludedBundleIdentifiers: Set<String> = [
            "com.apple.Safari",
            "com.apple.TextEdit",
            "com.apple.Notes",
            "com.apple.dt.Xcode",
            "com.google.Chrome",
            "com.brave.Browser",
            "org.mozilla.firefox",
            "net.mullvad.mullvadbrowser",
            "com.vscodium",
            "dev.zed.Zed",
            "com.onderk.codepeekplus"
        ]

        XCTAssertTrue(discoveredBundleIdentifiers.isDisjoint(with: excludedBundleIdentifiers))
    }

    func testDiscoveryUsesImageAndTextHandlerQueries() {
        var queriedContentTypeIdentifiers = [String]()
        let allowedURL = URL(fileURLWithPath: "/Applications/ImageViewer.app")
        let textURL = URL(fileURLWithPath: "/Applications/TextEditor.app")
        let browserURL = URL(fileURLWithPath: "/Applications/Browser.app")
        let applicationURLs = [
            "allowed": allowedURL,
            "text": textURL,
            "browser": browserURL
        ]
        let handlersByContentType = [
            UTType.png.identifier: ["allowed", "text"],
            UTType.jpeg.identifier: ["browser"],
            UTType.text.identifier: ["text"]
        ]
        let discovery = ClipboardImageOpeningApplicationDiscovery(
            handlerQuery: { contentTypeIdentifier in
                queriedContentTypeIdentifiers.append(contentTypeIdentifier)
                return handlersByContentType[contentTypeIdentifier] ?? []
            },
            applicationURLQuery: { applicationBundleIdentifier in
                applicationURLs[applicationBundleIdentifier]
            },
            metadataQuery: { applicationURL in
                ClipboardImageOpeningApplicationMetadata(
                    name: applicationURL.lastPathComponent,
                    handlesWebURLs: applicationURL == browserURL
                )
            }
        )

        let candidates = discovery.discover()
        let filteredApplications = ClipboardImageOpeningApplicationPolicy.filtered(
            candidates: candidates
        )

        XCTAssertTrue(queriedContentTypeIdentifiers.contains("public.avif"))
        XCTAssertTrue(queriedContentTypeIdentifiers.contains(UTType.text.identifier))
        XCTAssertEqual(filteredApplications.map(\.url), [allowedURL])
    }

    func testApplicationPolicyExcludesTextAndBrowserCandidates() {
        let allowedApplication = ClipboardImageOpeningApplication(
            url: URL(fileURLWithPath: "/Applications/ImageViewer.app"),
            name: "Image Viewer"
        )
        let textApplication = ClipboardImageOpeningApplication(
            url: URL(fileURLWithPath: "/Applications/TextEditor.app"),
            name: "Text Editor"
        )
        let browserApplication = ClipboardImageOpeningApplication(
            url: URL(fileURLWithPath: "/Applications/Browser.app"),
            name: "Browser"
        )
        let candidates = [
            ClipboardImageOpeningApplicationCandidate(
                application: textApplication,
                isTextHandler: true,
                handlesWebURLs: false
            ),
            ClipboardImageOpeningApplicationCandidate(
                application: browserApplication,
                isTextHandler: false,
                handlesWebURLs: true
            ),
            ClipboardImageOpeningApplicationCandidate(
                application: allowedApplication,
                isTextHandler: false,
                handlesWebURLs: false
            )
        ]

        XCTAssertEqual(
            ClipboardImageOpeningApplicationPolicy.filtered(candidates: candidates),
            [allowedApplication]
        )
    }

    func testConfiguredApplicationIsUsedWhenItExists() throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appendingPathComponent("CustomImageViewer.app")
        try makeApplicationBundle(at: applicationURL)
        let suiteName = "ClipboardToastPreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.clipboardImageOpeningApplicationURL = applicationURL

        let sourceURL = directory.appendingPathComponent("source.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: Data([1])))
        let capture = ImageOpeningApplicationCapture()
        let opener = ClipboardImagePreviewOpener(
            settings: settings,
            artifactStore: ClipboardImagePreviewArtifactStore(outputDirectory: directory),
            resolvePreviewApplication: { URL(fileURLWithPath: "/Applications/Preview.app") },
            openInApplication: { urls, openedApplicationURL, completion in
                capture.urls = urls
                capture.applicationURL = openedApplicationURL
                completion(nil, nil)
            }
        )

        opener.open(
            ClipboardImageEnrichmentRequest(
                generation: 6,
                localFileURL: sourceURL,
                typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
            )
        )

        XCTAssertEqual(capture.applicationURL?.path, applicationURL.path)
        opener.terminate()
    }

    func testStaleOpenFailureDoesNotPresentFailureToast() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: Data([1])))
        let capture = ImageOpeningApplicationCapture()
        let completionProcessed = expectation(description: "Stale opener completion processed")
        capture.completionProcessed = completionProcessed
        let opener = ClipboardImagePreviewOpener(
            settings: AppSettings(),
            artifactStore: ClipboardImagePreviewArtifactStore(outputDirectory: directory),
            openInApplication: { _, _, completion in
                capture.completion = { error in
                    completion(nil, error)
                    Task { @MainActor in capture.completionProcessed?.fulfill() }
                }
            },
            onFailure: { capture.failureCount += 1 }
        )

        opener.open(
            ClipboardImageEnrichmentRequest(
                generation: 7,
                localFileURL: sourceURL,
                typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
            ),
            isCurrent: { capture.isCurrent }
        )
        capture.isCurrent = false
        capture.completion?(CocoaError(.fileNoSuchFile))
        await fulfillment(of: [completionProcessed], timeout: 1)

        XCTAssertEqual(capture.failureCount, 0)
        opener.terminate()
    }

    private func makeApplicationBundle(at applicationURL: URL) throws {
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOSURL,
            withIntermediateDirectories: true
        )
        let infoDictionary: [String: Any] = [
            "CFBundleIdentifier": "test.custom.image-viewer",
            "CFBundleExecutable": "CustomImageViewer",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: infoDictionary,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let executableURL = macOSURL.appendingPathComponent("CustomImageViewer")
        XCTAssertTrue(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    private func makeTemporaryDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".kilo-tmp/ClipboardToastPreviewTests.\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func writeText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
    }

    private func writePNG(_ data: Data, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        pasteboard.writeObjects([item])
    }
}
@MainActor
private final class ImageOpeningApplicationCapture {
    var urls: [URL] = []
    var applicationURL: URL?
    var completion: (@Sendable (Error?) -> Void)?
    var completionProcessed: XCTestExpectation?
    var isCurrent = true
    var failureCount = 0
}
