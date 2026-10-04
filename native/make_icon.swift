// Renders the 1024×1024 app icon: a brass sound wave becoming centered lines of text.
// Usage: swift make_icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// Flip to top-left origin for easier reasoning.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824×824 body centered, soft shadow.
let body = CGRect(x: 100, y: 92, width: 824, height: 824)
let radius: CGFloat = 186
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0, 0, 0, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(13, 18, 32))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [rgb(27, 36, 60), rgb(11, 15, 28)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 92), end: CGPoint(x: 512, y: 916), options: [])
// warm glow at the top
let glow = CGGradient(colorsSpace: cs, colors: [rgb(201, 169, 107, 0.16), rgb(201, 169, 107, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 120), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 120), endRadius: 560, options: [])
ctx.restoreGState()

// hairline rim
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius - 1.5,
                   cornerHeight: radius - 1.5, transform: nil))
ctx.setStrokeColor(rgb(235, 230, 219, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

// sound wave
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let wave = CGMutablePath()
let x0: CGFloat = 268, x1: CGFloat = 756, cy: CGFloat = 400
wave.move(to: CGPoint(x: x0, y: cy))
let steps = 240
for i in 1...steps {
    let t = CGFloat(i) / CGFloat(steps)
    let x = x0 + (x1 - x0) * t
    let env = sin(.pi * t)                       // fade in/out at the ends
    let y = cy - env * (62 * sin(t * .pi * 5.0) + 18 * sin(t * .pi * 13.0))
    wave.addLine(to: CGPoint(x: x, y: y))
}
ctx.addPath(wave)
ctx.setStrokeColor(rgb(201, 169, 107))
ctx.setLineWidth(17)
ctx.strokePath()

// centered text lines
let lines: [(CGFloat, CGFloat, CGFloat)] = [(578, 420, 0.70), (654, 340, 0.46), (730, 228, 0.28)]
for (y, w, a) in lines {
    ctx.move(to: CGPoint(x: 512 - w / 2, y: y))
    ctx.addLine(to: CGPoint(x: 512 + w / 2, y: y))
    ctx.setStrokeColor(rgb(235, 230, 219, a))
    ctx.setLineWidth(17)
    ctx.strokePath()
}

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote", out)
