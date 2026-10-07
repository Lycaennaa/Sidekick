import AppKit

@MainActor
func configureSettingsPageStack(_ stack: NSStackView) {
    stack.alignment = .leading
    stack.distribution = .fill
    for arrangedSubview in stack.arrangedSubviews {
        arrangedSubview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}
