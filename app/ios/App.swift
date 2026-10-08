// 강의 받아쓰기 for iPhone and iPad: the same interface (ui/index.html), engine and library as the
// Mac app, listening through the microphone instead of the Mac's system audio.

import AVFoundation
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
private let navy = UIColor(red: 13 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)

@main
struct LectureScribeApp: App {
    var body: some Scene {
        WindowGroup {
            WebHost()
                .ignoresSafeArea()
                .background(Color(navy))
        }
    }
}

/// The engine outlives any one window: iOS may tear the UI down and rebuild it while a lecture records.
@MainActor
enum Shared {
    static var sink: (([String: Any]) -> Void)?
    static let bridge = Bridge { ev in Shared.sink?(ev) }
}

struct WebHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebController { WebController() }
    func updateUIViewController(_ controller: WebController, context: Context) {}
}

/// The page's message handler, held weakly (WKUserContentController retains its handlers).
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

@MainActor
final class WebController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIDocumentPickerDelegate, Platform,
                           QLPreviewControllerDataSource {
    private var web: WKWebView!
    private var bridge: Bridge!
    private var pageReady = false
    private var queued: [String] = []
    private var saveTask: UIBackgroundTaskIdentifier = .invalid
    private var previewing: URL?
    private let uiDir = (Bundle.main.resourcePath ?? "") + "/ui"

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "native")
        cfg.userContentController.addUserScript(pageScript())
        web = WKWebView(frame: .zero, configuration: cfg)
        overrideUserInterfaceStyle = .dark
        web.isOpaque = false
        web.backgroundColor = navy
        web.scrollView.backgroundColor = navy
        web.scrollView.contentInsetAdjustmentBehavior = .never     // the page handles the safe areas
        web.scrollView.isScrollEnabled = false                     // its panes scroll themselves
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        #if DEBUG
        web.isInspectable = true
        #endif
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Shared.sink = { [weak self] ev in self?.toPage(ev) }
        bridge = Shared.bridge
        bridge.platform = self
        web.loadFileURL(URL(fileURLWithPath: uiDir + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: uiDir))
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.bridge.player.id != nil { self?.bridge.player.report() } }
        }
        log("app started \(appVersion) (\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))")
    }

    // MARK: engine → page

    private func toPage(_ ev: [String: Any]) {
        let name = ev["ev"] as? String
        if name == "rec" { keepAliveWhileSaving(ev["state"] as? String) }
        if UIApplication.shared.applicationState == .background, ["level", "player", "progress"].contains(name ?? "") { return }
        guard JSONSerialization.isValidJSONObject(ev),                       // NaN/inf would raise, not throw
              let data = try? JSONSerialization.data(withJSONObject: ev), let json = String(data: data, encoding: .utf8) else {
            log("dropped an event the page can't read: \(name ?? "?")"); return
        }
        guard pageReady else {
            if name != "level" { queued.append(json) }
            return
        }
        web.evaluateJavaScript("window.app && window.app.receive(\(json))", completionHandler: nil)
    }

    /// After 정지 the recording is compressed; leaving the app right then must not cut that short.
    private func keepAliveWhileSaving(_ state: String?) {
        if state == "finishing", saveTask == .invalid {
            saveTask = UIApplication.shared.beginBackgroundTask(withName: "강의 저장") { [weak self] in
                MainActor.assumeIsolated { self?.keepAliveWhileSaving("idle") }
            }
        } else if state == "idle", saveTask != .invalid {
            UIApplication.shared.endBackgroundTask(saveTask)
            saveTask = .invalid
        }
    }

    // MARK: page → app

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        if cmd == "ready" {
            pageReady = true
            let pending = queued
            queued.removeAll()
            pending.forEach { web.evaluateJavaScript("window.app && window.app.receive(\($0))", completionHandler: nil) }
        }
        bridge.handle(cmd, body)
    }

    /// What the page knows before it runs a line, the app's language included (it is drawn in it).
    private func pageScript() -> WKUserScript {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? L("아이패드", "iPad") : L("아이폰", "iPhone")
        return WKUserScript(source: "window.__NATIVE__ = true; window.__PLATFORM__ = \"ios\"; window.__LIBRARY__ = true; window.__DEVICE__ = \"\(device)\"; window.__LANG__ = \"\(appLanguage.value)\";",
                            injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// 설정 › 언어: the page again in the new language; the engine replays its state.
    func languageChanged() {
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.addUserScript(pageScript())
        pageReady = false
        queued.removeAll()
        web.reload()
    }

    /// iOS may reclaim the page while the app records in the background: load it again and replay the state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("page was reclaimed by iOS; reloading")
        pageReady = false
        queued.removeAll()
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL && url.path.hasPrefix(uiDir) { return decisionHandler(.allow) }
        if url.scheme == "https" { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }

    // MARK: Platform (what differs from the Mac app)

    func copyText(_ text: String) { UIPasteboard.general.string = text }

    /// The Files app, at this app's folder ("나의 iPhone › 강의 받아쓰기").
    func openFolder(_ url: URL) {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        if let u = URL(string: "shareddocuments://" + path) { UIApplication.shared.open(u) }
    }

    func reveal(_ url: URL) { openFolder(url.deletingLastPathComponent()) }

    func share(_ urls: [URL], from rect: CGRect) {
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {                       // iPad: a popover at the button
            pop.sourceView = web
            pop.sourceRect = rect.width > 0 ? rect : CGRect(x: web.bounds.midX, y: web.bounds.midY, width: 1, height: 1)
        }
        present(vc, animated: true)
    }

    func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .movie, .audiovisualContent], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        bridge.engine.start(.file, file: url)
    }

    func openPrivacy() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }

    func openDocument(_ url: URL) {
        previewing = url
        let ql = QLPreviewController()
        ql.dataSource = self
        present(ql, animated: true)
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated { (previewing ?? URL(fileURLWithPath: "/")) as NSURL }
    }

    /// 설정 › 테마: dark or light pins the interface (and the page's colour scheme); 시스템 follows iOS.
    func applyAppearance(dark: Bool, system: Bool) {
        let style: UIUserInterfaceStyle = system ? .unspecified : (dark ? .dark : .light)
        overrideUserInterfaceStyle = style
        view.window?.overrideUserInterfaceStyle = style
        let bg = dark ? navy : UIColor(red: 244 / 255, green: 241 / 255, blue: 234 / 255, alpha: 1)
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
    }

    /// The home-screen icon (alternate icons from the asset catalog). iOS tells the user it changed.
    func setAppIcon(_ name: String) {
        let alt = name == "navy" ? nil : "AppIcon-" + name.prefix(1).uppercased() + name.dropFirst()
        guard UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != alt else { return }
        UIApplication.shared.setAlternateIconName(alt) { error in if let error { log("icon: \(error)") } }
    }

    func openLink(_ url: URL) { UIApplication.shared.open(url) }
    func openLogs() {}

    func startScreenSlides() {}                       // iPhone: slides come from imported videos only
    func stopScreenSlides() {}

    func requestRecording(_ done: @escaping @MainActor (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: done(true)
        case .denied: done(false)
        default: AVAudioApplication.requestRecordPermission { ok in Task { @MainActor in done(ok) } }
        }
    }
}
