// 강의 받아쓰기 — native app shell.
//
// A window with a WKWebView (ui/index.html) plus the Python backend (backend.py) as a child
// process. Backend events (JSON lines on its stdout) are forwarded to the page; page commands
// arrive through `window.webkit.messageHandlers.native`. All transcription logic lives in the
// backend and all presentation in the page.
//
// Everything ships inside the app (Contents/Resources: engine/, ui/, python/). Per-user data —
// the downloaded model, settings, logs — lives in ~/Library/Application Support/LectureScribe.
// For development, LECTURE_DEV_DIR=<checkout> runs the checkout's backend, UI and .venv instead.

import Cocoa
import WebKit

let env = ProcessInfo.processInfo.environment
let home = NSHomeDirectory() as NSString
let devDir = env["LECTURE_DEV_DIR"]
let resources = Bundle.main.resourcePath ?? ""
let engineDir = devDir ?? (resources + "/engine")
let uiDir = devDir.map { $0 + "/ui" } ?? (resources + "/ui")
let pythonPath = devDir.map { $0 + "/.venv/bin/python" } ?? (resources + "/python/bin/python3")
let dataDir = env["LECTURE_DATA_DIR"]       // tests may point this elsewhere
    ?? ((NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
         ?? home.appendingPathComponent("Library/Application Support")) as NSString)
        .appendingPathComponent("LectureScribe")
let logDir = devDir.map { $0 + "/logs" } ?? (dataDir + "/logs")
let outDir = home.appendingPathComponent("강의기록")
let repoURL = "https://github.com/JoshiChoi/lecture-scribe"

func openLog(_ name: String) -> FileHandle? {
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let path = (logDir as NSString).appendingPathComponent(name)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int, size > 5_000_000 {
        let old = (logDir as NSString).appendingPathComponent("old-" + name)
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
    }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let h = FileHandle(forWritingAtPath: path)
    h?.seekToEndOfFile()
    return h
}

final class Backend {
    private var proc: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private let log = openLog("backend.log")
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var running: Bool { proc?.isRunning ?? false }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        // -I: ignore the user's PYTHON* settings; -B: never write .pyc into the signed app.
        p.arguments = (devDir == nil ? ["-I", "-B", "-u"] : ["-u"]) + [engineDir + "/backend.py"]
        p.currentDirectoryURL = URL(fileURLWithPath: engineDir)
        var childEnv = env
        childEnv["PYTHONUNBUFFERED"] = "1"
        childEnv["PYTHONIOENCODING"] = "utf-8"
        childEnv["PYTHONHOME"] = nil
        childEnv["PYTHONPATH"] = nil
        childEnv["LANG"] = env["LANG"] ?? "ko_KR.UTF-8"
        if devDir == nil { childEnv["LECTURE_DATA_DIR"] = dataDir }
        p.environment = childEnv
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = log ?? FileHandle.nullDevice
        buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self = self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.buffer.append(d)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                    DispatchQueue.main.async { self.onLine?(s) }
                }
            }
        }
        p.terminationHandler = { [weak self] pr in
            DispatchQueue.main.async { self?.onExit?(pr.terminationStatus) }
        }
        do {
            try p.run()
            proc = p
            stdinPipe = inPipe
            writeLog("\n=== app started backend pid \(p.processIdentifier) at \(Date()) ===")
        } catch {
            writeLog("failed to start backend: \(error)")
            DispatchQueue.main.async { self.onExit?(-1) }
        }
    }

    func send(_ obj: [String: Any]) {
        guard running, let h = stdinPipe?.fileHandleForWriting,
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? h.write(contentsOf: d + Data([0x0A]))     // the engine may have just exited
    }

    func writeLog(_ s: String) { try? log?.write(contentsOf: Data((s + "\n").utf8)) }   // never crash on a full disk
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let backend = Backend()
    var activity: NSObjectProtocol?
    var pageReady = false
    var queued: [String] = []
    var quitting = false
    var recState = "idle"
    var restarts = 0
    var backendStarted = Date()

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)
        clearQuarantine()
        buildMenu()
        buildWindow()
        backend.onLine = { [weak self] in self?.fromBackend($0) }
        backend.onExit = { [weak self] in self?.backendExited($0) }
        backend.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// After "Open Anyway" on a browser-downloaded copy, the helper programs inside the app are
    /// still flagged as downloaded and could be blocked when the engine starts them.
    func clearQuarantine() {
        guard devDir == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", Bundle.main.bundlePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)   // keep the window visible while the backend saves
        return false
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if !backend.running { return .terminateNow }
        if quitting { return .terminateLater }
        quitting = true
        toPage(#"{"ev":"quitting"}"#)
        backend.send(["cmd": "shutdown"])
        // The backend also saves on its own when our pipe closes, so a forced quit never loses text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func backendExited(_ code: Int32) {
        backend.writeLog("backend exited with status \(code)")
        setActivity(false)
        if quitting {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        recState = "idle"
        if Date().timeIntervalSince(backendStarted) > 60 { restarts = 0 }   // it had been running fine
        if restarts < 3 {
            restarts += 1
            toPage(#"{"ev":"notice","code":"backend_restart","msg":"엔진을 다시 시작하는 중이에요."}"#)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.backendStarted = Date()
                self.backend.start()
            }
        } else {
            toPage(#"{"ev":"engine","state":"error","msg":"엔진이 계속 멈춰요. 앱을 다시 열어 주세요."}"#)
        }
    }

    // MARK: backend → page

    func fromBackend(_ line: String) {
        if line.contains(#""ev": "rec""#) || line.contains(#""ev":"rec""#),
           let d = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let state = obj["state"] as? String {
            recState = state
            setActivity(state != "idle")
        }
        toPage(line)
    }

    func toPage(_ json: String) {
        guard pageReady else {
            if !json.contains(#""ev": "level""#) { queued.append(json) }
            return
        }
        web.evaluateJavaScript("window.app && window.app.receive(\(json))", completionHandler: nil)
    }

    func setActivity(_ on: Bool) {
        if on, activity == nil {
            // Keep the Mac awake and out of App Nap while a lecture is being recorded.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "강의 녹음 중")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: page → native

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "ready":
            pageReady = true
            let pending = queued
            queued.removeAll()
            pending.forEach { toPage($0) }
        case "start", "stop", "retry", "settings":
            backend.send(body)
        case "copy":
            let text = body["text"] as? String ?? ""
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            toPage(#"{"ev":"copied","chars":\#(text.count)}"#)
        case "openFolder":
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: outDir))
        case "openFile":
            if let p = body["path"] as? String, FileManager.default.fileExists(atPath: p) {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            }
        case "reveal":
            if let p = body["path"] as? String, FileManager.default.fileExists(atPath: p) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        case "pickFile":
            pickFile()
        case "openPrivacy":
            let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
            if let u = URL(string: urls[0]), NSWorkspace.shared.open(u) { break }
            if let u = URL(string: urls[1]) { NSWorkspace.shared.open(u) }
        case "log":
            backend.writeLog("page: \(body["msg"] ?? "")")
        default:
            break
        }
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "받아쓸 녹음·영상 파일"
        panel.prompt = "받아쓰기"
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.backend.send(["cmd": "file", "path": url.path]) }
        }
    }

    // Dropping a file on the window makes WebKit try to open it: intercept and transcribe it instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let page = URL(fileURLWithPath: uiDir + "/index.html")
        if url.isFileURL && url.path == page.path { return decisionHandler(.allow) }
        if url.isFileURL && recState == "idle" {
            backend.send(["cmd": "file", "path": url.path])
        } else if !url.isFileURL {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    // MARK: window & menu

    func buildWindow() {
        let ink = NSColor(srgbRed: 0x0d / 255.0, green: 0x12 / 255.0, blue: 0x20 / 255.0, alpha: 1)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "강의 받아쓰기"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ink
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 380, height: 560)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "native")
        cfg.userContentController.addUserScript(WKUserScript(
            source: "window.__NATIVE__ = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        if #available(macOS 13.3, *) { web.isInspectable = true }
        window.contentView = web
        web.loadFileURL(URL(fileURLWithPath: uiDir + "/index.html"),
                        allowingReadAccessTo: URL(fileURLWithPath: uiDir))
        window.makeKeyAndOrderFront(nil)
    }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
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
        _ = sub("강의 받아쓰기", [
            it("강의 받아쓰기 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            it("강의 받아쓰기 가리기", #selector(NSApplication.hide(_:)), "h"),
            it("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            it("강의 받아쓰기 종료", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = sub("편집", [
            it("실행 취소", Selector(("undo:")), "z"),
            it("실행 복귀", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            it("잘라내기", #selector(NSText.cut(_:)), "x"),
            it("복사하기", #selector(NSText.copy(_:)), "c"),
            it("붙여넣기", #selector(NSText.paste(_:)), "v"),
            it("전체 선택", #selector(NSText.selectAll(_:)), "a"),
        ])
        let win = sub("윈도우", [
            it("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"),
            it("확대/축소", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            it("닫기", #selector(NSWindow.performClose(_:)), "w"),
        ])
        let help = sub("도움말", [
            it("GitHub 페이지 열기", #selector(openRepo), ""),
            it("로그 폴더 열기 (문제 신고용)", #selector(openLogs), ""),
        ])
        help.submenu?.items.forEach { $0.target = self }
        NSApp.mainMenu = main
        NSApp.windowsMenu = win.submenu
        NSApp.helpMenu = help.submenu
    }

    @objc func openRepo() {
        if let u = URL(string: repoURL) { NSWorkspace.shared.open(u) }
    }

    @objc func openLogs() {
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: logDir))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
