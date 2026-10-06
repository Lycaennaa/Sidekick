import AppKit

@MainActor
final class ToastPresentationCoordinator {
    typealias ID = ToastStackController.ID

    private enum Policy {
        static let general = ToastStackEntryConfiguration(
            maximumSize: ToastLayout.maximumSize,
            layoutPriority: 1,
            preservesRecoverableToast: true
        )
        static let microphone = ToastStackEntryConfiguration(
            maximumSize: ToastLayout.maximumSize,
            layoutPriority: 0,
            preservesRecoverableToast: true
        )
        static let twitch = ToastStackEntryConfiguration(
            maximumSize: ToastLayout.twitchMaximumSize,
            layoutPriority: 2,
            preservesRecoverableToast: false
        )
        static let maximumEntries = 7
        static let maximumTwitchEntries = 4
    }

    private let stack: ToastStackController
    private var generalID: ID?
    private var screenshotID: ID?
    private var microphoneID: ID?
    private var temporaryVolumeID: ID?
    private var twitchIDs: [ID] = []

    init(stack: ToastStackController) {
        self.stack = stack
    }

    func relayoutForScreenChanges() {
        stack.relayoutForScreenChanges()
    }
    @discardableResult
    func presentGeneral(
        _ model: ToastModel,
        duration: TimeInterval,
        onDismiss: ((UInt64) -> Void)? = nil,
        visibleFrame: CGRect? = nil
    ) -> ID? {
        pruneIDs()
        if let id = generalID,
           stack.replace(
               model,
               for: id,
               duration: duration,
               onDismiss: { [weak self] generation in
                   self?.generalDidDismiss(generation, onDismiss: onDismiss)
               },
               visibleFrame: visibleFrame
           ) {
            return id
        }
        generalID = nil

        guard entryCount < Policy.maximumEntries else {
            onDismiss?(model.generation)
            return nil
        }
        let id = stack.present(
            model,
            configuration: Policy.general,
            duration: duration,
            onDismiss: { [weak self] generation in
                self?.generalDidDismiss(generation, onDismiss: onDismiss)
            },
            visibleFrame: visibleFrame
        )
        generalID = id
        return id
    }
    @discardableResult
    func presentScreenshot(
        _ model: ToastModel,
        duration: TimeInterval,
        visibleFrame: CGRect? = nil
    ) -> ID? {
        pruneIDs()
        if let id = screenshotID,
           stack.replace(
               model,
               for: id,
               duration: duration,
               onDismiss: nil,
               visibleFrame: visibleFrame
           ) {
            return id
        }
        screenshotID = nil
        guard entryCount < Policy.maximumEntries else { return nil }
        screenshotID = stack.present(
            model,
            configuration: Policy.general,
            duration: duration,
            visibleFrame: visibleFrame
        )
        return screenshotID
    }

    func updateGeneral(_ model: ToastModel) {
        guard let generalID else { return }
        stack.update(model, for: generalID)
    }

    func hideGeneral() {
        guard let generalID else { return }
        self.generalID = nil
        stack.hide(generalID)
    }

    @discardableResult
    func presentMicrophone(
        _ model: ToastModel,
        duration: TimeInterval,
        onUserDismiss: (() -> Void)? = nil,
        visibleFrame: CGRect? = nil
    ) -> ID? {
        pruneIDs()
        if let id = microphoneID,
           stack.replace(
               model,
               for: id,
               duration: duration,
               onDismiss: nil,
               onUserDismiss: onUserDismiss,
               visibleFrame: visibleFrame
           ) {
            return id
        }
        microphoneID = stack.present(
            model,
            configuration: Policy.microphone,
            duration: duration,
            onUserDismiss: onUserDismiss,
            visibleFrame: visibleFrame
        )
        return microphoneID
    }

    var isMicrophonePresented: Bool {
        guard let microphoneID else { return false }
        return stack.isPresented(microphoneID) && !stack.isDismissing(microphoneID)
    }

    func hideMicrophone() {
        guard let microphoneID else { return }
        self.microphoneID = nil
        stack.hide(microphoneID)
    }

    @discardableResult
    func presentTemporaryVolume(
        _ model: ToastModel,
        duration: TimeInterval,
        visibleFrame: CGRect? = nil
    ) -> ID? {
        pruneIDs()
        if let id = temporaryVolumeID,
           stack.replace(
               model,
               for: id,
               duration: duration,
               onDismiss: nil,
               visibleFrame: visibleFrame
           ) {
            return id
        }
        temporaryVolumeID = nil
        guard entryCount < Policy.maximumEntries else { return nil }
        temporaryVolumeID = stack.present(
            model,
            configuration: Policy.general,
            duration: duration,
            visibleFrame: visibleFrame
        )
        return temporaryVolumeID
    }

    @discardableResult
    func presentTwitch(
        _ model: ToastModel,
        duration: TimeInterval,
        visibleFrame: CGRect? = nil
    ) -> ID? {
        pruneIDs()
        if let id = twitchIDs.first(where: { stack.isDismissing($0) }),
           stack.replace(
               model,
               for: id,
               duration: duration,
               onDismiss: nil,
               visibleFrame: visibleFrame
           ) {
            return id
        }

        if twitchIDs.count >= Policy.maximumTwitchEntries {
            let oldestID = twitchIDs.removeFirst()
            stack.hide(oldestID)
        }
        guard entryCount < Policy.maximumEntries else { return nil }

        let id = stack.present(
            model,
            configuration: Policy.twitch,
            duration: duration,
            visibleFrame: visibleFrame
        )
        if let id { twitchIDs.append(id) }
        return id
    }

    func hideAll() {
        generalID = nil
        screenshotID = nil
        microphoneID = nil
        temporaryVolumeID = nil
        twitchIDs.removeAll()
        stack.hideAll()
    }

    private var entryCount: Int {
        [generalID, screenshotID, microphoneID, temporaryVolumeID]
            .compactMap(\.self)
            .count + twitchIDs.count
    }

    private func pruneIDs() {
        if let generalID, !stack.contains(generalID) {
            self.generalID = nil
        }
        if let screenshotID, !stack.contains(screenshotID) {
            self.screenshotID = nil
        }
        if let microphoneID, !stack.contains(microphoneID) {
            self.microphoneID = nil
        }
        if let temporaryVolumeID, !stack.contains(temporaryVolumeID) {
            self.temporaryVolumeID = nil
        }
        twitchIDs.removeAll { !stack.contains($0) }
    }

    private func generalDidDismiss(
        _ generation: UInt64,
        onDismiss: ((UInt64) -> Void)?
    ) {
        onDismiss?(generation)
    }

}
