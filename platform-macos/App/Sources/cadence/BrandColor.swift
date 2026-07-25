// BrandColor — the one accent hue, defined once so the dashboard (and anything else that
// needs it) stays in lockstep with the app icon's rich-green peak bar. Dynamic so it adapts
// to light/dark: a deeper green on light grounds, a brighter one on dark.

import AppKit

enum BrandColor {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    /// Primary accent — bars, fills, the hero number's mark, active states.
    static let green = dynamic(
        light: NSColor(srgbRed: 0.247, green: 0.541, blue: 0.310, alpha: 1),  // #3F8A4F
        dark: NSColor(srgbRed: 0.361, green: 0.710, blue: 0.404, alpha: 1))   // #5CB567

    /// Deeper green — emphasis text on light grounds, secondary accents.
    static let greenStrong = dynamic(
        light: NSColor(srgbRed: 0.173, green: 0.416, blue: 0.227, alpha: 1),  // #2C6A3A
        dark: NSColor(srgbRed: 0.510, green: 0.808, blue: 0.522, alpha: 1))   // #82CE85

    /// Lighter green — past-day bars, the calmer half of any two-tone.
    static let greenSoft = dynamic(
        light: NSColor(srgbRed: 0.482, green: 0.741, blue: 0.494, alpha: 1),  // #7BBD7E
        dark: NSColor(srgbRed: 0.247, green: 0.541, blue: 0.310, alpha: 1))   // #3F8A4F

    /// Wash — the hero card's tinted background.
    static let greenWash = dynamic(
        light: NSColor(srgbRed: 0.902, green: 0.949, blue: 0.902, alpha: 1),  // #E6F2E6
        dark: NSColor(srgbRed: 0.110, green: 0.169, blue: 0.114, alpha: 1))   // #1C2B1D
}
