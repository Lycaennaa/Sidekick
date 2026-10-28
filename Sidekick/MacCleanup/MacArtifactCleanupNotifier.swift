import Foundation
import UserNotifications

@MainActor
final class MacArtifactCleanupNotifier {
    private let center: UNUserNotificationCenter?
    private let usesDefaultCenter: Bool
    private var tasks: [UUID: Task<String?, Never>] = [:]

    init() {
        center = nil
        usesDefaultCenter = true
    }

    init(center: UNUserNotificationCenter?) {
        self.center = center
        usesDefaultCenter = false
    }

    @discardableResult
    func send(
        title: String,
        body: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> Task<String?, Never>? {
        let notificationCenter: UNUserNotificationCenter?
        if usesDefaultCenter {
            notificationCenter = UNUserNotificationCenter.current()
        } else {
            notificationCenter = center
        }
        guard let center = notificationCenter else { return nil }

        let id = UUID()
        let task = Task<String?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.finishTask(id) }
            guard !Task.isCancelled, isCurrent() else { return nil }

            let status = await center.notificationSettings().authorizationStatus
            guard self.tasks[id] != nil, !Task.isCancelled, isCurrent() else { return nil }

            let allowed: Bool
            switch status {
            case .authorized, .provisional, .ephemeral:
                allowed = true
            case .notDetermined:
                allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                guard self.tasks[id] != nil, !Task.isCancelled, isCurrent() else { return nil }
            case .denied:
                allowed = false
            @unknown default:
                allowed = false
            }
            guard allowed else { return nil }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "mac-artifact-cleanup-\(id.uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                return nil
            }
            guard self.tasks[id] != nil, !Task.isCancelled, isCurrent() else { return nil }
            return request.identifier
        }
        tasks[id] = task
        return task
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func finishTask(_ id: UUID) {
        guard tasks[id] != nil else { return }
        tasks.removeValue(forKey: id)
    }
}
