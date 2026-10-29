// Render browser icons from the canonical SVG geometry, without grain at tiny sizes.
// Run from the repository root: swift qa/render-web-icons.swift
import AppKit
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let site = root.appendingPathComponent("site")
let mark = try String(contentsOf: site.appendingPathComponent("art/mark.svg"), encoding: .utf8)
func matches(_ pattern: String, _ text: String) -> [[String]] {
    let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
        (0..<m.numberOfRanges).map { String(text[Range(m.range(at: $0), in: text)!]) }
    }
}
let box = matches("viewBox=\"([^\"]+)\"", mark)[0][1].split(separator: " ").map { Double($0)! }
let paths = matches("<path stroke=\"(#[0-9A-Fa-f]{6})\" d=\"([^\"]+)\"", mark)
precondition(paths.count == 2, "Expected the canonical two-ink mark")
let weight = Double(matches("stroke-width=\"([0-9.]+)\"", mark)[0][1])!
func png(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: Double(size) / box[2], y: Double(size) / box[3])
    ctx.translateBy(x: -box[0], y: -box[1])
    ctx.setLineWidth(weight); ctx.setLineCap(.round)
    for path in paths {
        let hex = UInt32(path[1].dropFirst(), radix: 16)!
        ctx.setStrokeColor(CGColor(srgbRed: Double((hex >> 16) & 255) / 255,
                                   green: Double((hex >> 8) & 255) / 255,
                                   blue: Double(hex & 255) / 255, alpha: 1))
        for segment in matches("M([0-9.]+) ([0-9.]+) V([0-9.]+)", path[2]) {
            ctx.move(to: CGPoint(x: Double(segment[1])!, y: Double(segment[2])!))
            ctx.addLine(to: CGPoint(x: Double(segment[1])!, y: Double(segment[3])!))
        }
        ctx.strokePath()
    }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest))
    return data as Data
}
let svg = mark.replacingOccurrences(of: "<defs>[\\s\\S]*?</defs>", with: "", options: .regularExpression)
    .replacingOccurrences(of: " filter=\"url(#grain)\"", with: "")
try svg.write(to: site.appendingPathComponent("favicon-riso-v2.svg"), atomically: true, encoding: .utf8)
let fallback = png(64)
for name in ["favicon.png", "favicon-riso-v2.png"] { try fallback.write(to: site.appendingPathComponent(name)) }
// ICO has native 16/32/64 pixel variants for clients that still request /favicon.ico.
var ico = Data()
func word(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { ico.append(contentsOf: $0) } }
func dword(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { ico.append(contentsOf: $0) } }
let sizes = [16, 32, 64], images = [png(16), png(32), fallback]
word(0); word(1); word(3)
var offset = 6 + sizes.count * 16
for (size, data) in zip(sizes, images) {
    ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0]); word(1); word(32)
    dword(UInt32(data.count)); dword(UInt32(offset)); offset += data.count
}
for image in images { ico.append(image) }
try ico.write(to: site.appendingPathComponent("favicon.ico"))
for (source, target) in [("apple-touch-icon.png", "apple-touch-icon-riso-v2.png"),
                          ("icon-512.png", "icon-512-riso-v2.png")] {
    try Data(contentsOf: site.appendingPathComponent(source)).write(to: site.appendingPathComponent(target))
}
print("Rendered SVG, transparent PNG and multi-size ICO; versioned touch/share icons.")
