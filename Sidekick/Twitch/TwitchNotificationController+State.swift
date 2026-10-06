import Foundation

extension TwitchNotificationController {
    func setStatus(_ newStatus: Status, preservingTokenSaveError: Bool = false) {
        let statusCanPreserveTokenError: Bool
        switch newStatus {
        case .polling(.requestingPermission), .polling(.checking):
            statusCanPreserveTokenError = true
        default:
            statusCanPreserveTokenError = false
        }
        if !preservingTokenSaveError,
           !statusCanPreserveTokenError {
            tokenOwner.clearError()
        }
        guard status != newStatus else { return }
        status = newStatus
        onStateChange?()
    }
}
