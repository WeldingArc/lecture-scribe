// Engine of 강의 받아쓰기 v2: sessions, files, settings — talking to the UI with the same JSON
// events as v1 ({"ev": "seg", ...}), so the interface (ui/index.html) is shared.

import AVFoundation
import Foundation

let env = ProcessInfo.processInfo.environment

/// The real home folder (inside Apple's sandbox, NSHomeDirectory() points into the container).
let realHome: URL = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
    return URL(fileURLWithPath: NSHomeDirectory())
}()

extension String {
    /// File names come back from disk decomposed (NFD); everything the page sees uses precomposed NFC.
    var nfc: String { precomposedStringWithCanonicalMapping }
}

func fmtTime(_ sec: Double) -> String {
    let s = Int(max(0, sec)), h = s / 3600, m = s % 3600 / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
}

let defaultKeywords = ["출석", "시험", "과제", "퀴즈", "키워드", "암호", "비밀번호", "오늘의 단어", "확인 단어",
                       "attendance", "exam", "quiz", "assignment", "keyword", "password"]

/// Korean keywords match inside words and ignore spacing; Latin-script keywords match whole words
/// (+ plurals) — "exam" finds "exams" and "exam은" but not "example". Same rules as the UI.
func keywordRegex(_ words: [String]) -> NSRegularExpression? {
    let parts = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { w -> String in
        let body = w.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s?")
        let latin = w.range(of: "^[A-Za-z0-9 .'-]+$", options: .regularExpression) != nil
        return latin ? "(?<![A-Za-z0-9])\(body)(?:s|es)?(?![A-Za-z0-9])" : body
    }
    return parts.isEmpty ? nil : try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.caseInsensitive])
}

struct Settings {
    var keywords: [String]
    var timestamps: Bool
    var slides: Bool                       // collect slides into a PDF (Mac: the lecture window; files: their video)
    var theme: String                      // 설정: "dark" | "light" | "system"
    var accent: String                     // brass | sage | rose | blue | lavender
    var size: String                       // text size: s | m | l | xl
    var icon: String                       // app icon: navy | ivory | brass | charcoal | sage
    var engine: String                     // 설정 › 음성 인식: apple | whisper | qwen3 | parakeet (Mac, once downloaded)
    var language: String                   // 강의 언어 (main screen): ko | en — the lecture's main language
    static func load() -> Settings {
        let d = UserDefaults.standard
        func pick(_ k: String, _ allowed: [String], _ dflt: String) -> String { allowed.contains(d.string(forKey: k) ?? "") ? d.string(forKey: k)! : dflt }
        return Settings(keywords: d.stringArray(forKey: "keywords") ?? defaultKeywords,
                        timestamps: d.object(forKey: "timestamps") as? Bool ?? true,
                        slides: env["LECTURE_SLIDES"].map { $0 == "1" } ?? (d.object(forKey: "slides") as? Bool ?? false),
                        theme: pick("theme", ["dark", "light", "system"], "dark"),
                        accent: pick("accent", ["brass", "sage", "rose", "blue", "lavender"], "brass"),
                        size: pick("size", ["s", "m", "l", "xl"], "m"),
                        icon: pick("icon", appIcons, "navy"),
                        engine: env["LECTURE_ENGINE"] ?? pick("engine", speechEngines, "apple"),
                        language: env["LECTURE_LANGUAGE"] ?? pick("language", ["ko", "en"], "ko"))
    }
    func save() {
        let d = UserDefaults.standard
        d.set(keywords, forKey: "keywords"); d.set(timestamps, forKey: "timestamps"); d.set(slides, forKey: "slides")
        d.set(theme, forKey: "theme"); d.set(accent, forKey: "accent"); d.set(size, forKey: "size"); d.set(icon, forKey: "icon")
        d.set(engine, forKey: "engine"); d.set(language, forKey: "language")
    }
    /// What the page needs to show them.
    var event: [String: Any] {
        ["ev": "settings", "keywords": keywords, "timestamps": timestamps, "slides": slides, "theme": theme, "accent": accent,
         "size": size, "icon": icon, "engine": engine, "language": language,
         "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]
    }
}

let appIcons = ["navy", "ivory", "brass", "charcoal", "sage"]

/// The speech engines this build can offer. Apple's is built in; the others (Mac) are optional downloads.
#if WHISPER
let speechEngines = ["apple"] + engineSpecs.map(\.id)
#else
let speechEngines = ["apple"]
#endif

// MARK: - WAV writing (crash-safe) and AAC compression

/// 16-bit mono WAV whose header is patched every few seconds, so a crash never loses audio.
final class WavWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "lecture.wav")
    private var bytes = 0
    private var lastPatch = Date()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.url = url
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WavWriter.header(dataBytes: 0))
    }

    static func header(dataBytes n: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(clamping: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n)
        return d
    }

    /// A WAV can't describe more than 4 GiB (≈ 37 hours); the recording stops growing there, the transcript doesn't.
    static let maxDataBytes = Int(UInt32.max) - 64

    func write(_ buf: AVAudioPCMBuffer) {
        guard let p = buf.int16ChannelData?[0] else { return }
        let data = Data(bytes: p, count: Int(buf.frameLength) * 2)
        queue.async { [self] in
            guard bytes + data.count <= WavWriter.maxDataBytes else { return }
            try? handle.write(contentsOf: data)
            bytes += data.count
            if Date().timeIntervalSince(lastPatch) > 5 { patch() }
        }
    }

    private func patch() {
        let end = (try? handle.offset()) ?? 0
        try? handle.seek(toOffset: 4); try? handle.write(contentsOf: WavWriter.header(dataBytes: bytes).subdata(in: 4..<8))
        try? handle.seek(toOffset: 40); try? handle.write(contentsOf: WavWriter.header(dataBytes: bytes).subdata(in: 40..<44))
        try? handle.seek(toOffset: end)
        lastPatch = Date()
    }

    /// Returns seconds written.
    func close() -> Double {
        queue.sync { patch(); try? handle.close() }
        return Double(bytes) / 2 / 16000
    }
}

/// Seconds of audio in a file, or nil if it can't be read (e.g. an m4a cut off mid-write).
func audioSeconds(_ url: URL) -> Double? {
    guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
    return Double(f.length) / f.fileFormat.sampleRate
}

/// WAV → AAC .m4a (≈15 MB per hour). The m4a is written under a hidden temporary name, closed and
/// re-read; only a complete one gets the real name, and only then is the WAV deleted.
/// compress()'s temporary file beside the recording: hidden, and ending in .m4a — AVAudioFile picks the container from
/// the name, and from a ".part" name it wrote CAF (files named .m4a that weren't MPEG-4 until 2.3).
func compressPart(_ m4a: URL) -> URL {
    m4a.deletingLastPathComponent().appendingPathComponent(".\(m4a.deletingPathExtension().lastPathComponent).part.m4a")
}

func compress(wav: URL, seconds: Double) async -> URL {
    let fm = FileManager.default
    let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
    let part = compressPart(m4a)
    try? fm.removeItem(at: part)
    do {
        let input = try AVAudioFile(forReading: wav)
        let output = try AVAudioFile(forWriting: part, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16000 * 10)!
        while input.framePosition < input.length {
            try input.read(into: chunk)
            if chunk.frameLength == 0 { break }
            try output.write(from: chunk)
        }
        output.close()
        if let produced = audioSeconds(part), abs(produced - seconds) < 1.0 {
            if fm.fileExists(atPath: m4a.path) { try fm.removeItem(at: m4a) }      // a broken leftover, never a good one
            try fm.moveItem(at: part, to: m4a)
            try? fm.removeItem(at: wav)
            return m4a
        }
        log("compress check failed: \(audioSeconds(part) ?? -1) vs \(seconds)")
    } catch {
        log("compress error: \(error)")
    }
    try? fm.removeItem(at: part)
    return wav
}

// MARK: - Engine

@MainActor
final class Engine {
    let emit: ([String: Any]) -> Void
    private(set) var ready = false
    private var booting = false
    private(set) var session: Session?
    private var saving: [Task<Void, Never>] = []
    private var savingSessions: [Session] = []
    private var recovering: Set<String> = []

    /// Sessions whose files are still being written: recording, or saving after 정지.
    var busyIDs: Set<String> {
        var ids = Set(savingSessions.filter { !$0.done }.map(\.id)).union(recovering)
        if let s = session { ids.insert(s.id) }
        return ids
    }
    var settings = Settings.load()
    var keywords: NSRegularExpression?
    let outDir: URL = env["LECTURE_OUT_DIR"].map { URL(fileURLWithPath: $0) } ?? Engine.defaultOutDir

    /// Mac: 다운로드/강의기록. iPhone/iPad: the app's own folder in the Files app.
    static var defaultOutDir: URL {
        #if os(macOS)
        realHome.appendingPathComponent("Downloads/강의기록")
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    #if WHISPER
    let models = engineSpecs.map { ModelStore(spec: $0) }
    func model(_ id: String) -> ModelStore? { models.first { $0.spec.id == id } }
    #endif

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
        keywords = keywordRegex(settings.keywords)
        #if WHISPER
        if let m = model(settings.engine), !m.installed { settings.engine = "apple"; settings.save() }   // model gone
        for m in models {
            let id = m.spec.id
            m.onChange = { [weak self] in self?.modelsChanged() }
            m.onReady = { [weak self] in self?.downloaded(id) }
        }
        #endif
    }

    #if WHISPER
    /// Downloaded on purpose: use it — unless it can't write the current lecture's language and another downloaded
    /// engine already does (Parakeet doesn't push Qwen3-ASR aside for a Korean lecture).
    private func downloaded(_ id: String) {
        guard let m = model(id) else { return }
        let name = m.spec.name
        if m.spec.languages.contains(settings.language) { selectEngine(id); return }
        if let current = model(settings.engine), current.state == .ready, current.spec.languages.contains(settings.language) {
            emit(["ev": "notice", "code": "engine_language",
                  "msg": "\(name) 모델을 내려받았습니다. 영어 강의 전용이라 지금은 \(current.spec.name) 모델을 그대로 사용합니다 — 영어 강의에 사용하려면 설정 › 음성 인식에서 선택하십시오."])
            emit(enginesEvent)
            return
        }
        selectEngine(id)
        emit(["ev": "notice", "code": "engine_language",
              "msg": "\(name) 모델은 영어 강의 전용입니다. 강의 언어를 English로 바꾸면 \(name) 모델로 받아 적습니다."])
    }

    /// A shared file (the voice detector) may have gone with another engine's check.
    private func modelsChanged() {
        models.forEach { $0.refresh() }
        emit(enginesEvent)
    }
    #endif

    /// 설정 › 음성 인식: every engine this app offers and its state. The page draws whatever is listed, so another
    /// platform (a Windows build, say) can offer its own engines through the same events and commands.
    var enginesEvent: [String: Any] {
        var list: [[String: Any]] = [["id": "apple", "name": "Apple 음성 인식", "desc": "기본 · 추가 다운로드 없이 가볍고 빠릅니다",
                                      "state": "ready", "bytes": 0]]
        #if WHISPER
        for m in models {                                 // a ready engine's size: what 삭제 frees (the shared detector stays
            var info = m.info                             // while another engine has it)
            if m.state == .ready {
                let shared = Set(models.filter { $0 !== m && $0.state != .absent }.flatMap { $0.spec.files.map(\.name) })
                info["bytes"] = m.spec.files.filter { !shared.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
            }
            list.append(info)
        }
        #endif
        var current = settings.engine
        #if WHISPER
        if let m = model(current), m.state != .ready { current = "apple" }                   // what a recording would use
        #endif
        return ["ev": "engines", "list": list, "current": current, "busy": session != nil]
    }

    func selectEngine(_ id: String) {
        #if WHISPER
        guard id == "apple" || model(id)?.state == .ready else { return }
        #else
        guard id == "apple" else { return }
        #endif
        if settings.engine != id { log("engine: \(id)") }
        settings.engine = id
        settings.save()
        emit(settings.event)
        emit(enginesEvent)
    }

    func downloadEngine(_ id: String) {
        #if WHISPER
        guard let m = model(id) else { return }
        if let other = models.first(where: { $0 !== m && ($0.downloading || $0.state == .verifying) }) {   // one at a time
            emit(["ev": "notice", "code": "engine_downloading",
                  "msg": "\(other.spec.name) 모델을 내려받는 중입니다. 끝난 뒤에 내려받을 수 있습니다."])
            return
        }
        m.download()
        #endif
    }

    func cancelEngine(_ id: String) {
        #if WHISPER
        model(id)?.cancel()
        #endif
    }

    func removeEngine(_ id: String) {
        #if WHISPER
        guard let m = model(id) else { return }
        if session?.engineID == id || savingSessions.contains(where: { !$0.done && $0.engineID == id }) {
            emit(["ev": "notice", "code": "engine_busy", "msg": "지금 \(m.spec.name) 모델로 받아 적는 중입니다. 끝난 뒤에 삭제할 수 있습니다."])
            return
        }
        // the voice detector stays while another engine has it
        let shared = Set(models.filter { $0 !== m && $0.state != .absent }.flatMap { $0.spec.files.map(\.name) })
        m.remove(keeping: shared)
        if settings.engine == id { selectEngine("apple") } else { emit(enginesEvent) }
        #endif
    }

    /// The recognizer for a new session: the chosen engine, or Apple's when the chosen one isn't ready.
    func makeRecognizer(live: Bool) -> (SpeechRecognizer, String) {
        #if WHISPER
        if let m = model(settings.engine) {
            let name = m.spec.name
            if !m.spec.languages.contains(settings.language) {
                emit(["ev": "notice", "code": "engine_language",
                      "msg": "\(name) 모델은 영어 강의 전용이라 한국어 강의는 Apple 음성 인식으로 받아 적습니다."])
            } else if m.state == .ready {
                let r = WhisperRecognizer(live: live, major: settings.language, spec: m.spec)
                r.onFallback = { [weak m] in m?.recheck() }
                return (r, m.spec.id)
            } else {
                emit(["ev": "notice", "code": "engine_missing", "msg": m.downloading || m.state == .verifying
                      ? "\(name) 모델을 아직 준비하는 중이라 이번에는 Apple 음성 인식으로 받아 적습니다."
                      : "\(name) 모델이 없어서 Apple 음성 인식으로 받아 적습니다. 설정 › 음성 인식에서 내려받을 수 있습니다."])
            }
        }
        #endif
        return (Recognizer(main: settings.language), "apple")
    }

    var busy: Bool { session != nil || !saving.isEmpty }

    /// 슬라이드 PDF turned off while sessions are still being saved: no PDF for them either.
    func dropSavingSlides() { savingSessions.filter { !$0.done }.forEach { $0.dropSlides() } }

    /// The page loaded (or reloaded, e.g. after iOS reclaimed it in the background).
    func pageLoaded() {
        if ready || booting { replay() } else { boot() }
    }

    /// Everything a freshly loaded page needs to show the current state.
    func replay() {
        emit(settings.event)
        emit(enginesEvent)
        emit(ready ? ["ev": "engine", "state": "ready", "msg": "준비됨"] : ["ev": "engine", "state": "loading", "msg": "엔진 준비 중"])
        if let s = session { s.replay() }
        else if let s = savingSessions.first(where: { !$0.done }) {
            emit(["ev": "rec", "state": "finishing", "mode": s.mode == .live ? "live" : "file"])
        }
    }

    func boot() {
        guard !booting, !ready else { return }
        booting = true
        emit(settings.event)
        emit(enginesEvent)
        emit(["ev": "engine", "state": "loading", "msg": "엔진 준비 중"])
        Task {
            do {
                try await Recognizer.prepare { fraction in
                    Task { @MainActor in
                        self.emit(["ev": "engine", "state": "downloading", "done": Int(fraction * 100), "total": 100,
                                   "label": "음성 인식 모델 준비 중"])
                    }
                }
                ready = true
                booting = false
                emit(["ev": "engine", "state": "ready", "msg": "준비됨"])
                log("engine ready")
                #if WHISPER
                for m in models { m.warmUpIfUpdated(selected: settings.engine == m.spec.id) }
                #endif
                let dir = self.outDir
                Task.detached {
                    recoverSlides()
                    await recoverOrphans(in: dir) { id, busy in
                        await MainActor.run {
                            if busy { self.recovering.insert(id) } else { self.recovering.remove(id); self.emit(["ev": "recovered", "id": id]) }
                        }
                    }
                }
                if env["LECTURE_AUTOSTART"] == "1" {
                    start(.live)
                    if let s = Double(env["LECTURE_AUTOSTOP"] ?? "") {
                        Task { try? await Task.sleep(for: .seconds(s)); self.stop() }
                    }
                }
            } catch {
                booting = false
                log("engine boot failed: \(error)")
                emit(["ev": "engine", "state": "error", "retry": true,
                      "msg": (error as NSError).localizedDescription.isEmpty ? "음성 인식을 시작하지 못했습니다." : "음성 인식을 시작하지 못했습니다. \((error as NSError).localizedDescription)"])
            }
        }
    }

    /// iPhone: the document picker's copy of a file we won't use.
    private func discardIfTemp(_ file: URL?) {
        guard let f = file, f.resolvingSymlinksInPath().path
            .hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) else { return }
        try? FileManager.default.removeItem(at: f)
    }

    func start(_ mode: Session.Mode, file: URL? = nil) {
        guard session == nil else {
            if mode == .file { emit(["ev": "notice", "code": "busy_recording", "msg": "지금 받아 적는 중입니다. 끝난 뒤에 다시 시도하십시오."]) }
            discardIfTemp(file)
            return
        }
        guard savingSessions.allSatisfy({ $0.done }) else {
            emit(["ev": "notice", "code": "busy_saving", "msg": "저장이 끝나면 다시 시작할 수 있습니다."])
            discardIfTemp(file)
            return
        }
        guard ready else {
            emit(["ev": "notice", "code": "not_ready", "msg": "엔진이 아직 준비 중입니다. 준비되면 다시 시도하십시오."])
            discardIfTemp(file)
            return
        }
        do {
            let s = try Session(engine: self, mode: mode, file: file)
            session = s
            emit(enginesEvent)
            Task {
                do { try await s.start() } catch {
                    guard session === s else { log("late start failure ignored: \(error)"); return }   // that session already ended
                    log("session start failed: \(error)")
                    if mode == .file {
                        let ce = error as? CaptureError
                        emit(["ev": "notice", "code": "file_error", "msg": ce?.status == -3
                              ? "파일을 여는 데 너무 오래 걸립니다. iCloud나 네트워크에 있는 파일이면 먼저 이 기기에 내려받은 뒤 다시 시도하십시오."
                              : ce?.step == "no audio track" ? "이 파일에는 소리가 없어서 받아 적을 수 없습니다."
                              : "이 파일에서 소리를 읽을 수 없습니다. 녹음이나 영상 파일인지 확인하십시오."])
                    } else {
                        emit(["ev": "notice", "code": "tap_error", "msg": "소리를 가져오지 못했습니다."])
                    }
                    stop()
                }
            }
        } catch {
            emit(["ev": "notice", "code": "file_missing", "msg": "파일을 만들거나 열 수 없습니다."])
            discardIfTemp(file)
        }
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        emit(enginesEvent)
        savingSessions.append(s)
        let t = Task { await s.finish() }
        saving.append(t)
        Task {
            await t.value
            saving.removeAll { $0 == t }
            savingSessions.removeAll { $0 === s }
        }
    }

    /// Quit: stop and wait for every save in progress.
    func shutdown() async {
        stop()
        for t in saving { await t.value }
    }

    func updateSettings(_ msg: [String: Any]) {
        if let words = msg["keywords"] as? [String] {
            settings.keywords = Array(words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(60))
            keywords = keywordRegex(settings.keywords)
        }
        if let ts = msg["timestamps"] as? Bool { settings.timestamps = ts }
        if let sl = msg["slides"] as? Bool { settings.slides = sl }
        if let v = msg["theme"] as? String, ["dark", "light", "system"].contains(v) { settings.theme = v }
        if let v = msg["accent"] as? String, ["brass", "sage", "rose", "blue", "lavender"].contains(v) { settings.accent = v }
        if let v = msg["size"] as? String, ["s", "m", "l", "xl"].contains(v) { settings.size = v }
        if let v = msg["icon"] as? String, appIcons.contains(v) { settings.icon = v }
        if let v = msg["language"] as? String, ["ko", "en"].contains(v), v != settings.language {
            settings.language = v
            #if WHISPER
            if let m = model(settings.engine), m.state == .ready, !m.spec.languages.contains(v) {   // Parakeet: English only
                emit(["ev": "notice", "code": "engine_language",
                      "msg": "\(m.spec.name) 모델은 영어 강의 전용이라 한국어 강의는 Apple 음성 인식으로 받아 적습니다."])
            }
            #endif
        }
        settings.save()
        emit(settings.event)
    }
}

/// Waits for a task, but no longer than `seconds` (the task keeps running if it's slower).
func waitBriefly(for task: Task<Void, Error>, seconds: Double) async {
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    }
    let once = Once()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        Task { _ = try? await task.value; once.run { c.resume() } }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.run { c.resume() } }
    }
}

/// Hands an audio source to the thread that starts it (sources do their own locking).
/// How far into a video its slides are read (중지 part-way: up to what was transcribed). Any thread.
private final class SlideLimit: @unchecked Sendable {
    private let lock = NSLock(); private var v = Double.infinity
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

private final class SourceBox: @unchecked Sendable {
    let source: AudioSource
    init(_ s: AudioSource) { source = s }
}

/// 일시정지 for the audio thread: while paused the sound is let go. The first buffer after pausing becomes a short
/// silence instead, so the sentence before the break ends there — the recording gets the same silence and stays in
/// step with the transcript's times.
private final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false, gap = false
    func set(_ on: Bool) { lock.lock(); paused = on; if on { gap = true }; lock.unlock() }
    /// Audio thread: (drop this buffer, put the silence in first).
    func take() -> (drop: Bool, gap: Bool) {
        lock.lock(); defer { lock.unlock() }
        let g = gap
        gap = false
        return (paused, g)
    }
}

/// Quiet audio in the sources' format (16 kHz mono Int16).
func silence(seconds: Double) -> AVAudioPCMBuffer? {
    let n = AVAudioFrameCount(seconds * sampleRate)
    guard let b = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: n), let p = b.int16ChannelData?[0] else { return nil }
    b.frameLength = n
    p.update(repeating: 0, count: Int(n))
    return b
}

// MARK: - Session

private let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

@MainActor
final class Session {
    enum Mode { case live, file }

    let mode: Mode
    unowned let engine: Engine
    let txtURL: URL
    let header: String
    var id: String { txtURL.deletingPathExtension().lastPathComponent.nfc }
    /// Set just before "saved": the files are final from here on.
    private(set) var done = false
    private let wav: WavWriter?
    private let fileURL: URL?
    private var source: AudioSource?
    private var startTask: Task<Void, Error>?
    private let recognizer: SpeechRecognizer
    /// Which engine transcribes this session ("apple", or a downloaded one's id).
    let engineID: String
    private var slides: SlideCollector?
    private var slideTask: Task<Void, Never>?
    private var slideProgress: Double?
    private let slideLimit = SlideLimit()
    private var reachedEnd = false
    private var lines: [Int: Line] = [:]
    private var written: Set<Int> = []
    private var handle: FileHandle?
    private let stats = Stats()
    private var watchdog: Timer?
    private var stopping = false
    private var closed = false
    private var duration: Double = 0
    private let started = Date()
    private let gate = PauseGate()
    /// 일시정지 (live recordings): nothing is recognized or recorded until 계속.
    private(set) var paused = false
    private var pausedSince: Date?
    private var pausedTotal: Double = 0

    /// Audio-thread counters.
    final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var _samples = 0, _nonzero = false, _last = Date.distantPast, _peak: Float = 0, _levelAt = Date()
        func add(_ buf: AVAudioPCMBuffer) -> Float? {
            guard let p = buf.int16ChannelData?[0] else { return nil }
            let n = Int(buf.frameLength)
            var sum: Float = 0, any = false
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v; if p[i] != 0 { any = true } }
            lock.lock(); defer { lock.unlock() }
            _samples += n; _last = Date(); if any { _nonzero = true }
            _peak = max(_peak, (sum / Float(max(n, 1))).squareRoot())
            guard Date().timeIntervalSince(_levelAt) >= 0.1 else { return nil }
            let level = _peak; _peak = 0; _levelAt = Date()
            return level
        }
        var samples: Int { lock.lock(); defer { lock.unlock() }; return _samples }
        var nonzero: Bool { lock.lock(); defer { lock.unlock() }; return _nonzero }
        var last: Date { lock.lock(); defer { lock.unlock() }; return _last }
    }

    init(engine: Engine, mode: Mode, file: URL?) throws {
        self.engine = engine
        self.mode = mode
        self.fileURL = file
        (recognizer, engineID) = engine.makeRecognizer(live: mode == .live)
        try FileManager.default.createDirectory(at: engine.outDir, withIntermediateDirectories: true)
        let now = Date(), cal = Calendar(identifier: .gregorian), c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let stamp = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let title = mode == .live ? String(format: "%@ %02d시%02d분 강의", stamp, c.hour!, c.minute!)
                                  : "\(file!.deletingPathExtension().lastPathComponent) 받아쓰기"
        txtURL = Session.unique(engine.outDir.appendingPathComponent("\(title).txt"))
        header = mode == .live ? String(format: "강의 녹취 · %@ (%@) %02d:%02d 시작", stamp, weekdays[c.weekday! - 1], c.hour!, c.minute!)
                               : "파일 받아쓰기 · \(file!.lastPathComponent) · \(stamp)"
        wav = try WavWriter(url: txtURL.deletingPathExtension().appendingPathExtension("wav"))   // files too: every session keeps its audio
        FileManager.default.createFile(atPath: txtURL.path, contents: (header + "\n\n").data(using: .utf8))
        handle = try FileHandle(forWritingTo: txtURL)
        _ = try? handle?.seekToEnd()
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        func taken(_ u: URL) -> Bool { ["txt", "wav", "m4a", "pdf"].contains { fm.fileExists(atPath: u.deletingPathExtension().appendingPathExtension($0).path) } }
        if !taken(url) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        for i in 2... {
            let u = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(i)).txt")
            if !taken(u) { return u }
        }
        return url
    }

    func start() async throws {
        recognizer.onLine = { [weak self] in self?.handle($0) }
        recognizer.onError = { [weak self] e in
            log("recognizer error: \(e)")
            self?.engine.emit(["ev": "notice", "code": "recognizer",
                               "msg": (e as? EngineError)?.message ?? "음성 인식이 잠시 멈췄습니다. 녹음은 계속됩니다."])
        }
        try await recognizer.start()
        if stopping { return }                       // 정지 already pressed: don't open the microphone/tap at all
        let src: AudioSource
        var fileSource: FileAudioSource?
        if mode == .file, let f = fileURL {
            let fs = FileAudioSource(url: f)
            fileSource = fs
            src = fs
        } else if let fake = env["LECTURE_FAKE_INPUT"] {          // tests: a file played like live audio
            src = FileAudioSource(url: URL(fileURLWithPath: fake), realtime: true)
        } else {
            #if os(macOS)
            src = SystemAudioSource()
            #else
            src = MicAudioSource()
            #endif
        }
        source = src
        src.onProblem = { [weak self] code, msg in
            DispatchQueue.main.async { self?.engine.emit(["ev": "notice", "code": code, "msg": msg]) }
        }
        let rec = recognizer, stats = stats, wav = wav, mode = mode, gate = gate
        src.onBuffer = { [weak self] buf in                       // hooked up before any audio can flow
            guard let buf else {                                    // the file ended: stop this session — never a newer one
                if mode == .file {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.reachedEnd = true } }
                    DispatchQueue.main.async { MainActor.assumeIsolated { if let self, self.engine.session === self { self.engine.stop() } } }
                }
                return
            }
            let (drop, gap) = gate.take()
            if gap, let quiet = silence(seconds: 1.5) { rec.push(quiet); wav?.write(quiet); _ = stats.add(quiet) }
            if drop { return }
            rec.push(buf)
            wav?.write(buf)
            if let level = stats.add(buf) {
                let db = 20 * log10(Double(level) + 1e-9)
                let v = max(0, min(1, (db + 60) / 60))
                DispatchQueue.main.async { self?.tick(level: v) }
            }
        }
        // The UI shows "recording" (and the no-sound watchdog runs) even while the start below waits.
        engine.emit(["ev": "rec", "state": "recording", "mode": mode == .live ? "live" : "file",
                     "started": Date().timeIntervalSince1970, "txt": txtURL.path,
                     "title": txtURL.deletingPathExtension().lastPathComponent, "header": header])
        if mode == .live {
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        // Starting can block (macOS's system-audio permission prompt, probing a file): never on the main thread.
        let box = SourceBox(src)
        let t = Task<Void, Error> {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try box.source.start(); c.resume() } catch { c.resume(throwing: error) }
                }
            }
        }
        startTask = t
        try await t.value
        guard !stopping else { return }                       // 정지 came while starting
        if let fs = fileSource { duration = fs.duration }
        if mode == .file, engine.settings.slides, let f = fileURL, !(await VideoSlides.hasVideo(f)) {
            engine.emit(["ev": "notice", "code": "slides_note", "msg": "소리만 있는 파일이라 슬라이드 PDF는 만들지 않습니다."])
        }
        if mode == .file, engine.settings.slides, let f = fileURL, await VideoSlides.hasVideo(f), !stopping {   // slides from the video
            let c = try SlideCollector(settle: 1, transcript: txtURL)     // one frame a second: two alike
            slides = c
            slideProgress = 0
            c.onCount = { [weak self] n in DispatchQueue.main.async { MainActor.assumeIsolated { self?.engine.emit(["ev": "slides", "count": n]) } } }
            c.onPreview = previewSender()
            let limit = slideLimit
            slideTask = Task.detached(priority: .utility) {
                await VideoSlides.extract(f, into: c, until: { limit.value }) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.slidesAdvanced(p) } }
                }
            }
        }
        log("capture started (\(mode == .live ? "live" : "file"), \(engineID))")
    }

    /// Re-sends this session to a page that was reloaded mid-recording.
    func replay() {
        engine.emit(["ev": "rec", "state": stopping ? "finishing" : "recording", "mode": mode == .live ? "live" : "file",
                     "started": started.timeIntervalSince1970, "txt": txtURL.path, "title": id, "header": header, "replay": true])
        for l in lines.values.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            engine.emit(["ev": "seg", "id": l.id, "t": (l.start * 100).rounded() / 100, "text": l.text, "final": l.final])
        }
        if paused || pausedTotal > 0 { emitPaused() }
    }

    /// 일시정지 / 계속 (live recordings only). The page's clock leaves the paused time out, like the recording does.
    func setPaused(_ on: Bool) {
        guard mode == .live, !stopping, on != paused else { return }
        paused = on
        gate.set(on)
        if on { pausedSince = Date() } else if let s = pausedSince { pausedTotal += Date().timeIntervalSince(s); pausedSince = nil }
        emitPaused()
        log(on ? "paused" : "resumed")
    }

    private func emitPaused() {
        engine.emit(["ev": "paused", "on": paused, "total": (pausedTotal * 10).rounded() / 10,
                     "since": pausedSince?.timeIntervalSince1970 ?? 0])
    }

    private func tick(level v: Double) {
        guard !closed else { return }
        engine.emit(["ev": "level", "v": (v * 1000).rounded() / 1000])
        if mode == .file, duration > 0 {
            let audio = min(1, Double(stats.samples) / 16000 / duration)
            engine.emit(["ev": "progress", "done": min(audio, slideProgress ?? 1)])
        }
    }

    private func slidesAdvanced(_ p: Double) {
        slideProgress = p
        if stopping, !closed { engine.emit(["ev": "progress", "slides": (p * 100).rounded() / 100]) }
    }

    /// 슬라이드 PDF turned off mid-session: stop collecting and throw away what was collected.
    func dropSlides() {
        slideTask?.cancel()
        slides?.discard()
        slides = nil
        slideProgress = nil
    }

    /// The live preview for the page: the frame (small JPEG) and the lecturer's camera, if one was found.
    private func previewSender() -> @Sendable (String, CGRect?) -> Void {
        { [weak self] jpeg, cam in
            let camera: Any = cam.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } ?? NSNull()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.engine.emit(["ev": "slidePreview", "img": "data:image/jpeg;base64," + jpeg, "camera": camera]) } }
        }
    }

    /// A frame of the lecture window (Mac). Slides are found as they appear.
    func addSlideFrame(_ image: CGImage) {
        guard mode == .live, !stopping, !paused, engine.settings.slides else { return }   // paused: the window may show anything
        if slides == nil {
            slides = try? SlideCollector(settle: 1.5, transcript: txtURL)
            slides?.onCount = { [weak self] n in DispatchQueue.main.async { MainActor.assumeIsolated { self?.engine.emit(["ev": "slides", "count": n]) } } }
            slides?.onPreview = previewSender()
        }
        slides?.add(image, at: Double(stats.samples) / 16000)     // audio time, like the transcript: a paused video can't shift it
    }

    private var notified = false
    private func check() {
        let elapsed = Date().timeIntervalSince(started) - pausedTotal - (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
        if paused || Date().timeIntervalSince(stats.last) > 0.6 { engine.emit(["ev": "level", "v": 0]) }
        guard !notified, !paused else { return }
        if stats.samples == 0 && elapsed > 20 {
            notified = true
            engine.emit(["ev": "notice", "code": "no_input", "msg": "아직 소리가 들어오지 않습니다."])
        } else if stats.samples > 0 && !stats.nonzero && elapsed > 20 {
            notified = true
            engine.emit(["ev": "notice", "code": "no_audio", "msg": "20초째 소리가 들어오지 않습니다."])
        }
    }

    private func handle(_ line: Line) {
        guard !closed, !(stopping && !line.final) else { return }
        lines[line.id] = line
        if line.final, !line.text.isEmpty, !written.contains(line.id) {   // first version → file now
            written.insert(line.id)
            try? handle?.write(contentsOf: "[\(fmtTime(line.start))] \(line.text)\n".data(using: .utf8)!)
        }
        engine.emit(["ev": "seg", "id": line.id, "t": (line.start * 100).rounded() / 100, "text": line.text, "final": line.final])
    }

    func finish() async {
        stopping = true
        engine.emit(["ev": "rec", "state": "finishing", "mode": mode == .live ? "live" : "file"])
        watchdog?.invalidate()
        source?.stop()
        if let t = startTask {               // 정지 during start-up: let the start finish (≤ 5 s), then stop for sure
            await waitBriefly(for: t, seconds: 5)
            source?.stop()                   // a start that ends later sees the stop and does nothing
        }
        if let t = slideTask {               // a file's slides: read the video to the end — or, after 중지, as far as was transcribed
            if !reachedEnd { slideLimit.value = Double(stats.samples) / 16000 }
            await t.value
        }
        log("session finishing")
        await recognizer.finish()
        closed = true
        // Rewrite the whole transcript in time order (English rescues may have updated lines).
        let finals = lines.values.filter { $0.final && !$0.text.isEmpty }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var text = header + "\n\n" + finals.map { "[\(fmtTime($0.start))] \($0.text)\n" }.joined()
        if let kw = engine.keywords {
            let hits = finals.filter { kw.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
            if !hits.isEmpty { text += "\n── 중요 문장 ──\n" + hits.map { "[\(fmtTime($0.start))] \($0.text)\n" }.joined() }
        }
        try? handle?.close()
        try? text.data(using: .utf8)?.write(to: txtURL, options: .atomic)
        var audio: URL?
        var seconds = Double(stats.samples) / 16000
        if let wav {
            let secs = wav.close()
            seconds = secs
            if secs > 0 { audio = await compress(wav: wav.url, seconds: secs) } else { try? FileManager.default.removeItem(at: wav.url) }
        }
        var slideCount = 0
        if let c = slides {                  // the slide PDF, next to the transcript (with what was said per slide)
            let lines = finals.map { ($0.start, $0.end, $0.text) }, txt = txtURL, end = seconds
            slideCount = await Task.detached(priority: .userInitiated) { c.makePDF(transcript: txt, lines: lines, end: end) }.value
        }
        if finals.isEmpty && seconds < 3 && slideCount == 0 {        // accidental start/stop, unreadable file: no clutter
            try? FileManager.default.removeItem(at: txtURL)
            if let a = audio { try? FileManager.default.removeItem(at: a) }
            done = true
            engine.emit(["ev": "saved", "id": "", "txt": "", "audio": "", "seconds": seconds, "count": 0])
        } else {
            done = true
            engine.emit(["ev": "saved", "id": id, "txt": txtURL.path, "audio": audio?.path ?? "",
                         "seconds": (seconds * 10).rounded() / 10, "count": finals.count, "slides": slideCount])
        }
        if let f = fileURL, f.resolvingSymlinksInPath().path
            .hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) {   // iPhone: picker's copy
            try? FileManager.default.removeItem(at: f)
        }
        engine.emit(["ev": "rec", "state": "idle", "mode": mode == .live ? "live" : "file"])
        log("session saved: \(finals.count) lines, \(fmtTime(seconds))")
    }
}

// MARK: - Crash recovery

/// Exactly the header WavWriter writes: RIFF/WAVE, 16-byte PCM fmt, mono, 16 kHz, 16-bit, data at 36.
func isOurWAV(_ url: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? h.close() }
    guard let d = try? h.read(upToCount: 44), d.count == 44 else { return false }
    func u32(_ o: Int) -> UInt32 { d[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    return d[0..<4] == Data("RIFF".utf8) && d[8..<16] == Data("WAVEfmt ".utf8) && u32(16) == 16 && u16(20) == 1
        && u16(22) == 1 && u32(24) == 16000 && u32(28) == 32000 && u16(32) == 2 && u16(34) == 16 && d[36..<40] == Data("data".utf8)
}

/// Is the transcript next to this file one the app wrote?
func hasOurTranscript(_ url: URL) -> Bool {
    let txt = url.deletingPathExtension().appendingPathExtension("txt")
    guard let h = try? FileHandle(forReadingFrom: txt) else { return false }
    defer { try? h.close() }
    guard var d = try? h.read(upToCount: 64) else { return false }
    if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }                  // byte-order mark
    return d.starts(with: Data("강의 녹취 · ".utf8)) || d.starts(with: Data("파일 받아쓰기 · ".utf8))
}

/// Moves a file out of the way, recoverably (Mac: Trash; iPhone: the app's holding folder).
private func setAside(_ url: URL) {
    let fm = FileManager.default
    #if os(macOS)
    if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { return }
    #endif
    let bin = Library.deletedDir.appendingPathComponent(UUID().uuidString)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try? fm.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
}

/// A crash leaves the half-written WAV behind: repair its header and compress it. Only the app's own
/// files are touched — a WAV with our exact header next to a transcript the app wrote — and only
/// once they've been left alone for a while. Anything else in the folder is never modified.
func recoverOrphans(in dir: URL, busy: (@Sendable (String, Bool) async -> Void)? = nil) async {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    func settled(_ u: URL) -> Bool {
        let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return Date().timeIntervalSince(m) > 15
    }
    for wav in items where wav.pathExtension.lowercased() == "wav" && settled(wav) && isOurWAV(wav) && hasOurTranscript(wav) {
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        for part in [compressPart(m4a), wav.deletingLastPathComponent().appendingPathComponent(".\(m4a.lastPathComponent).part")]
            where fm.fileExists(atPath: part.path) && settled(part) { try? fm.removeItem(at: part) }  // compress() was cut off (also 2.2's name)
        guard let h = try? FileHandle(forUpdating: wav) else { continue }
        var n = min(Int((try? h.seekToEnd()) ?? 44) - 44, WavWriter.maxDataBytes)
        n -= n % 2
        let fixed = WavWriter.header(dataBytes: n)
        try? h.seek(toOffset: 4); try? h.write(contentsOf: fixed.subdata(in: 4..<8))
        try? h.seek(toOffset: 40); try? h.write(contentsOf: fixed.subdata(in: 40..<44))
        try? h.close()
        let seconds = Double(n) / 2 / 16000
        if fm.fileExists(atPath: m4a.path) {                 // saved before, but the WAV stayed
            if let a = audioSeconds(m4a), abs(a - seconds) < 1 { try? fm.removeItem(at: wav); continue }   // our complete copy exists
            setAside(m4a)                                    // a cut-off m4a: out of the way (recoverably), redo it
        }
        let id = wav.deletingPathExtension().lastPathComponent.nfc
        await busy?(id, true)
        let out = await compress(wav: wav, seconds: seconds)
        await busy?(id, false)
        log(out.pathExtension == "m4a" ? "recovered recording from an earlier crash: \(out.lastPathComponent)"
                                       : "could not compress a recording left by a crash: \(wav.lastPathComponent)")
    }
}

// MARK: - Log (no transcript text, no user names)

private let logQueue = DispatchQueue(label: "lecture.log")
let logURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LectureScribe/logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("app.log")
}()

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        .replacingOccurrences(of: realHome.path, with: "~")
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }
}
