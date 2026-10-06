import AppKit

@MainActor
enum AppTheme {
    static let surface = NSColor.black
    static let border = NSColor(srgbRed: 38 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1)
    static let primaryText = NSColor.white
    static let secondaryText = NSColor(srgbRed: 160 / 255, green: 160 / 255, blue: 160 / 255, alpha: 1)
}
