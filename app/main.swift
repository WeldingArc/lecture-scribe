// 강의 받아쓰기 v2 — a single native app: AppKit window + WKWebView UI (ui/index.html) + the
// in-process engine (Engine.swift) using Apple's on-device speech recognition.
//
// Test mode (no window): LectureScribe --transcribe FILE   |   LectureScribe --live SECONDS   |   LectureScribe --download-engine ID
// (with LECTURE_FAKE_INPUT=FILE to play a file as if it were the Mac's sound; LECTURE_MODEL_URL to download from a local
// server). Events print as JSON lines.

import Cocoa
import UniformTypeIdentifiers
import WebKit

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let devDir = env["LECTURE_DEV_DIR"]
let uiDir = devDir.map { $0 + "/ui" } ?? ((Bundle.main.resourcePath ?? "") + "/ui")
let repoURL = "https://github.com/WeldingArc/lecture-transcriber"
let sandboxed = env["APP_SANDBOX_CONTAINER_ID"] != nil

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, Platform {
    var window: NSWindow!
    var web: WKWebView!
    var bridge: Bridge!
    var engine: Engine { bridge.engine }
    let screenSlides = ScreenSlides()
    var pageReady = false
    var queued: [String] = []
    var activity: NSObjectProtocol?
    var quitting = false

    func applicationDidFinishLaunching(_ n: Notification) {
        clearQuarantine()
        buildMenu()
        bridge = Bridge { [weak self] ev in self?.toPage(ev) }
        bridge.platform = self
        screenSlides.onFrame = { [weak self] img in self?.bridge.engine.session?.addSlideFrame(img) }
        screenSlides.onNote = { [weak self] code, msg in self?.toPage(["ev": "notice", "code": code, "msg": msg]) }
        setAppIcon(bridge.engine.settings.icon)
        buildWindow()
        NSApp.activate()
        log("app started \(appVersion)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Everything is saved by now. After a Whisper model failed to load, skip the C++ teardown (it would abort).
    func applicationWillTerminate(_ notification: Notification) {
        #if WHISPER
        if whisperLoadFailed.value { quit(0) }
        #endif
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)          // keep the window up while a recording is saved
        return false
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        bridge?.finalizeDeletes()
        guard let bridge, bridge.engine.busy else { return .terminateNow }
        if quitting { return .terminateLater }
        quitting = true
        toPage(["ev": "quitting"])
        Task { @MainActor in
            await engine.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// After "Open Anyway" on a browser-downloaded copy, files inside the app keep the download flag.
    func clearQuarantine() {
        guard devDir == nil, !sandboxed else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", Bundle.main.bundlePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: engine → page

    func toPage(_ ev: [String: Any]) {
        if (ev["ev"] as? String) == "rec", let st = ev["state"] as? String { setActivity(st != "idle") }
        guard JSONSerialization.isValidJSONObject(ev),                       // NaN/inf would raise, not throw
              let data = try? JSONSerialization.data(withJSONObject: ev), let json = String(data: data, encoding: .utf8) else {
            log("dropped an event the page can't read: \(ev["ev"] ?? "?")"); return
        }
        guard pageReady else {
            if (ev["ev"] as? String) != "level" { queued.append(json) }
            return
        }
        web.evaluateJavaScript("window.app && window.app.receive(\(json))", completionHandler: nil)
    }

    func setActivity(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "강의 녹음 중")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
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

    // MARK: Platform (what differs from the iPhone app)

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openFolder(_ url: URL) { NSWorkspace.shared.open(url) }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// The share menu (AirDrop, Mail, Messages, Notes…) at the button the page reports.
    func share(_ urls: [URL], from rect: CGRect) {
        let picker = NSSharingServicePicker(items: urls)
        let y = web.isFlipped ? rect.minY : web.bounds.height - rect.maxY          // page coordinates are top-left
        let r = rect.width > 0 ? NSRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
                               : NSRect(x: web.bounds.midX, y: web.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: r, of: web, preferredEdge: .minY)
    }

    func openPrivacy() {
        for s in ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { break }
        }
    }

    func requestRecording(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }   // macOS asks on first capture

    func openDocument(_ url: URL) { NSWorkspace.shared.open(url) }

    /// 설정 › 테마: dark or light pins the window (and the page's colour scheme); 시스템 follows macOS.
    func applyAppearance(dark: Bool, system: Bool) {
        window.appearance = system ? nil : NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(srgbRed: 13 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)
                                      : NSColor(srgbRed: 244 / 255, green: 241 / 255, blue: 234 / 255, alpha: 1)
    }

    /// The Dock icon (the bundle's own icon can't change without breaking its signature).
    func setAppIcon(_ name: String) {
        NSApp.applicationIconImage = name == "navy" ? nil : NSImage(contentsOfFile: uiDir + "/icons/\(name).png")
    }

    func openLink(_ url: URL) { NSWorkspace.shared.open(url) }
    func startScreenSlides() { screenSlides.start() }
    func stopScreenSlides() { screenSlides.stop() }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "받아쓸 녹음·영상 파일"
        panel.prompt = "받아쓰기"
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.engine.start(.file, file: url) }
        }
    }

    /// A file dropped on the window: transcribe it (audio/video only) instead of navigating to it.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL && url.path == URL(fileURLWithPath: uiDir + "/index.html").path { return decisionHandler(.allow) }
        if url.isFileURL {
            let media = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) ?? false
            if !media {
                toPage(["ev": "notice", "code": "file_error", "msg": "녹음이나 영상 파일만 받아 적을 수 있어요."])
            } else if !FileManager.default.isReadableFile(atPath: url.path) {      // the sandbox didn't grant this drop
                toPage(["ev": "notice", "code": "file_error", "msg": "이 파일은 아래쪽 [파일 불러오기]로 열어 주세요."])
            } else {
                engine.start(.file, file: url)               // busy → the engine says so
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    /// The page's process died (rare): load it again; the engine replays the current state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("page process ended; reloading")
        pageReady = false
        queued.removeAll()
        webView.reload()
    }

    // MARK: window & menu

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "강의 받아쓰기"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 13 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 380, height: 560)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "native")
        let testOpen = env["LECTURE_TEST_OPEN"].map { " window.__TEST_OPEN__ = \(jsString($0));" } ?? ""
        cfg.userContentController.addUserScript(WKUserScript(source: "window.__NATIVE__ = true; window.__PLATFORM__ = \"mac\"; window.__LIBRARY__ = true;" + testOpen,
                                                             injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        web = WKWebView(frame: container.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.isInspectable = devDir != nil
        container.addSubview(web)
        // The page fills the whole window (no visible title bar), and a web view swallows clicks, so the
        // top strip gets a native view that moves the window like a title bar would.
        let bar = min(30, max(28, window.frame.height - window.contentLayoutRect.height))
        let strip = TitleBarStrip(frame: NSRect(x: 0, y: container.bounds.height - bar, width: container.bounds.width, height: bar))
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
        window.contentView = container
        web.loadFileURL(URL(fileURLWithPath: uiDir + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: uiDir))
        window.makeKeyAndOrderFront(nil)
    }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(), m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            item.submenu = m
            main.addItem(item)
            return item
        }
        func it(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let appMenu = sub("강의 받아쓰기", [
            it("강의 받아쓰기 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), .separator(),
            it("설정…", #selector(openSettings), ","), .separator(),
            it("강의 받아쓰기 가리기", #selector(NSApplication.hide(_:)), "h"),
            it("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]), .separator(),
            it("강의 받아쓰기 종료", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = sub("편집", [
            it("실행 취소", Selector(("undo:")), "z"), it("실행 복귀", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            it("잘라내기", #selector(NSText.cut(_:)), "x"), it("복사하기", #selector(NSText.copy(_:)), "c"),
            it("붙여넣기", #selector(NSText.paste(_:)), "v"), it("전체 선택", #selector(NSText.selectAll(_:)), "a"),
        ])
        let win = sub("윈도우", [
            it("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"), it("확대/축소", #selector(NSWindow.performZoom(_:)), ""),
            .separator(), it("닫기", #selector(NSWindow.performClose(_:)), "w"),
        ])
        let help = sub("도움말", [
            it("GitHub 페이지 열기", #selector(openRepo), ""),
            it("로그 폴더 열기 (문제 신고용)", #selector(openLogs), ""),
        ])
        help.submenu?.items.forEach { $0.target = self }
        appMenu.submenu?.items.first { $0.action == #selector(openSettings) }?.target = self
        NSApp.mainMenu = main
        NSApp.windowsMenu = win.submenu
        NSApp.helpMenu = help.submenu
    }

    @objc func openRepo() { if let u = URL(string: repoURL) { NSWorkspace.shared.open(u) } }
    @objc func openSettings() { toPage(["ev": "openSettings"]) }
    @objc func openLogs() { NSWorkspace.shared.open(logURL.deletingLastPathComponent()) }
}

/// A Swift string as a JavaScript string literal.
func jsString(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
}

/// Where a title bar would be: drag to move the window, double-click to zoom (or minimize, per the
/// system setting). Sits above the web page's top strip, which has nothing clickable.
final class TitleBarStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { window?.performDrag(with: event); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }
}

// MARK: - entry point

let args = CommandLine.arguments
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Ends the process. After a model failed to load in this run, C++ teardown is skipped: ggml would abort
/// at exit over the half-made GPU state ("quit unexpectedly") — everything is saved by the time this runs.
func quit(_ code: Int32) -> Never {
    #if WHISPER
    if whisperLoadFailed.value { fflush(stdout); fflush(stderr); _exit(code) }
    #endif
    exit(code)
}

let downloadID = flag("--download-engine") ?? (args.contains("--download-whisper") ? "whisper" : nil)
if flag("--transcribe") != nil || flag("--live") != nil || downloadID != nil {
    setvbuf(stdout, nil, _IOLBF, 0)
    MainActor.assumeIsolated {
        var engine: Engine!
        engine = Engine { ev in
            if JSONSerialization.isValidJSONObject(ev), let d = try? JSONSerialization.data(withJSONObject: ev),
               let s = String(data: d, encoding: .utf8) { print(s) }
            #if WHISPER
            if let id = downloadID, ev["ev"] as? String == "engines",
               let w = (ev["list"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) {
                if w["state"] as? String == "ready" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { quit(0) } }
                if w["state"] as? String == "failed" { quit(2) }
            }
            #endif
            switch (ev["ev"] as? String, ev["state"] as? String) {
            case ("engine", "ready") where downloadID != nil:
                engine.downloadEngine(downloadID!)
            case ("engine", "ready"):
                if let f = flag("--transcribe") { engine.start(.file, file: URL(fileURLWithPath: f)) }
                else if let secs = Double(flag("--live") ?? "") {
                    engine.start(.live)
                    Task { try? await Task.sleep(for: .seconds(secs)); engine.stop() }
                }
            case ("engine", "error"): quit(1)
            case ("rec", "idle"): DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { quit(0) }
            default: break
            }
        }
        engine.boot()
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
