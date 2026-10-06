// Appearance — the System / Light / Dark switch. "System" (the default) follows macOS; a pick
// pins the whole app (dashboard, dictionary, menus) via NSApp.appearance. The overlay pill keeps
// its HUD material either way. The choice is stored in the encrypted settings table by the
// composition root; with no store it still applies, just for this session.

import AppKit

enum Appearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SF Symbol for the dashboard toggle — shows the current choice.
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The order the dashboard toggle steps through.
    var next: Appearance {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    private(set) static var current: Appearance = .system
    /// Set by the composition root to save a new choice. Nil = session-only.
    static var persist: ((Appearance) -> Void)?

    /// Apply without saving (launch-time restore).
    static func apply(_ choice: Appearance) {
        current = choice
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// A user's pick: apply it and save it.
    static func choose(_ choice: Appearance) {
        apply(choice)
        persist?(choice)
    }
}

/// A content view that reports appearance flips (system switch or our own), so views that bake
/// colours into CALayers — which never re-resolve on their own — can rebuild.
final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
