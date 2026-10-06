// ListeningOrb — the pill's "listening" indicator: a small "Siri orb" (layered conic
// gradients turning at different speeds, blurred together) in the Cadence greens. It
// replaces the old "●" dot and swells with the mic level, so it doubles as a second
// "mic is hearing you" signal next to the bars.
//
// Ported from the Vitals widget's Orb (ai-search-tracker/vitals-widget/Vitals.swift) and
// scaled down for a ~22 pt circle: blur and highlight radii are fractions of the size, so
// the gradients stay legible instead of melting into one flat green.
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
let cadenceOrb = OrbPalette(base: hex(0x123A1E), c1: hex(0x3F8A4F), c2: hex(0xD2F5D6),
                            c3: hex(0x1F6B33))

struct ListeningOrb: View {
    @ObservedObject var model: OrbModel
    var p: OrbPalette = cadenceOrb
    var size: CGFloat = 22
    var period: Double = 6  // faster than Vitals' 24 s: this one should feel alive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: model.paused)) { ctx in
            let a = ctx.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period * 360
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
            .drawingGroup()
        }
        .frame(width: size, height: size)
        // Breathes with the voice: a quiet room sits at 82%, a loud word fills the circle.
        .scaleEffect(0.82 + 0.18 * model.level)
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
