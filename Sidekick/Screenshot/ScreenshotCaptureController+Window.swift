import AppKit
import CoreGraphics

extension ScreenshotCaptureController {
    func captureSelectedWindow(_ request: RequestState, mode: ScreenshotCaptureMode) async {
        guard hasWindowCaptureAccess() else {
            activeRequestID = nil
            onFailure(.capture)
            return
        }
        let selection = WindowScreenshotSelection.Session()
        defer { selection.close() }
        do {
            for attempt in 1...Self.windowInventoryAttemptLimit {
                let inventory = try await windowInventory()
                guard isWindowCaptureRequestActive(request) else { return }
                guard !selection.isCancelled else {
                    cancelWindowCaptureRequest(request)
                    return
                }
                guard !inventory.windows.isEmpty else {
                    guard attempt == Self.windowInventoryAttemptLimit else { continue }
                    selection.close()
                    activeRequestID = nil
                    onFailure(.noCapturableWindow)
                    return
                }
                selection.update(windows: inventory.windows)
                guard let windowID = await selection.waitForSelection() else {
                    cancelWindowCaptureRequest(request)
                    return
                }
                guard isWindowCaptureRequestActive(request) else { return }
                selection.close()
                let image = try await WindowScreenshotCapture.capture(
                    windowID: windowID,
                    from: inventory,
                    showsCursor: request.showsCursor
                )
                guard isWindowCaptureRequestActive(request) else { return }
                await copyWindowImage(image, mode: mode, request: request)
                return
            }
        } catch {
            if selection.isCancelled {
                cancelWindowCaptureRequest(request)
            } else {
                failWindowCapture(request)
            }
        }
    }
}

private extension ScreenshotCaptureController {
    func isWindowCaptureRequestActive(_ request: RequestState) -> Bool {
        guard activeRequestID == request.id else { return false }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return false
        }
        return true
    }

    func cancelWindowCaptureRequest(_ request: RequestState) {
        if activeRequestID == request.id { activeRequestID = nil }
    }

    func failWindowCapture(_ request: RequestState) {
        guard activeRequestID == request.id else { return }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return
        }
        activeRequestID = nil
        onFailure(.capture)
    }
}
