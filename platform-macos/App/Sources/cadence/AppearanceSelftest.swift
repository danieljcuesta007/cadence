// AppearanceSelftest — headless check of the light/dark switch (`cadence selftest-appearance`).
//
// The dashboard bakes colours into CALayers, which never re-resolve on their own, so the risk
// with a live switch is a window that flips its chrome but keeps last mode's cards. This builds
// the dashboard offscreen (never shown, never activated, no store — history falls back to an
// empty read), flips the app appearance under it, and compares that against a dashboard built
// fresh in the target mode. Pass `--out <dir>` to keep the renders as PNGs for a look.
//
// Same shape as the other selftests: named checks, JSON out, non-zero exit on failure.

import AppKit

private struct AppearanceCheck: Codable {
    var name: String
    var pass: Bool
    var detail: String?
}

/// Render a window's content offscreen to an sRGB bitmap.
private func render(_ controller: DashboardWindowController) -> NSBitmapImageRep? {
    guard let view = controller.window?.contentView else { return nil }
    // Let layout and the layer tree settle (a never-shown window only commits on a run-loop pass).
    view.layoutSubtreeIfNeeded()
    CATransaction.flush()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Mean luminance (0–1) over a sparse grid of the drawn pixels. The window background isn't
/// part of the content view's cache, so transparent pixels are skipped.
private func luminance(_ rep: NSBitmapImageRep) -> Double {
    var sum = 0.0, n = 0.0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5
            else { continue }
            sum += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            n += 1
        }
    }
    return n > 0 ? sum / n : 0
}

/// Fraction of sampled pixels that differ noticeably between two same-size renders.
private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
    var off = 0.0, n = 0.0
    for y in stride(from: 0, to: a.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: a.pixelsWide, by: 4) {
            guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            let d = abs(p.alphaComponent - q.alphaComponent) + abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                + abs(p.blueComponent - q.blueComponent)
            if d > 0.06 { off += 1 }
            n += 1
        }
    }
    return n > 0 ? off / n : 1
}

private func save(_ rep: NSBitmapImageRep, _ name: String, in dir: String?) {
    guard let dir, let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
}

func runAppearanceSelftest(outDir: String?) -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // no Dock tile, no focus steal
    var checks: [AppearanceCheck] = []
    func check(_ name: String, _ pass: Bool, _ detail: String? = nil) {
        checks.append(AppearanceCheck(name: name, pass: pass, detail: detail))
    }

    // Choice round-trip and cycle order.
    check("raw values round-trip",
        Appearance.allCases.allSatisfy { Appearance(rawValue: $0.rawValue) == $0 })
    check("unknown value is not a choice", Appearance(rawValue: "sepia") == nil)
    check("toggle cycles system → light → dark → system",
        Appearance.system.next == .light && Appearance.light.next == .dark
            && Appearance.dark.next == .system)

    // apply() drives NSApp.appearance; system clears the override.
    Appearance.apply(.dark)
    check("dark pins darkAqua",
        app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    Appearance.apply(.light)
    check("light pins aqua",
        app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    Appearance.apply(.system)
    check("system clears the override", app.appearance == nil)

    // Fresh renders in each mode.
    // Render each before the next flip: an open dashboard follows the app, so a light one
    // drawn after switching to dark would (correctly) come out dark.
    Appearance.apply(.light)
    let lightRep = render(DashboardWindowController())
    Appearance.apply(.dark)
    let darkRep = render(DashboardWindowController())
    guard let lightRep, let darkRep else {
        check("offscreen render", false, "no bitmap")
        return finish(checks)
    }
    save(lightRep, "dashboard-light.png", in: outDir)
    save(darkRep, "dashboard-dark.png", in: outDir)
    let lumL = luminance(lightRep), lumD = luminance(darkRep)
    check("light render is light", lumL > 0.6, String(format: "mean luminance %.2f", lumL))
    // Drawn pixels only, so white text lifts the dark mean; the gap is what matters.
    check("dark render is dark", lumD < 0.5 && lumL - lumD > 0.4, String(format: "mean luminance %.2f", lumD))

    // Live flips: an open dashboard must match a fresh one in the new mode (cards included).
    Appearance.apply(.light)
    let live = DashboardWindowController()
    _ = render(live)
    Appearance.apply(.dark)
    if let flipped = render(live) {
        save(flipped, "dashboard-flipped-dark.png", in: outDir)
        let d = difference(flipped, darkRep)
        check("light → dark flip repaints everything", d < 0.01,
            String(format: "%.2f%% of pixels differ from a fresh dark build", d * 100))
    }
    Appearance.apply(.light)
    if let back = render(live) {
        let d = difference(back, lightRep)
        check("dark → light flip repaints everything", d < 0.01,
            String(format: "%.2f%% of pixels differ from a fresh light build", d * 100))
    }
    Appearance.apply(.system)
    return finish(checks)
}

private func finish(_ checks: [AppearanceCheck]) -> Int32 {
    let failed = checks.filter { !$0.pass }.count
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(checks), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    print("selftest-appearance: \(checks.count - failed)/\(checks.count) passed")
    return failed == 0 ? 0 : 1
}
