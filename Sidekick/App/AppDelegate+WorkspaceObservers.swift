import AppKit
import Foundation

extension AppDelegate {
    func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc func workspaceWillSleep(_ notification: Notification) {
        clipboardToastController?.addSuspension(.systemSleeping)
    }

    @objc func workspaceDidWake(_ notification: Notification) {
        clipboardToastController?.removeSuspension(.systemSleeping)
    }

    @objc func sessionDidResignActive(_ notification: Notification) {
        clipboardToastController?.addSuspension(.sessionInactive)
    }

    @objc func sessionDidBecomeActive(_ notification: Notification) {
        clipboardToastController?.removeSuspension(.sessionInactive)
    }

    @objc func screenDidLock(_ notification: Notification) {
        clipboardToastController?.addSuspension(.screenLocked)
    }

    @objc func screenDidUnlock(_ notification: Notification) {
        clipboardToastController?.removeSuspension(.screenLocked)
    }

    @objc func screenParametersDidChange(_ notification: Notification) {
        toastPresentationCoordinator?.relayoutForScreenChanges()
    }

}
