// Renders the Cadence app icon master (1024×1024 PNG) — run: swift render-icon.swift out.png
//
// Design: warm ivory squircle (Apple continuous corner curve via CALayer cornerCurve),
// five-bar cadence waveform in warm ink, peak bar in antique gold. No emoji, no gloss —
// clean at 16 px, distinctive at Dock size. Regenerate AppIcon.icns via make-icns.sh.

import AppKit
import QuartzCore

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let canvas: CGFloat = 1024
let plate: CGFloat = 824 // standard macOS icon grid: 100 px margin each side
let corner: CGFloat = plate * 0.2237

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let root = CALayer()
root.frame = CGRect(x: 0, y: 0, width: canvas, height: canvas)
root.isGeometryFlipped = false

// Soft ambient shadow so the plate sits on the Dock like a first-party icon.
let shadowHost = CALayer()
shadowHost.frame = root.bounds
shadowHost.shadowColor = CGColor(gray: 0, alpha: 1)
shadowHost.shadowOpacity = 0.30
shadowHost.shadowRadius = 22
shadowHost.shadowOffset = CGSize(width: 0, height: -12)
root.addSublayer(shadowHost)

let plateLayer = CAGradientLayer()
plateLayer.frame = CGRect(x: (canvas - plate) / 2, y: (canvas - plate) / 2, width: plate, height: plate)
plateLayer.colors = [color(0xFBF7EE), color(0xEFE6D4)] // ivory, warm
plateLayer.startPoint = CGPoint(x: 0.5, y: 1) // layer y=1 is top pre-flip; render() flips
plateLayer.endPoint = CGPoint(x: 0.5, y: 0)
plateLayer.cornerRadius = corner
plateLayer.cornerCurve = .continuous
plateLayer.masksToBounds = true
shadowHost.addSublayer(plateLayer)

// Hairline inner keyline: separates the ivory plate from light backgrounds.
let keyline = CALayer()
keyline.frame = plateLayer.bounds
keyline.cornerRadius = corner
keyline.cornerCurve = .continuous
keyline.borderWidth = 4
keyline.borderColor = CGColor(gray: 0.20, alpha: 0.10)
plateLayer.addSublayer(keyline)

// The cadence mark: five bars, heights shaped like a spoken phrase.
let heights: [CGFloat] = [0.34, 0.72, 1.00, 0.55, 0.80]
let barW: CGFloat = 76, gap: CGFloat = 46, maxH: CGFloat = 400
let markW = barW * 5 + gap * 4
let x0 = (plate - markW) / 2
let ink = color(0x201C14) // warm near-black

for (i, h) in heights.enumerated() {
    let barH = maxH * h
    let bar = CAGradientLayer()
    bar.frame = CGRect(
        x: x0 + CGFloat(i) * (barW + gap),
        y: (plate - barH) / 2, width: barW, height: barH)
    bar.cornerRadius = barW / 2
    bar.cornerCurve = .continuous
    if h == 1.0 {
        bar.colors = [color(0xCBA94E), color(0xA9862F)] // antique gold, lit from top
        bar.startPoint = CGPoint(x: 0.5, y: 1)
        bar.endPoint = CGPoint(x: 0.5, y: 0)
    } else {
        bar.colors = [ink, ink]
    }
    plateLayer.addSublayer(bar)
}

guard
    let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("bitmap context") }
root.render(in: ctx)
guard let img = ctx.makeImage() else { fatalError("makeImage") }

let url = URL(fileURLWithPath: out) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)
else { fatalError("destination") }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
