// ListeningOrb — the pill's "listening" indicator: a small "Siri orb" (layered conic
// gradients turning at different speeds, blurred together) in greys that follow the
// text colour, as the old dot did: graphite on a light pill, silver on a dark one. It
// replaces the old "●" dot and swells with the mic level, so it doubles as a second
// "mic is hearing you" signal next to the bars.
//
// Same footprint as the "●" it replaced (~10.5 pt), so the pill looks as it always has; the
// life is in the motion: a slow breath while you pause, a swell on every word. Ported from
// the Vitals widget's Orb (ai-search-tracker/vitals-widget/Vitals.swift); blur and highlight
// radii are fractions of the size so the gradients stay legible at this scale.
//
// CPU contract: the TimelineView is paused whenever the pill isn't listening (and after it
// fades), so the orb costs nothing between dictations. 12 fps is enough for a slow drift.

import AppKit
import SwiftUI

final class OrbModel: ObservableObject {
    @Published var paused = true
    /// Smoothed mic level, 0...1. Published only when it moves visibly (see OverlayHUD).
    @Published var level: CGFloat = 0
}

struct OrbPalette {
    var base, c1, c2, c3: Color
}

private func hex(_ v: UInt32) -> Color {
    Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
          blue: Double(v & 0xFF) / 255)
}

/// Cadence greens: the brand #3F8A4F, a darker forest for depth, a pale mint that shows as
/// the moving light, and a deep pine base so the orb reads on light and dark HUD material.
/// Spread wide on purpose: at 22 pt the blur averages close shades into one flat green.
/// Kept for a quick switch back: Daniel tried it green first (6 Oct) and preferred grey.
let cadenceOrb = OrbPalette(base: hex(0x123A1E), c1: hex(0x3F8A4F), c2: hex(0xD2F5D6),
                            c3: hex(0x1F6B33))

/// The greys: same roles as the greens (dark base, mid tone, a light that moves, a shade for
/// depth), so the orb has the old dot's weight in either appearance.
let graphiteOrb = OrbPalette(base: hex(0x232326), c1: hex(0x55555B), c2: hex(0xC9C9CF),
                             c3: hex(0x3A3A3F))
let silverOrb = OrbPalette(base: hex(0xBDBDC3), c1: hex(0x8A8A91), c2: hex(0xFFFFFF),
                           c3: hex(0xA2A2A9))

struct ListeningOrb: View {
    @ObservedObject var model: OrbModel
    @Environment(\.colorScheme) private var scheme
    var size: CGFloat = 10.5  // the old dot's diameter at 13 pt medium
    var period: Double = 14  // a calm turn; the breath and the swell carry the liveliness

    private var p: OrbPalette { scheme == .dark ? silverOrb : graphiteOrb }

    /// The hosting frame leaves room for the swell, so it never clips.
    static let frameSize: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: model.paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let a = t.truncatingRemainder(dividingBy: period) / period * 360
            // a slow breath (2.4 s), so it is alive even between words
            let breath = 1 + 0.05 * sin(t * 2 * .pi / 2.4)
            ZStack {
                p.base
                ZStack {
                    cone(p.c3, UnitPoint(x: 0.30, y: 0.65), a * 1.2, 45)
                    cone(p.c2, UnitPoint(x: 0.70, y: 0.35), a * 0.8, 60)
                    cone(p.c1, UnitPoint(x: 0.65, y: 0.75), -a * 1.5, 90)
                    cone(p.c2, UnitPoint(x: 0.25, y: 0.25), a * 2.1, 30)
                    cone(p.c1, UnitPoint(x: 0.80, y: 0.80), -a * 0.7, 45)
                    EllipticalGradient(colors: [p.c3, .clear], center: UnitPoint(x: 0.4, y: 0.6),
                                       startRadiusFraction: 0, endRadiusFraction: 0.5)
                }
                .scaleEffect(1.25)  // so the blur never thins out at the edge
                .blur(radius: size * 0.08)
                .saturation(1.2)
                .contrast(1.1)
                // the orb's soft highlight
                RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.42, y: 0.38), startRadius: 0,
                               endRadius: size * 0.6)
                    .blendMode(.overlay)
            }
            .clipShape(Circle())
            // a hairline glass rim, like a bead under the HUD material
            .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            .drawingGroup()
            .frame(width: size, height: size)
            .scaleEffect(breath)
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
        // Swells with the voice: silence is the old dot's size, a loud word about 125%.
        .scaleEffect(1 + 0.25 * model.level)
        .brightness(0.10 * model.level)
        .animation(.easeOut(duration: 0.12), value: model.level)
    }

    private func cone(_ c: Color, _ at: UnitPoint, _ deg: Double, _ spread: Double) -> some View {
        AngularGradient(stops: [.init(color: c, location: 0),
                                .init(color: .clear, location: spread / 360),
                                .init(color: .clear, location: 1 - spread / 360),
                                .init(color: c, location: 1)],
                        center: at, angle: .degrees(deg))
    }
}
