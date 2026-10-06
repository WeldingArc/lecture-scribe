// Renders an animation page offscreen, frame by frame, with WebKit (for README GIFs).
// usage: frames <file-url> <out-dir> <width> <height> <seconds> <fps> <js-function>
// e.g.   frames "file://$PWD/ui/index.html?shot=slidesdemo" /tmp/f 720 660 22 10 __renderDemo
import AppKit
import WebKit
let a = CommandLine.arguments
let url = URL(string: a[1])!, out = a[2], w = Double(a[3])!, h = Double(a[4])!, secs = Double(a[5])!, fps = Double(a[6])!, fn = a[7]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    win.contentView = web
    win.orderFrontRegardless()
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    let total = Int(secs * fps)
    @MainActor func frame(_ i: Int) {
        guard i < total else { print("wrote \(total) frames"); exit(0) }
        web.evaluateJavaScript("window.\(fn)(\(Double(i) / fps))") { _, _ in
            web.takeSnapshot(with: WKSnapshotConfiguration()) { img, _ in
                if let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: String(format: "%@/%04d.png", out, i)))
                }
                frame(i + 1)
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { frame(0) }
    app.run()
}
