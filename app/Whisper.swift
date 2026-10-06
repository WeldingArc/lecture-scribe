// The optional Whisper engine for 강의 받아쓰기 v2 on the Mac (whisper.cpp, large-v3-turbo, on this Mac's GPU).
// Only the small runtime is compiled into the app: the model and its voice detector are downloaded from
// 설정 › 음성 인식, checked against their published SHA-256, and can be removed there again.
//
// The pipeline is v1's: a voice detector cuts the audio at pauses, each piece is transcribed (long ones get live
// previews), and Whisper's known failure modes are caught — phrases it invents on silence, one phrase repeated over
// and over, and an English quote translated into Korean (or the reverse) instead of written down as spoken.

#if WHISPER
import Accelerate
import AVFoundation
import CryptoKit
import Foundation

// MARK: - Model files

struct WhisperFile: Sendable {
    let name: String, url: URL, bytes: Int64, sha256: String
}

let whisperFiles = [
    WhisperFile(name: "ggml-silero-v5.1.2.bin",
                url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin")!,
                bytes: 885_098, sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"),
    WhisperFile(name: "ggml-large-v3-turbo-q5_0.bin",
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin")!,
                bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
]
let whisperBytes = whisperFiles.reduce(Int64(0)) { $0 + $1.bytes }
private let appBuildVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")"

/// Application Support/LectureScribe/Models (inside the app's container). Tests: LECTURE_MODEL_DIR.
let whisperDir: URL = env["LECTURE_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureScribe/Models")

private func whisperPath(_ f: WhisperFile) -> String { whisperDir.appendingPathComponent(f.name).path }

/// Downloads, checks and removes the model files. One download at a time; progress goes to the page.
@MainActor
final class WhisperModel: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable { case absent, downloading(Double), verifying, ready, failed(String) }
    private(set) var state: State = .absent { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// A download the user started has finished.
    var onReady: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?                   // a download cut off by the network continues where it stopped
    private var resumeIndex = -1
    private var index = 0
    private var lastReport = Date.distantPast

    override init() {
        super.init()
        if let left = try? FileManager.default.contentsOfDirectory(atPath: whisperDir.path) {   // an interrupted download
            for f in left where f.hasSuffix(".part") { try? FileManager.default.removeItem(at: whisperDir.appendingPathComponent(f)) }
        }
        state = WhisperModel.installed ? .ready : .absent
    }

    nonisolated static func complete(_ f: WhisperFile) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: whisperPath(f))[.size] as? NSNumber)?.int64Value == f.bytes
    }
    nonisolated static var installed: Bool { whisperFiles.allSatisfy(complete) }

    var downloading: Bool { task != nil }

    func download() {
        guard task == nil, state != .ready else { return }
        let need = whisperBytes + 500_000_000
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? need
        guard free >= need else {
            state = .failed("저장 공간이 부족해요. \(String(format: "%.1f", Double(need) / 1e9))GB 이상 비운 뒤 다시 해 주세요.")
            return
        }
        do { try FileManager.default.createDirectory(at: whisperDir, withIntermediateDirectories: true) } catch {
            state = .failed("모델을 저장할 폴더를 만들지 못했어요."); return
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        index = 0
        log("whisper: model download started")
        next()
    }

    private func next() {
        while index < whisperFiles.count, WhisperModel.complete(whisperFiles[index]) { index += 1 }
        guard index < whisperFiles.count, let session else { return finished() }
        let f = whisperFiles[index]
        let url = env["LECTURE_MODEL_URL"].flatMap { URL(string: $0)?.appendingPathComponent(f.name) } ?? f.url   // tests: a local server
        let t: URLSessionDownloadTask
        if let data = resumeData, resumeIndex == index { t = session.downloadTask(withResumeData: data); log("whisper: resuming the download") }
        else { t = session.downloadTask(with: url) }
        resumeData = nil
        task = t
        t.resume()
        report(0, force: true)
    }

    private func report(_ written: Int64, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReport) >= 0.25 else { return }
        lastReport = Date()
        let before = whisperFiles.prefix(index).reduce(Int64(0)) { $0 + $1.bytes }
        state = .downloading(min(0.999, Double(before + written) / Double(whisperBytes)))
    }

    private func finished() {
        session?.finishTasksAndInvalidate()
        session = nil; task = nil
        guard WhisperModel.installed else { state = .failed("모델을 내려받지 못했어요. 다시 해 주세요."); return }
        // The very first load compiles the model's GPU programs (about 40 s, once; macOS keeps them): do it now,
        // while the page still says "확인 중", so the first recording with Whisper starts at once.
        state = .verifying
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            WhisperCore.warmUp()
            log(String(format: "whisper: warmed up in %.1f s", Date().timeIntervalSince(t0)))
            await MainActor.run {
                guard self.task == nil, self.session == nil, WhisperModel.installed else { return }
                self.state = .ready
                log("whisper: model ready")
                self.onReady?()
            }
        }
    }

    private func fail(_ message: String) {
        task = nil
        session?.invalidateAndCancel(); session = nil
        state = .failed(message)
    }

    func cancel() {
        resumeData = nil
        guard task != nil else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil; session = nil
        state = WhisperModel.installed ? .ready : .absent
        log("whisper: download cancelled")
    }

    func remove() {
        cancel()
        for f in whisperFiles { try? FileManager.default.removeItem(atPath: whisperPath(f)) }
        state = .absent
        log("whisper: model removed")
    }

    /// Whisper didn't load: check the files against their checksums (in the background). Damaged or missing files are
    /// removed, so 설정 › 음성 인식 offers the download again instead of failing at every recording.
    func recheck() {
        guard state == .ready, task == nil else { return }
        Task.detached(priority: .utility) {
            let bad = whisperFiles.filter { !WhisperModel.verify(URL(fileURLWithPath: whisperPath($0)), $0) }
            let missing = bad.contains { !FileManager.default.fileExists(atPath: whisperPath($0)) }
            await MainActor.run {
                guard !bad.isEmpty else { log("whisper: the model files are intact"); return }
                guard self.state == .ready, self.task == nil else { return }
                for f in bad { try? FileManager.default.removeItem(atPath: whisperPath(f)) }
                log("whisper: removed damaged or missing files: \(bad.map(\.name).joined(separator: ", "))")
                self.state = .failed(missing ? "모델 파일이 없어졌어요. 다시 내려받아 주세요." : "모델 파일이 손상되어 지웠어요. 다시 내려받아 주세요.")
            }
        }
    }

    /// After an app update the GPU programs are compiled again on the first load (20–40 s): if Whisper is the chosen
    /// engine, do that quietly in the background once per build, so the next recording starts at once.
    func warmUpIfUpdated(selected: Bool) {
        guard selected, state == .ready, env["LECTURE_TEST_NO_WARMUP"] == nil else { return }
        let exe = Bundle.main.executableURL.map { $0.path } ?? CommandLine.arguments[0]
        let built = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "whisperWarm", stamp = "\(appBuildVersion)-\(Int(built))"
        guard UserDefaults.standard.string(forKey: key) != stamp else { return }
        Task.detached(priority: .background) {
            let t0 = Date()
            WhisperCore.warmUp()
            log(String(format: "whisper: warmed up for this build in %.1f s", Date().timeIntervalSince(t0)))
            UserDefaults.standard.set(stamp, forKey: key)
        }
    }

    /// For the page (설정 › 음성 인식).
    var info: [String: Any] {
        var d: [String: Any] = ["id": "whisper", "name": "Whisper", "model": "large-v3 turbo",
                                "desc": "OpenAI의 공개 모델을 이 Mac에서 실행해요 · Apple보다 전력을 더 써요",
                                "bytes": whisperBytes, "removable": true]
        switch state {
        case .absent: d["state"] = "absent"
        case .downloading(let p): d["state"] = "downloading"; d["progress"] = (p * 1000).rounded() / 1000
        case .verifying: d["state"] = "downloading"; d["progress"] = 1; d["verifying"] = true
        case .ready: d["state"] = "ready"
        case .failed(let m): d["state"] = "failed"; d["error"] = m
        }
        return d
    }

    // MARK: URLSession (delegate queue: main)

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        MainActor.assumeIsolated { if downloadTask === self.task { self.report(totalBytesWritten) } }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let part = whisperDir.appendingPathComponent(UUID().uuidString + ".part")     // the temporary file is gone after this returns
        let moved = (try? FileManager.default.moveItem(at: location, to: part)) != nil
        MainActor.assumeIsolated { self.received(downloadTask, part: moved ? part : nil, status: status) }
    }

    nonisolated func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard t === self.task, (error as NSError).code != NSURLErrorCancelled else { return }
            log("whisper: download failed: \(error)")
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {   // 다시 시도 continues from here
                self.resumeData = data; self.resumeIndex = self.index
            }
            self.fail((error as NSError).code == NSURLErrorNotConnectedToInternet
                      ? "인터넷에 연결되어 있지 않아요. 연결한 뒤 다시 해 주세요." : "모델을 내려받지 못했어요. 잠시 후 다시 해 주세요.")
        }
    }

    private func received(_ t: URLSessionDownloadTask, part: URL?, status: Int) {
        guard t === task, let part, status == 200 else {
            if let part { try? FileManager.default.removeItem(at: part) }
            if t === task { log("whisper: download HTTP \(status)"); fail("모델을 내려받지 못했어요. 잠시 후 다시 해 주세요.") }
            return
        }
        let f = whisperFiles[index]
        state = .verifying
        Task.detached(priority: .userInitiated) {
            let ok = WhisperModel.verify(part, f)
            await MainActor.run {
                guard t === self.task else { try? FileManager.default.removeItem(at: part); return }     // cancelled meanwhile
                guard ok else {
                    try? FileManager.default.removeItem(at: part)
                    log("whisper: \(f.name) failed its checksum")
                    self.fail("내려받은 파일이 올바르지 않아요. 다시 해 주세요."); return
                }
                try? FileManager.default.removeItem(atPath: whisperPath(f))
                do { try FileManager.default.moveItem(atPath: part.path, toPath: whisperPath(f)) } catch {
                    self.fail("모델을 저장하지 못했어요."); return
                }
                self.index += 1
                self.next()
            }
        }
    }

    nonisolated static func verify(_ url: URL, _ f: WhisperFile) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var sha = SHA256(), n: Int64 = 0
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk); n += Int64(chunk.count) }
        return n == f.bytes && sha.finalize().map { String(format: "%02x", $0) }.joined() == f.sha256
    }
}

// MARK: - Recognizer

/// Whisper's speech recognition for one session. The model loads while the first audio is already buffered,
/// so 시작 responds at once. If it can't be loaded at all (a damaged file, the GPU refusing it), Apple's recognizer
/// takes over the session with everything heard so far — the transcript never just stops.
@MainActor
final class WhisperRecognizer: SpeechRecognizer {
    var onLine: ((Line) -> Void)?
    var onError: ((Error) -> Void)?
    /// Whisper didn't load and Apple's recognizer took over (the engine then checks the model files).
    var onFallback: (() -> Void)?
    private let core: WhisperCore
    private var apple: Recognizer?
    private var takeover: Task<Void, Never>?

    init(live: Bool) { core = WhisperCore(live: live) }

    func start() async throws {
        core.deliver = { [weak self] line in DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLine?(line) } } }
        core.failed = { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.onError?(e) } } }
        core.loadFailed = { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.fallBack(e) } } }
        core.run()
    }

    nonisolated func push(_ buffer: AVAudioPCMBuffer) { core.push(buffer) }

    func finish() async {
        await offMain { $0.finish() }
        if let e = core.failure { fallBack(e) }              // failed while 정지 was pressed: the audio still gets transcribed
        await takeover?.value
        await apple?.finish()
    }

    func cancel() async {
        await offMain { $0.cancel() }
        await takeover?.value
        await apple?.cancel()
    }

    private func fallBack(_ error: Error) {
        guard takeover == nil else { return }
        let apple = Recognizer(), core = self.core
        apple.onLine = { [weak self] in self?.onLine?($0) }
        apple.onError = { [weak self] in self?.onError?($0) }
        self.apple = apple
        onFallback?()
        takeover = Task { [weak self] in
            do {
                try await apple.start()
                core.handOver { apple.push($0) }
                log("whisper: Apple's recognizer took over")
                self?.onError?(EngineError(message: "Whisper 모델을 열지 못해서 이번 녹음은 Apple 음성 인식으로 받아 적어요. 지금까지 들린 내용도 빠짐없이 받아 적어요."))
            } catch {
                core.abandon()
                self?.apple = nil
                log("whisper: Apple's recognizer couldn't take over: \(error)")
                self?.onError?(EngineError(message: "음성 인식을 시작하지 못했어요. 녹음은 계속돼요."))
            }
        }
    }

    private func offMain(_ f: @escaping @Sendable (WhisperCore) -> Void) async {
        let core = self.core
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { f(core); c.resume() }
        }
    }
}

/// How sure Whisper was of the language it detected in the last "auto" decode. Its API keeps the probability to
/// itself, so it is read from its log line ("auto-detected language: en (p = 0.504676)"); one worker thread decodes.
private let detectedP = AtomicValue()

final class AtomicValue: @unchecked Sendable {
    private let lock = NSLock(); private var v: Float = 0
    var value: Float {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// A model failed to load in this run: its half-made GPU state makes ggml's teardown abort at exit ("quit
/// unexpectedly"), so the app then leaves with `_exit` once everything is saved (main.swift `quit`).
let whisperLoadFailed = AbortFlag()

final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Phrases Whisper is known to invent on silence or noise (video outro boilerplate) — dropped only when they are
/// the whole piece. Same list as v1.
private let hallucinations = ["시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요 부탁드립니다",
                              "구독 좋아요 알림설정", "구독과 좋아요", "MBC 뉴스", "KBS 뉴스", "SBS 뉴스", "YTN 뉴스",
                              "자막 제공", "한글자막", "자막 by", "Thank you for watching", "다음 영상에서 만나요"]
    .map { $0.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }

/// Whisper's failure mode: the same phrase over and over. (start word, phrase length, repeats) or nil.
func whisperLoop(_ text: String) -> (Int, Int, Int)? {
    let w = text.split(separator: " ").map(String.init)
    for n in 1...6 {
        let need = n == 1 ? 6 : 4
        guard w.count >= n * need else { continue }
        for i in 0...(w.count - n * need) {
            var k = 1
            while i + (k + 1) * n <= w.count, Array(w[(i + k * n)..<(i + (k + 1) * n)]) == Array(w[i..<(i + n)]) { k += 1 }
            if k >= need { return (i, n, k) }
        }
    }
    return nil
}

/// Keeps two of the repeats and marks the rest with "…".
func whisperCollapse(_ text: String) -> String {
    var w = text.split(separator: " ").map(String.init)
    for _ in 0..<20 {
        guard let (i, n, k) = whisperLoop(w.joined(separator: " ")) else { break }
        w = Array(w[..<(i + 2 * n)]) + ["…"] + Array(w[(i + k * n)...])
    }
    return w.joined(separator: " ")
}

/// Everything the worker thread touches. Audio arrives on capture threads; Whisper runs on one worker thread.
private final class WhisperCore: @unchecked Sendable {
    let live: Bool
    var deliver: (Line) -> Void = { _ in }
    var failed: (Error) -> Void = { _ in }
    /// The model couldn't be loaded. The audio keeps being collected until `handOver` passes it on.
    var loadFailed: (Error) -> Void = { _ in }

    private var ctx: OpaquePointer?
    private var vad: OpaquePointer?
    private let cond = NSCondition()
    private var input: [Float] = []
    private var head = 0                       // samples of `input` already handed to the worker
    private var closing = false
    private var running = false
    private var loadError: Error?
    private var forward: ((AVAudioPCMBuffer) -> Void)?     // after a failed load: where the audio goes instead
    private let abort = AbortFlag()

    init(live: Bool) { self.live = live }

    /// Loads the model once and frees it (after a download): macOS keeps the compiled GPU programs.
    static func warmUp() {
        let core = WhisperCore(live: false)
        try? core.load()
        core.release()
    }

    func run() {
        cond.lock(); running = true; cond.unlock()
        let t = Thread { [self] in work() }
        t.stackSize = 8 << 20
        t.qualityOfService = .userInitiated
        t.name = "lecture.whisper"
        t.start()
    }

    func push(_ buf: AVAudioPCMBuffer) {
        guard let p = buf.int16ChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var f = [Float](repeating: 0, count: n)
        f.withUnsafeMutableBufferPointer { b in
            vDSP_vflt16(p, 1, b.baseAddress!, 1, vDSP_Length(n))
            var s = Float(1.0 / 32768.0)
            vDSP_vsmul(b.baseAddress!, 1, &s, b.baseAddress!, 1, vDSP_Length(n))
        }
        cond.lock()
        // A file is read far faster than Whisper listens: stay at most ~30 s ahead (memory). Live audio never waits.
        while !live, forward == nil, input.count - head > 30 * 16000, !closing, !abort.value { _ = cond.wait(until: Date() + 0.5) }
        if let sink = forward { cond.unlock(); sink(buf); return }
        defer { cond.unlock() }
        guard !closing, !abort.value else { return }
        input.append(contentsOf: f)
        cond.broadcast()
    }

    private var isClosing: Bool { cond.lock(); defer { cond.unlock() }; return closing }

    /// Why the model didn't load, if it didn't.
    var failure: Error? { cond.lock(); defer { cond.unlock() }; return loadError }

    /// After a failed load: everything heard so far, then everything that follows, goes to `sink` — in order.
    func handOver(to sink: @escaping (AVAudioPCMBuffer) -> Void) {
        cond.lock(); defer { cond.unlock() }
        var i = head
        while i < input.count {
            let n = min(16000, input.count - i)
            guard let b = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
                  let p = b.int16ChannelData?[0] else { break }
            for k in 0..<n { p[k] = Int16(max(-32768, min(32767, (input[i + k] * 32768).rounded()))) }
            b.frameLength = AVAudioFrameCount(n)
            sink(b)
            i += n
        }
        input.removeAll(); head = 0
        forward = sink
        cond.broadcast()                                      // a file reader may be waiting for room
    }

    /// Nothing will take the audio after all: stop collecting it.
    func abandon() {
        abort.value = true
        cond.lock(); input.removeAll(); head = 0; cond.broadcast(); cond.unlock()
    }

    /// Transcribe what's left, then free the model (≤ 3 minutes, even if Whisper gets stuck).
    func finish() {
        cond.lock()
        closing = true
        cond.broadcast()
        let deadline = Date() + 180
        while running, Date() < deadline { _ = cond.wait(until: min(deadline, Date() + 1)) }
        let stuck = running
        cond.unlock()
        if stuck { log("whisper: still busy after 3 minutes; stopping"); stop() } else { release() }
    }

    func cancel() { stop() }

    private func stop() {
        abort.value = true
        cond.lock()
        closing = true
        cond.broadcast()
        let deadline = Date() + 15
        while running, Date() < deadline { _ = cond.wait(until: min(deadline, Date() + 1)) }
        cond.unlock()
        release()
    }

    private func release() {
        cond.lock(); defer { cond.unlock() }
        guard !running else { return }                        // never free under a running decode
        if let v = vad { whisper_vad_free(v); vad = nil }
        if let c = ctx { whisper_free(c); ctx = nil }
    }

    // MARK: worker

    private func load() throws {
        whisper_log_set({ level, text, _ in                    // whisper.cpp is chatty: warnings and errors only
            guard let text else { return }
            if strstr(text, "auto-detected language:") != nil, let at = strstr(text, "(p = ") {
                detectedP.value = Float(String(cString: at + 5).prefix { "0123456789.".contains($0) }) ?? 0
            }
            guard level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR || env["LECTURE_DEBUG"] == "1" else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { log("whisper: " + line) }
        }, nil)
        let t0 = Date()
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true                                   // measured: ~20% faster on an M2
        guard let c = whisper_init_from_file_with_params(whisperPath(whisperFiles[1]), cp) else {
            throw EngineError(message: "the model didn't load")
        }
        var vp = whisper_vad_default_context_params()
        vp.n_threads = 1
        vp.use_gpu = false
        guard let v = whisper_vad_init_from_file_with_params(whisperPath(whisperFiles[0]), vp) else {
            whisper_free(c)
            throw EngineError(message: "the voice detector didn't load")
        }
        ctx = c; vad = v
        log(String(format: "whisper: model loaded in %.1f s · ", Date().timeIntervalSince(t0)) + String(cString: whisper_print_system_info()))
    }

    private func work() {
        let slow = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosing else { return }
            self.failed(EngineError(message: "Whisper를 준비하는 중이에요. 처음 한 번은 1분쯤 걸려요 — 그동안에도 녹음은 계속되고, 준비되면 이어서 받아 적어요."))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: slow)
        defer { slow.cancel() }
        do { try load(); slow.cancel() } catch {
            slow.cancel()
            whisperLoadFailed.value = true
            log("whisper: \(error)")
            cond.lock(); loadError = error; running = false; cond.broadcast(); cond.unlock()
            loadFailed(error)                                 // the audio waits for Apple's recognizer
            return
        }
        let window = 512
        var ending = false
        while !ending, !abort.value {
            cond.lock()
            while input.count - head < window, !closing, !abort.value { cond.wait() }
            if abort.value { cond.unlock(); break }
            let available = input.count - head
            let take = closing ? available : min(available / window * window, 2 * 16000)    // ≤ 2 s at a time
            let chunk = Array(input[head..<(head + take)])
            head += take
            if head > 60 * 16000 { input.removeFirst(head); head = 0 }
            ending = closing && head == input.count
            cond.broadcast()                                  // a file reader may be waiting for room
            cond.unlock()
            listen(chunk)
        }
        if ending, !abort.value { flush() }
        cond.lock(); running = false; cond.broadcast(); cond.unlock()
    }

    /// Seconds of audio waiting for the worker. Live, Whisper may fall behind on a busy or slow Mac; then it skips
    /// previews and the extra language check until it has caught up (v1: previews only when the GPU is idle).
    private var backlog: Double {
        cond.lock(); defer { cond.unlock() }
        return Double(input.count - head) / 16000
    }

    private func listen(_ samples: [Float]) {
        guard !samples.isEmpty, let vad else { return }
        var s = samples
        if s.count % 512 != 0 { s += [Float](repeating: 0, count: 512 - s.count % 512) }
        let ok = s.withUnsafeBufferPointer { whisper_vad_detect_speech_no_reset(vad, $0.baseAddress, Int32($0.count)) }
        let n = Int(whisper_vad_n_probs(vad))
        guard ok, n == s.count / 512, let probs = whisper_vad_probs(vad) else { log("whisper: voice detector failed"); return }
        for i in 0..<n { feed(s[(i * 512)..<((i + 1) * 512)], probs[i]) }
    }

    // v1's segmenter: groups 32 ms voice-detector frames into utterances, cut at pauses. Short phrases wait for a
    // longer pause (more context = better accuracy), long ones cut at shorter pauses; anything reaching 22 s is cut
    // at the quietest moment of its last 5 seconds.
    private let frameSec = 0.032
    private let startP: Float = 0.5, endP: Float = 0.35
    private let preFrames = 15, tailFrames = 9, maxSec = 22.0, minSpeechSec = 0.25
    private var pre: [Float] = []
    private var pos = 0
    private var active = false
    private var seg: [Float] = []
    private var probs: [Float] = []
    private var segStart = 0
    private var silence = 0
    private var lastPreview = 0.0
    private var nextID = 1, curID = 0, previewed = 0

    private func feed(_ frame: ArraySlice<Float>, _ p: Float) {
        defer { pos += 1 }
        if !active {
            pre.append(contentsOf: frame)
            if pre.count > preFrames * 512 { pre.removeFirst(pre.count - preFrames * 512) }
            guard p >= startP else { return }
            active = true
            seg = pre
            probs = [Float](repeating: 0, count: pre.count / 512 - 1) + [p]
            segStart = pos - pre.count / 512 + 1
            silence = 0; lastPreview = 0
            curID = nextID; nextID += 1
            pre.removeAll(keepingCapacity: true)
            return
        }
        seg.append(contentsOf: frame)
        probs.append(p)
        silence = p < endP ? silence + 1 : 0
        let length = Double(probs.count) * frameSec
        let need = length < 4 ? 1.2 : (length < 12 ? 0.6 : 0.3)
        if Double(silence) * frameSec >= need {
            let cut = probs.count - silence + min(silence, tailFrames)
            let after = Array(seg[(cut * 512)...])
            close(cut)
            active = false
            seg.removeAll(); probs.removeAll()
            pre = Array(after.suffix(preFrames * 512))        // pure silence: a safe pre-roll for the next utterance
        } else if length >= maxSec {
            let look = Int(5.0 / frameSec)
            var k = probs.count - look, best = Float.infinity
            for i in (probs.count - look)..<probs.count where probs[i] < best { best = probs[i]; k = i }
            k = max(k, 1)
            let restAudio = Array(seg[(k * 512)...]), restProbs = Array(probs[k...])
            close(k)
            seg = restAudio; probs = restProbs
            segStart += k
            silence = 0; lastPreview = 0
            curID = nextID; nextID += 1
        } else if live, length >= 3, length - lastPreview >= 4, backlog < 1 {
            let text = transcribe(seg, final: false)
            if !text.isEmpty { previewed = curID; deliver(Line(id: curID, start: Double(segStart) * frameSec, text: text, final: false)) }
            lastPreview = length
        }
    }

    private func close(_ cut: Int) {
        let start = Double(segStart) * frameSec
        let spoken = Double(probs.prefix(cut).filter { $0 >= startP }.count) * frameSec
        let text = spoken >= minSpeechSec ? transcribe(Array(seg.prefix(cut * 512)), final: true, voice: Array(probs.prefix(cut))) : ""
        if !text.isEmpty || previewed == curID {               // empty: withdraw the preview, if one was shown
            deliver(Line(id: curID, start: start, text: text, final: true, end: start + Double(cut) * frameSec))
        }
    }

    private func flush() {
        if active, !probs.isEmpty { close(probs.count) }
        active = false
        seg.removeAll(); probs.removeAll()
    }

    // MARK: decoding

    private struct Result {
        var text: String; var conf: Double; var lang: String; var parts: [(t0: Double, t1: Double, text: String)] = []
        var sure: Float = 1                                     // "auto": how sure Whisper was of `lang`
    }

    /// Korean or English, written down as spoken (never translated) — v1's rule: long finals detect their language;
    /// if that differs from the lecture's (Korean), the piece is decoded both ways and the more confident reading
    /// wins, so an English quote stays English and a misheard Korean sentence can't turn into an English translation.
    private func transcribe(_ pcm: [Float], final: Bool, voice: [Float] = []) -> String {
        let major = "ko"
        let behind = live ? backlog : 0
        var r: Result
        if final, Double(pcm.count) / 16000 >= 2.5, behind < 3 {
            r = decode(pcm, language: "auto", beam: 5)
            if r.lang != "ko", r.lang != "en" {
                r = decode(pcm, language: major, beam: 5); r.lang = major
            } else if r.lang != major {
                let m = decode(pcm, language: major, beam: 5)
                if m.conf >= r.conf { r = m; r.lang = major }
            }
        } else {
            r = decode(pcm, language: major, beam: final && behind < 8 ? 5 : 1); r.lang = major
            // A short piece may be an English quote ("Less is more."). If the Korean pass wrote it in English anyway, read it
            // again as English (the Korean pass drops or capitalises its words: "STAY HUNGRY"). If Korean can't make sense
            // of it, it becomes English only when Whisper itself identifies the speech as English: forced into English,
            // unclear Korean comes out as invented English ("잠깐만요" → "I'm done with you").
            if final, behind < 8, Double(pcm.count) / 16000 >= 0.6 {
                if latin(r.text) {
                    let e = decode(pcm, language: "en", beam: 5)
                    if latin(e.text), e.conf > -0.9 { r = e; r.lang = "en" }
                } else if r.text.isEmpty || r.conf < -0.8 {
                    let a = decode(pcm, language: "auto", beam: 5)
                    if a.lang == "en", a.sure >= 0.9, latin(a.text), a.conf > -0.9 { r = a }
                }
            }
        }
        if final, !r.text.isEmpty, whisperLoop(r.text) != nil {      // the repetition failure: one more try, other language
            let other = r.lang == "ko" ? "en" : "ko"
            let r2 = decode(pcm, language: other, beam: 5)
            if !r2.text.isEmpty, whisperLoop(r2.text) == nil, r2.conf > r.conf { r = r2; r.lang = other }
        }
        if final, behind < 3, !voice.isEmpty { r = rescue(pcm, voice, r) }
        if whisperLoop(r.text) != nil { log("whisper: collapsing a repeated phrase"); r.text = whisperCollapse(r.text) }
        return r.text
    }

    /// Mostly Latin letters (English), not Hangul.
    private func latin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && Double(letters.filter { $0.isASCII }.count) >= 0.8 * Double(letters.count)
    }

    /// Speech the voice detector heard but no part of the transcript covers — typically a short English quote inside a
    /// mostly Korean piece, which Whisper leaves out. Each such utterance is decoded again with Whisper's own language
    /// identification and put in, in time order: English when Whisper identifies it as English (a reading forced into
    /// another language would be a translation), Korean only where Whisper's own timing shows a gap. Nothing the
    /// transcript already has is put in twice.
    private func rescue(_ pcm: [Float], _ voice: [Float], _ r: Result) -> Result {
        guard !r.parts.isEmpty else { return r }
        let frame = 0.032, dur = Double(pcm.count) / 16000
        // Whisper's segment times stretch over speech it left out (a segment "starts" where the previous one ended, the
        // first at 0:00): estimate where each segment's speech really began from its length (a wrong guess only costs a
        // check).
        let raw = r.parts
        var parts = r.parts
        for k in parts.indices { parts[k].t0 = max(parts[k].t0, parts[k].t1 - spokenLength(parts[k].text, rate: k == 0 ? 6 : 5)) }
        func covered(_ t: Double) -> Bool { parts.contains { t >= $0.t0 - 0.2 && t <= $0.t1 + 0.25 } }
        var runs: [(Int, Int)] = [], start: Int?, quiet = 0
        for (i, p) in voice.enumerated() {
            if p >= 0.5 && !covered(Double(i) * frame) { if start == nil { start = i }; quiet = 0 }
            else if let s0 = start { quiet += 1; if quiet > 4 { runs.append((s0, i - quiet)); start = nil; quiet = 0 } }
        }
        if let s0 = start { runs.append((s0, voice.count - 1)) }
        // the whole utterance around each uncovered stretch (to the pauses on either side), so no word is cut in half
        func edge(_ i: Int, _ step: Int) -> Int {
            var k = i, q = 0
            while k + step >= 0, k + step < voice.count, q <= 4 { k += step; q = voice[k] >= 0.5 ? 0 : q + 1 }
            return k - step * q
        }
        var added = false
        for (a, b) in runs.filter({ Double($0.1 - $0.0 + 1) * frame >= 0.6 }).prefix(3) {
            let lo = Int(max(0, Double(edge(a, -1)) * frame - 0.2) * 16000), hi = Int(min(dur, Double(edge(b, 1) + 1) * frame + 0.25) * 16000)
            guard hi - lo >= 9600 else { continue }
            let t0 = Double(lo) / 16000, t1 = Double(hi) / 16000
            let around = raw.filter { $0.t1 > t0 && $0.t0 < t1 }
            // a Korean segment there with English words in it heard this speech, if poorly: nothing was left out
            if r.lang != "en", around.contains(where: { latinWord($0.text) }) { continue }
            if env["LECTURE_DEBUG"] == "1" { log(String(format: "whisper: checking %.1f–%.1f s for left-out speech", t0, t1)) }
            let x = decode(Array(pcm[lo..<hi]), language: "auto", beam: 5)
            guard !x.text.isEmpty, x.conf > -0.9, !similar(x.text, r.text) else { continue }
            // English only when Whisper is sure it is English: real quotes measure 0.98–1.00, while Korean it already has
            // (a slow speaker makes the guess of where a segment began too late) misidentified as English measures
            // 0.24–0.62 and comes out as invented English ("여러분," → "You're a good one.")
            let english = x.lang == "en" && x.sure >= 0.9 && latin(x.text)
            let korean = x.lang == "ko" && !latin(x.text) && around.isEmpty         // a gap in Whisper's own timing
            guard english || korean else { continue }
            parts.append((t0 - 0.01, t1, x.text))                                    // before what follows it
            added = true
            log("whisper: put back speech the transcript had left out")
        }
        guard added else { return r }
        var out = r
        out.parts = parts.sorted { $0.t0 < $1.t0 }
        out.text = clean(out.parts.map(\.text).joined(separator: " "))
        return out
    }

    /// Roughly how long `text` takes to say (`rate` syllables, half as many English words or 4 digits a second).
    private func spokenLength(_ text: String, rate: Double = 6) -> Double {
        var syllables = 0, digits = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0xAC00...0xD7A3, 0x3040...0x30FF, 0x4E00...0x9FFF: syllables += 1     // Hangul, kana, CJK (Whisper writes those too)
            case 0x30...0x39: digits += 1
            default: break
            }
        }
        return Double(syllables) / rate + Double(latinRuns(text).count) / (rate / 2) + Double(digits) / 4 + 0.2
    }

    /// The English words in `text`, also where a Korean particle is attached ("cost입니다").
    private func latinRuns(_ text: String) -> [String] {
        var runs: [String] = [], run = ""
        for ch in text + " " {
            if ch.isASCII && ch.isLetter { run.append(ch) } else if !run.isEmpty { runs.append(run); run = "" }
        }
        return runs
    }

    /// An English word (four letters or more, not an acronym like "GDP").
    private func latinWord(_ text: String) -> Bool {
        latinRuns(text).contains { $0.count >= 4 && $0.contains { $0.isLowercase } }
    }

    /// Most of `a` (its letter pairs) already appears in `b`.
    private func similar(_ a: String, _ b: String) -> Bool {
        func pairs(_ s: String) -> [String] {
            let c = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
            return c.count < 2 ? c.map(String.init) : (0..<(c.count - 1)).map { String(c[$0...$0 + 1]) }
        }
        let pa = pairs(a), pb = Set(pairs(b))
        return !pa.isEmpty && Double(pa.filter(pb.contains).count) >= 0.6 * Double(pa.count)
    }

    private func decode(_ pcm: [Float], language: String, beam: Int) -> Result {
        guard let ctx, !abort.value, !pcm.isEmpty else { return Result(text: "", conf: -9, lang: language) }
        var p = whisper_full_default_params(beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        p.n_threads = 4
        p.no_context = true
        p.print_progress = false; p.print_realtime = false; p.print_timestamps = false; p.print_special = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.temperature = 0
        p.temperature_inc = 0.2
        p.no_speech_thold = 0.6
        p.beam_search.beam_size = Int32(beam)
        p.greedy.best_of = 1
        p.abort_callback = { data in data.map { Unmanaged<AbortFlag>.fromOpaque($0).takeUnretainedValue().value } ?? false }
        p.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        let t0 = Date()
        detectedP.value = language == "auto" ? 0 : 1
        let rc: Int32 = language.withCString { lang in
            p.language = lang
            return pcm.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
        let took = Date().timeIntervalSince(t0)
        guard rc == 0 else {
            if !abort.value { log("whisper: decode failed (\(rc))") }
            return Result(text: "", conf: -9, lang: language)
        }
        let eot = whisper_token_eot(ctx)
        var kept: [String] = [], sum = 0.0, count = 0, parts: [(t0: Double, t1: Double, text: String)] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            let t = String(cString: whisper_full_get_segment_text(ctx, i)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            var s = 0.0, n = 0
            for j in 0..<whisper_full_n_tokens(ctx, i) {
                let d = whisper_full_get_token_data(ctx, i, j)
                if d.id < eot { s += Double(d.plog); n += 1 }
            }
            let avg = n > 0 ? s / Double(n) : 0
            if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.6, avg < -1.0 { continue }      // no speech after all
            kept.append(t); sum += s; count += n
            parts.append((Double(whisper_full_get_segment_t0(ctx, i)) / 100, Double(whisper_full_get_segment_t1(ctx, i)) / 100, t))
        }
        let lang = String(cString: whisper_lang_str(whisper_full_lang_id(ctx)))
        let text = clean(kept.joined(separator: " "))
        let conf = count > 0 ? sum / Double(count) : -9                              // nothing kept: the least confident
        if env["LECTURE_DEBUG"] == "1" {
            log(String(format: "whisper: decoded %.1f s of audio in %.2f s (%@ → %@, beam %d, conf %.2f): %@", Double(pcm.count) / 16000, took,
                       language, lang, beam, conf, String(text.prefix(60))))
        }
        return Result(text: text, conf: conf, lang: lang, parts: text.isEmpty ? [] : parts, sure: detectedP.value)
    }

    private func clean(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let norm = t.replacingOccurrences(of: "[\\s.,!?…·\\-~]+", with: "", options: .regularExpression)
        guard !norm.isEmpty else { return "" }
        for h in hallucinations where norm.hasPrefix(h) && norm.count <= h.count + 8 {
            log("whisper: dropped a known hallucination")
            return ""
        }
        return t
    }
}
#endif
