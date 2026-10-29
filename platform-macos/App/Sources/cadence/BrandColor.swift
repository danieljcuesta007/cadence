// BrandColor — the accent inks, defined once so the dashboard (and anything else that
// needs them) stays in lockstep with the app icon: riso pink for marks and fills, cobalt
// for emphasis (brand v1, docs/brand/README.md). Dynamic so they adapt to light/dark.

import AppKit

enum BrandColor {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    /// Primary accent — bars, fills, the hero number's mark, active states. The icon's pink peak.
    static let accent = dynamic(
        light: NSColor(srgbRed: 0.933, green: 0.561, blue: 0.698, alpha: 1),  // #EE8FB2
        dark: NSColor(srgbRed: 0.949, green: 0.635, blue: 0.749, alpha: 1))   // #F2A2BF

    /// Cobalt — emphasis text and secondary accents (readable where pink is too light for text).
    static let accentStrong = dynamic(
        light: NSColor(srgbRed: 0.141, green: 0.263, blue: 0.769, alpha: 1),  // #2443C4
        dark: NSColor(srgbRed: 0.561, green: 0.635, blue: 1.000, alpha: 1))   // #8FA2FF

    /// Softer pink — past-day bars, the calmer half of any two-tone.
    static let accentSoft = dynamic(
        light: NSColor(srgbRed: 0.973, green: 0.835, blue: 0.882, alpha: 1),  // #F8D5E1
        dark: NSColor(srgbRed: 0.431, green: 0.290, blue: 0.400, alpha: 1))   // #6E4A66

    /// Wash — the hero card's tinted background.
    static let accentWash = dynamic(
        light: NSColor(srgbRed: 0.992, green: 0.953, blue: 0.969, alpha: 1),  // #FDF3F7
        dark: NSColor(srgbRed: 0.165, green: 0.118, blue: 0.200, alpha: 1))   // #2A1E33
}
