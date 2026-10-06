// Renders a page offscreen with WebKit (the engine the apps use) and saves a PNG.
// usage: shot <file-url> <out.png> <width> <height> [seconds]
import AppKit
import WebKit
let a = CommandLine.arguments
let url = URL(string: a[1])!, out = a[2], w = Double(a[3])!, h = Double(a[4])!, wait = a.count > 5 ? Double(a[5])! : 3
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    win.contentView = web
    win.orderFrontRegardless()
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        web.takeSnapshot(with: WKSnapshotConfiguration()) { img, err in
            guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("snapshot failed: \(String(describing: err))"); exit(1) }
            let rep = NSBitmapImageRep(cgImage: cg)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) \(cg.width)x\(cg.height)")
            exit(0)
        }
    }
    app.run()
}
