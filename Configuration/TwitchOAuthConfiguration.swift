import Foundation

enum TwitchOAuthConfiguration {
    static var effectiveClientID: String {
        resolvedClientID(userOverride: nil)
    }

    static func resolvedClientID(userOverride: String?) -> String {
        resolveClientID(
            userOverride: userOverride,
            appClientID: Bundle.main.object(forInfoDictionaryKey: "TwitchOAuthClientID") as? String
        )
    }

    static func resolveClientID(
        userOverride: String? = nil,
        appClientID: String?
    ) -> String {
        for candidate in [userOverride, appClientID] {
            let normalized = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, isConfigured(normalized) {
                return normalized
            }
        }
        return "none"
    }

    static func isConfigured(_ clientID: String) -> Bool {
        let candidate = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !candidate.isEmpty && candidate.caseInsensitiveCompare("none") != .orderedSame
    }
}