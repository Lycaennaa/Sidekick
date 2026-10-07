import AppKit

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark
    case amoledBlack

    var title: String {
        switch self {
        case .system: "Match macOS"
        case .light: "Light"
        case .dark: "Dark"
        case .amoledBlack: "AMOLED Black"
        }
    }

    var detail: String {
        switch self {
        case .system: "Uses Sidekick Light in macOS Light and Sidekick Dark in macOS Dark."
        case .light: "Bright surfaces and dark text."
        case .dark: "Deep charcoal. Stays dark regardless of macOS appearance."
        case .amoledBlack: "True-black surfaces with crisp contrast."
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark, .amoledBlack: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
enum AppTheme {
    private(set) static var appearance: AppAppearance = .system

    static func apply(_ appearance: AppAppearance) {
        self.appearance = appearance
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    static var resolvedAppearance: AppAppearance {
        resolve(appearance, effectiveAppearance: NSApplication.shared.effectiveAppearance)
    }

    static func resolve(_ appearance: AppAppearance, effectiveAppearance: NSAppearance) -> AppAppearance {
        guard appearance == .system else { return appearance }
        return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    static var surface: NSColor {
        switch resolvedAppearance {
        case .system, .light: .windowBackgroundColor
        case .dark: NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
        case .amoledBlack: .black
        }
    }

    static var border: NSColor {
        switch resolvedAppearance {
        case .system, .light: .separatorColor
        case .dark: NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 48 / 255, alpha: 1)
        case .amoledBlack: NSColor(srgbRed: 38 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1)
        }
    }

    static var sidebarSurface: NSColor {
        switch resolvedAppearance {
        case .system, .light: .controlBackgroundColor
        case .dark: NSColor(srgbRed: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
        case .amoledBlack: .black
        }
    }

    static var primaryText: NSColor { .labelColor }
    static var secondaryText: NSColor { .secondaryLabelColor }
}
