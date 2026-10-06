// Renders the 1024×1024 app icon.  swift app/make_icon.swift <path-without-.png> [--flat] [--palette NAME]
// --flat: full-bleed opaque square for iPhone/iPad (iOS draws the rounded mask itself).
// --palette: navy (default), ivory, brass, charcoal, sage — the icon choices in 설정.
import AppKit
import CoreText

let flat = CommandLine.arguments.contains("--flat")
let corner: CGFloat = flat ? 0 : 186

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let ivory = rgb(236, 230, 218), brass = rgb(201, 169, 107)

struct Palette { let top, bottom, figure, lines, caret, glow: CGColor }
let palettes: [String: Palette] = [
    "navy": Palette(top: rgb(30, 39, 64), bottom: rgb(10, 14, 26), figure: ivory, lines: rgb(20, 27, 46, 0.78), caret: brass, glow: rgb(201, 169, 107, 0.13)),
    "ivory": Palette(top: rgb(248, 245, 238), bottom: rgb(224, 216, 200), figure: rgb(24, 32, 56), lines: rgb(236, 230, 218, 0.85), caret: brass, glow: rgb(255, 255, 255, 0.5)),
    "brass": Palette(top: rgb(216, 186, 126), bottom: rgb(160, 126, 66), figure: rgb(22, 28, 46), lines: rgb(228, 204, 156, 0.9), caret: rgb(246, 242, 233), glow: rgb(255, 240, 210, 0.3)),
    "charcoal": Palette(top: rgb(48, 48, 52), bottom: rgb(14, 14, 16), figure: ivory, lines: rgb(26, 26, 30, 0.8), caret: brass, glow: rgb(201, 169, 107, 0.1)),
    "sage": Palette(top: rgb(70, 94, 80), bottom: rgb(26, 38, 32), figure: ivory, lines: rgb(26, 38, 32, 0.8), caret: brass, glow: rgb(220, 230, 200, 0.12)),
]
let paletteName: String = { let a = CommandLine.arguments; if let i = a.firstIndex(of: "--palette"), i + 1 < a.count { return a[i + 1] }; return "navy" }()
let pal = palettes[paletteName] ?? palettes["navy"]!

func base(_ ctx: CGContext) {                       // macOS icon body on a 1024 canvas (top-left origin)
    let body = CGRect(x: 100, y: 92, width: 824, height: 824), r = corner
    let shape = CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.saveGState(); if !flat { ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0, 0, 0, 0.35)) }
    ctx.addPath(shape); ctx.setFillColor(pal.bottom); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [pal.top, pal.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 92), end: CGPoint(x: 512, y: 916), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [pal.glow, pal.glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 110), startRadius: 0, endCenter: CGPoint(x: 512, y: 110), endRadius: 600, options: [])
    ctx.restoreGState()
    guard !flat else { return }
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: r - 1.5, cornerHeight: r - 1.5, transform: nil))
    ctx.setStrokeColor(rgb(236, 230, 218, 0.08)); ctx.setLineWidth(3); ctx.strokePath()
}

func glyph(_ ctx: CGContext, _ s: String, font: String, size: CGFloat, color: CGColor, center: CGPoint) -> CGRect {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: center.x - b.midX, y: center.y + b.midY); ctx.scaleBy(x: 1, y: -1)
    CTLineDraw(line, ctx); ctx.restoreGState()
    return CGRect(x: center.x - b.width / 2, y: center.y - b.height / 2, width: b.width, height: b.height)
}

func caret(_ ctx: CGContext, x: CGFloat, midY: CGFloat, w: CGFloat, h: CGFloat) {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 28, color: rgb(201, 169, 107, 0.55))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: midY - h / 2, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
    ctx.setFillColor(pal.caret); ctx.fillPath(); ctx.restoreGState()
}

func render(_ name: String, _ draw: (CGContext) -> Void) -> CGImage {  // writes <name>.png
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: (flat ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!   // iOS: no alpha
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    if flat { ctx.scaleBy(x: 1024 / 824, y: 1024 / 824); ctx.translateBy(x: -100, y: -92) }   // the icon body fills the square
    base(ctx); draw(ctx)
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(name).png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    return img
}


func person(_ ctx: CGContext, color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: 262, y: 492, width: 168, height: 168))            // head
    let sh = CGMutablePath()                                                          // shoulders
    sh.move(to: CGPoint(x: 196, y: 916)); sh.addLine(to: CGPoint(x: 196, y: 812))
    sh.addCurve(to: CGPoint(x: 346, y: 690), control1: CGPoint(x: 196, y: 740), control2: CGPoint(x: 262, y: 690))
    sh.addCurve(to: CGPoint(x: 496, y: 812), control1: CGPoint(x: 430, y: 690), control2: CGPoint(x: 496, y: 740))
    sh.addLine(to: CGPoint(x: 496, y: 916)); sh.closeSubpath()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 92, width: 824, height: 824), cornerWidth: corner, cornerHeight: corner, transform: nil)); ctx.clip()
    ctx.addPath(sh); ctx.fillPath(); ctx.restoreGState()
}
func bubblePath() -> CGPath {                                                         // bubble with tail toward the speaker
    let (x0, y0, x1, y1, r): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (420, 196, 830, 478, 72)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0 + r, y: y0))
    p.addLine(to: CGPoint(x: x1 - r, y: y0)); p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
    p.addLine(to: CGPoint(x: x1, y: y1 - r)); p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r)
    p.addLine(to: CGPoint(x: 560, y: y1))
    p.addLine(to: CGPoint(x: 452, y: 572))                                              // tail tip, toward the head
    p.addLine(to: CGPoint(x: 486, y: y1))
    p.addLine(to: CGPoint(x: x0 + r, y: y1)); p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
    p.addLine(to: CGPoint(x: x0, y: y0 + r)); p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
    p.closeSubpath()
    return p
}
func textLines(_ ctx: CGContext, color: CGColor) {                                   // the transcription, mid-typing
    for (y, w) in [(282.0, 270.0), (366.0, 168.0)] as [(CGFloat, CGFloat)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 488, y: y - 17, width: w, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setFillColor(color); ctx.fillPath()
    }
    caret(ctx, x: 676, midY: 366, w: 22, h: 76)
}

// 강의 받아쓰기 v2 icon: a lecturer whose speech bubble is being transcribed (bubble = live text + brass cursor).
let out: String = {                                          // the first argument that isn't an option or its value
    let a = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < a.count { if a[i] == "--palette" { i += 2; continue }; if !a[i].hasPrefix("--") { return a[i] }; i += 1 }
    return "icon_1024"
}()
_ = render(out) { ctx in
    person(ctx, color: pal.figure)
    ctx.addPath(bubblePath()); ctx.setFillColor(pal.figure); ctx.fillPath()
    textLines(ctx, color: pal.lines)
}
print("wrote \(out).png")
