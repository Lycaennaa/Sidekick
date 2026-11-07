import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ClipboardImagePreviewIntegrationTests: XCTestCase {
    func testDefaultDependenciesOpenARealImageInPreview() async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") != nil
        else {
            throw XCTSkip("Preview.app is unavailable")
        }
        let candidates = [
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns",
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ToolbarCustomizeIcon.icns"
        ].map(URL.init(fileURLWithPath:))
        guard let fixtureURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw XCTSkip("No system image fixture is available")
        }
        // Default configuration reuses existing Preview; require a clean session for ownership.
        let runningPreviewProcessIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.Preview"
            ).map(\.processIdentifier)
        )
        guard runningPreviewProcessIDs.isEmpty else {
            throw XCTSkip("Preview.app is already running")
        }
        let applicationOwner = PreviewApplicationOwner()
        addTeardownBlock { @MainActor in
            let terminated = await applicationOwner.requestTeardown()
            XCTAssertTrue(terminated, "Owned Preview application did not terminate")
        }
        let opened = expectation(description: "Preview opened a real image")
        let applicationOpened = expectation(description: "Preview application launched")
        let opener = ClipboardImagePreviewOpener(
            settings: makeSettings(),
            onApplicationResolved: { application in
                let captured = await applicationOwner.capture(application)
                if !captured {
                    XCTFail("Preview launch did not return an application")
                }
                applicationOpened.fulfill()
            },
            onOpenResult: { succeeded in
                if !succeeded {
                    XCTFail("Preview.app rejected the image")
                }
                opened.fulfill()
            }
        )
        defer { opener.terminate() }

        opener.open(
            ClipboardImageEnrichmentRequest(
                generation: 6,
                localFileURL: fixtureURL,
                typeIdentifier: UTType(filenameExtension: "icns")?.identifier ?? "com.apple.icns"
            )
        )
        await fulfillment(of: [opened, applicationOpened], timeout: 5)
    }
    func testDefaultFallbackOpensRealImage() async throws {
        let candidates = [
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns",
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ToolbarCustomizeIcon.icns"
        ].map(URL.init(fileURLWithPath:))
        guard let fixtureURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw XCTSkip("No system image fixture is available")
        }
        guard let defaultApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: fixtureURL),
              let defaultBundleIdentifier = Bundle(url: defaultApplicationURL)?.bundleIdentifier
        else {
            throw XCTSkip("No default image application is available")
        }
        let runningDefaultApplicationIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: defaultBundleIdentifier
            ).map(\.processIdentifier)
        )
        guard runningDefaultApplicationIDs.isEmpty else {
            throw XCTSkip("Default image application is already running")
        }
        let applicationOwner = PreviewApplicationOwner()
        addTeardownBlock { @MainActor in
            let terminated = await applicationOwner.requestTeardown()
            XCTAssertTrue(terminated, "Owned default image application did not terminate")
        }
        let opened = expectation(description: "Default fallback opened a real image")
        let applicationOpened = expectation(description: "Default fallback launched an application")
        let opener = ClipboardImagePreviewOpener(
            settings: makeSettings(),
            resolvePreviewApplication: { nil },
            onApplicationResolved: { application in
                let captured = await applicationOwner.capture(application)
                if !captured {
                    XCTFail("Default fallback did not return an application")
                }
                applicationOpened.fulfill()
            },
            onOpenResult: { succeeded in
                if !succeeded {
                    XCTFail("Default fallback rejected the image")
                }
                opened.fulfill()
            }
        )
        defer { opener.terminate() }

        opener.open(
            ClipboardImageEnrichmentRequest(
                generation: 7,
                localFileURL: fixtureURL,
                typeIdentifier: UTType(filenameExtension: "icns")?.identifier ?? "com.apple.icns"
            )
        )
        await fulfillment(of: [opened, applicationOpened], timeout: 5)
    }
}

@MainActor
private enum PreviewApplicationOwnerState {
    case accepting
    case awaitingApplication
    case terminating
    case finished
    case noApplication
}

@MainActor
private final class PreviewApplicationOwner {
    private var application: NSRunningApplication?
    private var state = PreviewApplicationOwnerState.accepting
    private var applicationContinuation: CheckedContinuation<NSRunningApplication?, Never>?

    func capture(_ application: NSRunningApplication?) async -> Bool {
        guard let application else {
            switch state {
            case .accepting, .awaitingApplication:
                state = .noApplication
                applicationContinuation?.resume(returning: nil)
                applicationContinuation = nil
            case .terminating, .finished, .noApplication:
                break
            }
            return false
        }
        self.application = application
        switch state {
        case .accepting:
            return true
        case .awaitingApplication:
            if let continuation = applicationContinuation {
                applicationContinuation = nil
                continuation.resume(returning: application)
            }
            return true
        case .terminating:
            return true
        case .finished, .noApplication:
            state = .terminating
            let terminated = await terminatePreviewApplication(application)
            state = .finished
            return terminated
        }
    }

    func requestTeardown() async -> Bool {
        switch state {
        case .finished, .noApplication:
            return true
        case .terminating, .awaitingApplication:
            return application?.isTerminated == true
        case .accepting:
            break
        }
        state = .awaitingApplication
        let application = await withTaskGroup(of: NSRunningApplication?.self) { group in
            group.addTask { [weak self] in
                await self?.waitForApplication()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return nil
                }
                return nil
            }
            let application = await group.next()
            group.cancelAll()
            return application
        } ?? self.application
        guard let application else {
            if case .noApplication = state {
                state = .finished
                return true
            }
            state = .finished
            return false
        }
        state = .terminating
        let terminated = await terminatePreviewApplication(application)
        state = .finished
        return terminated
    }

    private func waitForApplication() async -> NSRunningApplication? {
        if let application {
            return application
        }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if let application = self.application {
                    continuation.resume(returning: application)
                } else {
                    self.applicationContinuation = continuation
                }
            }
        }, onCancel: {
            Task { @MainActor in
                self.applicationContinuation?.resume(returning: nil)
                self.applicationContinuation = nil
            }
        })
    }
}
private actor PreviewTerminationWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    func wait() async -> Bool {
        guard !finished else { return true }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if self.finished {
                    continuation.resume(returning: true)
                } else {
                    self.continuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.finish(false) }
        })
    }

    func finish(_ terminated: Bool) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: terminated)
        continuation = nil
    }
}

@MainActor
private func waitForPreviewTermination(
    _ application: NSRunningApplication,
    force: Bool
) async -> Bool {
    if application.isTerminated {
        return true
    }
    let waiter = PreviewTerminationWaiter()
    let notificationCenter = NSWorkspace.shared.notificationCenter
    let observer = notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
    ) { notification in
        guard let terminatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
            terminatedApplication.isEqual(application)
        else {
            return
        }
        Task { await waiter.finish(true) }
    }
    defer { notificationCenter.removeObserver(observer) }
    if force {
        _ = application.forceTerminate()
    } else {
        _ = application.terminate()
    }
    if application.isTerminated {
        return true
    }
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await waiter.wait()
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                await waiter.finish(false)
                return false
            }
            await waiter.finish(false)
            return false
        }
        let terminated = await group.next() ?? false
        group.cancelAll()
        return terminated || application.isTerminated
    }
}

@MainActor
private func terminatePreviewApplication(_ application: NSRunningApplication) async -> Bool {
    guard await waitForPreviewTermination(application, force: false) else {
        return await waitForPreviewTermination(application, force: true)
    }
    return true
}

@MainActor
private func makeSettings() -> AppSettings {
    let suiteName = "ClipboardImagePreviewOpenerTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Unable to create test defaults suite")
    }
    return AppSettings(defaults: defaults)
}
