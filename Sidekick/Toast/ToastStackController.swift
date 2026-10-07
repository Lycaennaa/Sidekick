import AppKit

@MainActor
final class ToastStackController {
    typealias ID = UInt64

    private struct Entry {
        let id: ID
        let configuration: ToastStackEntryConfiguration
        let panel: ToastPanelController
        var onDismiss: ((UInt64) -> Void)?
        var onUserDismiss: (() -> Void)?
        var dismissalNotified = false
    }

    private var entries: [Entry] = []
    private var nextID: ID = 0

    init() {}

    @discardableResult
    func present(
        _ model: ToastModel,
        configuration: ToastStackEntryConfiguration,
        duration: TimeInterval,
        onDismiss: ((UInt64) -> Void)? = nil,
        onUserDismiss: (() -> Void)? = nil,
        visibleFrame: CGRect? = nil
    ) -> ID? {
        let id = insert(
            model,
            duration: duration,
            configuration: configuration,
            onDismiss: onDismiss,
            onUserDismiss: onUserDismiss,
            visibleFrame: visibleFrame
        )
        relayout()
        return entries.contains { $0.id == id } ? id : nil
    }

    @discardableResult
    func replace(
        _ model: ToastModel,
        for id: ID,
        duration: TimeInterval,
        onDismiss: ((UInt64) -> Void)?,
        onUserDismiss: (() -> Void)? = nil,
        visibleFrame: CGRect? = nil
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let screen = entries[index].panel.presentedScreen
        let frame = visibleFrame
            ?? screen?.visibleFrame
            ?? entries[index].panel.presentedVisibleFrame
        entries[index].onDismiss = onDismiss
        entries[index].onUserDismiss = onUserDismiss
        entries[index].dismissalNotified = false
        entries[index].panel.present(
            model,
            duration: duration,
            maximumSize: entries[index].configuration.maximumSize,
            visibleFrame: frame,
            screen: screen
        )
        relayout()
        return entries.contains { $0.id == id }
    }

    func update(_ model: ToastModel, for id: ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].panel.update(model)
        relayout()
    }

    func contains(_ id: ID) -> Bool {
        entries.contains { $0.id == id }
    }

    func isPresented(_ id: ID) -> Bool {
        entries.contains {
            $0.id == id && $0.panel.isVisible
        }
    }

    func isDismissing(_ id: ID) -> Bool {
        entries.contains {
            $0.id == id && $0.panel.isDismissingToast
        }
    }

    func dismiss(_ id: ID) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }
        entry.panel.dismiss()
    }

    func hide(_ id: ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        let generation = entries[index].panel.activeGeneration
        removeEntry(
            at: index,
            hidePanel: true,
            dismissalGeneration: generation
        )
        relayout()
    }

    func hideAll() {
        for entry in entries {
            entry.panel.hide()
        }
        entries.removeAll()
    }

    func refreshAppearance() {
        for entry in entries {
            entry.panel.refreshAppearance()
        }
    }

    func presentedFrame(for id: ID) -> CGRect? {
        entries.first { $0.id == id }?.panel.presentedFrame
    }

    func relayoutForScreenChanges() {
        var expired: [(id: ID, generation: UInt64)] = []
        for entry in entries {
            entry.panel.refreshScreenFrame()
            if let generation = entry.panel.recoverIfPossible() {
                expired.append((entry.id, generation))
            }
        }
        for item in expired {
            guard let index = entries.firstIndex(where: { $0.id == item.id }) else {
                continue
            }
            removeEntry(
                at: index,
                hidePanel: false,
                dismissalGeneration: item.generation
            )
        }
        relayout()
    }

    private func insert(
        _ model: ToastModel,
        duration: TimeInterval,
        configuration: ToastStackEntryConfiguration,
        onDismiss: ((UInt64) -> Void)?,
        onUserDismiss: (() -> Void)?,
        visibleFrame: CGRect? = nil
    ) -> ID {
        let id = nextID
        nextID &+= 1
        let screen = entries.first?.panel.presentedScreen
        let frame = visibleFrame
            ?? screen?.visibleFrame
            ?? entries.first?.panel.presentedVisibleFrame
        let panel = ToastPanelController(
            onDismiss: { [weak self] generation in
                self?.panelDidBeginDismissal(id: id, generation: generation)
            },
            onUserDismiss: { [weak self] in
                self?.panelDidReceiveUserDismissal(id: id)
            },
            onDismissComplete: { [weak self] in
                self?.panelDidFinishDismissal(id: id)
            }
        )
        entries.append(
            Entry(
                id: id,
                configuration: configuration,
                panel: panel,
                onDismiss: onDismiss,
                onUserDismiss: onUserDismiss
            )
        )
        panel.present(
            model,
            duration: duration,
            maximumSize: configuration.maximumSize,
            visibleFrame: frame,
            screen: screen,
            bottomOffset: stackOffset(for: frame)
        )
        return id
    }

    private func panelDidReceiveUserDismissal(id: ID) {
        guard let callback = entries.first(where: { $0.id == id })?.onUserDismiss else {
            return
        }
        callback()
    }

    private func panelDidBeginDismissal(id: ID, generation: UInt64) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        notifyDismissal(of: &entries[index], generation: generation)
    }

    private func panelDidFinishDismissal(id: ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeEntry(at: index, hidePanel: false)
        relayout()
    }

    private func removeEntry(
        at index: Int,
        hidePanel: Bool,
        dismissalGeneration: UInt64? = nil
    ) {
        var entry = entries.remove(at: index)
        if hidePanel {
            entry.panel.hide()
        }
        notifyDismissal(of: &entry, generation: dismissalGeneration)
    }

    private func notifyDismissal(of entry: inout Entry, generation: UInt64?) {
        guard !entry.dismissalNotified, let generation else { return }
        entry.dismissalNotified = true
        entry.onDismiss?(generation)
    }

    private func stackOffset(for visibleFrame: CGRect?) -> CGFloat {
        guard let visibleFrame else { return 0 }
        return entries
            .sorted(by: layoutPrecedes)
            .reduce(into: 0) { offset, entry in
                guard entry.panel.isVisible,
                      entry.panel.presentedVisibleFrame == visibleFrame else { return }
                offset += entry.panel.presentedFrame.height + ToastLayout.stackSpacing
            }
    }

    private func layoutPrecedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        guard lhs.configuration.layoutPriority == rhs.configuration.layoutPriority else {
            return lhs.configuration.layoutPriority < rhs.configuration.layoutPriority
        }
        return lhs.id < rhs.id
    }

    private func relayout() {
        var stacks: [(visibleFrame: CGRect, nextOffset: CGFloat)] = []
        var invalid: [(id: ID, dismissalGeneration: UInt64?)] = []

        for entry in entries.sorted(by: layoutPrecedes) {
            guard entry.panel.isVisible,
                  let visibleFrame = entry.panel.presentedVisibleFrame else {
                if entry.configuration.preservesRecoverableToast,
                   entry.panel.hasRecoverableToast {
                    continue
                }
                let generation = entry.panel.activeGeneration
                entry.panel.hide()
                invalid.append((entry.id, generation))
                continue
            }

            let stackIndex = stacks.firstIndex { $0.visibleFrame == visibleFrame }
            let offset = stackIndex.map { stacks[$0].nextOffset } ?? 0
            let requiredHeight = entry.panel.requiredHeight(in: visibleFrame)
            let availableHeight = max(
                0,
                visibleFrame.height - (ToastLayout.screenInset * 2) - offset
            )
            guard requiredHeight > 0, availableHeight >= requiredHeight else {
                let generation = entry.panel.activeGeneration
                entry.panel.hide()
                invalid.append((entry.id, generation))
                continue
            }

            entry.panel.relayout(bottomOffset: offset)
            let nextOffset = offset + requiredHeight + ToastLayout.stackSpacing
            if let stackIndex {
                stacks[stackIndex].nextOffset = nextOffset
            } else {
                stacks.append((visibleFrame, nextOffset))
            }
        }

        for item in invalid {
            guard let index = entries.firstIndex(where: { $0.id == item.id }) else {
                continue
            }
            removeEntry(
                at: index,
                hidePanel: false,
                dismissalGeneration: item.dismissalGeneration
            )
        }
    }
}
