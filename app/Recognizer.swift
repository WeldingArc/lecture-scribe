// Apple's on-device speech recognition (SpeechAnalyzer, macOS 26+) for 강의 받아쓰기 v2.
//
// Two transcribers listen to the same audio:
//   • Korean (ko-KR) — the transcript, plus live "volatile" previews.
//   • English (en-US) — only to rescue English quotes. The Korean model turns English speech into
//     low-confidence Latin gibberish ("Ht snot teve…") or skips it; where that happens and the English
//     model is confident, its words are spliced in at the right moment. Nothing is ever translated.

import AVFoundation
import Foundation
import Speech

struct Token {
    let start: Double, end: Double, conf: Double, text: String
    var hangul: Bool { text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) } }
    var latinOnly: Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy { $0.isASCII }
    }
}

/// One line of transcript as the UI and the files see it.
struct Line {
    let id: Int
    var start: Double
    var text: String
    var final: Bool
    var end: Double = 0            // when the line's speech ended (0 = unknown)
}

/// A speech-to-text engine for one session. Apple's (`Recognizer`) is built in; others — Whisper on the Mac — are
/// optional downloads (설정 › 음성 인식). Every engine gets the same 16 kHz mono Int16 audio and reports `Line`s:
/// previews (final: false) replaced by finals with the same id; a final with empty text withdraws a preview.
@MainActor
protocol SpeechRecognizer: AnyObject {
    var onLine: ((Line) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start() async throws
    /// Any thread.
    nonisolated func push(_ buffer: AVAudioPCMBuffer)
    /// Transcribes whatever is still waiting, then returns (never hangs forever).
    func finish() async
    func cancel() async
}

/// A problem worth showing the user as it is.
struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class Recognizer: SpeechRecognizer {
    var onLine: ((Line) -> Void)?
    var onError: ((Error) -> Void)?

    private let ko: SpeechTranscriber
    private let en: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    /// Audio arrives on capture threads; AsyncStream continuations are thread-safe.
    private final class Input: @unchecked Sendable {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        private let lock = NSLock()
        private var _fed = false
        var fed: Bool { lock.lock(); defer { lock.unlock() }; return _fed }
        func markFed() { lock.lock(); _fed = true; lock.unlock() }
    }
    private let input = Input()
    private var readers: [Task<Void, Never>] = []

    private struct KoFinal { let id: Int; let start: Double; let end: Double; var tokens: [Token]; let raw: String }
    private struct Phrase { var tokens: [Token]; var start: Double { tokens.first!.start }; var end: Double { tokens.last!.end } }
    private var nextID = 1
    private var volatileID: Int?
    private var koFinals: [KoFinal] = []
    private var koFinalizedThrough: Double = 0
    private var pendingEnglish: [Phrase] = []
    private var ownLines: [Int: Line] = [:]          // English phrases that fell between Korean lines

    static func transcribers() -> (SpeechTranscriber, SpeechTranscriber) {
        (SpeechTranscriber(locale: Locale(identifier: "ko-KR"), transcriptionOptions: [],
                           reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange, .transcriptionConfidence]),
         SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                           reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence]))
    }

    /// Makes sure the Korean and English speech models are on this Mac (macOS downloads them once).
    static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let (ko, en) = transcribers()
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == "ko-KR" }) else {
            throw NSError(domain: "LectureScribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "이 기기에서 한국어 음성 인식을 지원하지 않아요."])
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [ko, en]) {
            let watcher = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }
    }

    init() {
        (ko, en) = Recognizer.transcribers()
        analyzer = SpeechAnalyzer(modules: [ko, en])
    }

    func start() async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input.continuation = continuation
        try await analyzer.start(inputSequence: stream)
        let (ko, en) = (self.ko, self.en)
        readers = [
            Task { [weak self] in
                do { for try await r in ko.results { self?.korean(r) } } catch { self?.onError?(error) }
            },
            Task { [weak self] in
                do { for try await r in en.results { self?.english(r) } } catch { self?.onError?(error) }
            },
        ]
    }

    private func tokens(_ text: AttributedString) -> [Token] {
        text.runs.compactMap { run in
            let s = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, let tr = run.audioTimeRange else { return nil }
            return Token(start: tr.start.seconds, end: tr.end.seconds, conf: run.transcriptionConfidence ?? 1, text: s)
        }
    }

    // MARK: Korean

    private func korean(_ r: SpeechTranscriber.Result) {
        let raw = String(r.text.characters).trimmingCharacters(in: .whitespaces)
        if !r.isFinal {
            guard !raw.isEmpty else { return }
            let id = volatileID ?? { let i = nextID; nextID += 1; volatileID = i; return i }()
            onLine?(Line(id: id, start: r.range.start.seconds, text: raw, final: false))
            return
        }
        let id = volatileID ?? { let i = nextID; nextID += 1; return i }()
        volatileID = nil
        let toks = tokens(r.text)
        let seg = KoFinal(id: id, start: r.range.start.seconds, end: r.range.end.seconds, tokens: toks, raw: raw)
        koFinals.append(seg)
        koFinalizedThrough = max(koFinalizedThrough, seg.end)
        emitKorean(seg)
        placeEnglish(final: false)
    }

    /// Korean line text: Apple's own text unless gibberish has to go or English is spliced in.
    private func render(_ seg: KoFinal) -> String {
        let garbage = seg.tokens.filter { $0.latinOnly && $0.conf < 0.6 }
        let inside = acceptedInside(seg)
        if garbage.isEmpty && inside.isEmpty { return seg.raw }
        var all = seg.tokens.filter { !($0.latinOnly && $0.conf < 0.6) }
        all += inside.flatMap { $0.tokens }
        return join(all.sorted { $0.start < $1.start })
    }

    /// Words joined by spaces; punctuation sticks to the word before it and is never doubled.
    private func join(_ tokens: [Token]) -> String {
        let punct = CharacterSet.punctuationCharacters.union(.symbols)
        var out = ""
        for t in tokens {
            if t.text.unicodeScalars.allSatisfy({ punct.contains($0) }) {
                guard let last = out.unicodeScalars.last, !punct.contains(last) else { continue }
                out += t.text
            } else {
                out += (out.isEmpty ? "" : " ") + t.text
            }
        }
        return out
    }

    private func emitKorean(_ seg: KoFinal) {
        let text = render(seg)
        onLine?(Line(id: seg.id, start: seg.start, text: text, final: true, end: seg.end))
    }

    // MARK: English rescue

    private var accepted: [Phrase] = []

    private func acceptedInside(_ seg: KoFinal) -> [Phrase] {
        accepted.filter { p in let mid = (p.start + p.end) / 2; return mid >= seg.start && mid <= seg.end }
    }

    private func english(_ r: SpeechTranscriber.Result) {
        guard r.isFinal else { return }
        var phrase: [Token] = []
        func flush() { if !phrase.isEmpty { pendingEnglish.append(Phrase(tokens: phrase)); phrase = [] } }
        for t in tokens(r.text) {
            if let last = phrase.last, t.start - last.end > 0.7 { flush() }
            phrase.append(t)
        }
        flush()
        placeEnglish(final: false)
    }

    /// Accept English phrases once Korean has been finalized past them (or at the very end).
    private func placeEnglish(final: Bool) {
        var keep: [Phrase] = []
        for p in pendingEnglish {
            guard final || koFinalizedThrough >= p.end + 0.3 else { keep.append(p); continue }
            guard let ok = vetted(p) else { continue }
            accepted.append(ok)
            let mid = (ok.start + ok.end) / 2
            if let seg = koFinals.first(where: { mid >= $0.start && mid <= $0.end }) {
                emitKorean(seg)                                   // re-render with the English inside
            } else {
                let id = nextID; nextID += 1
                let line = Line(id: id, start: ok.start, text: join(ok.tokens), final: true, end: ok.end)
                ownLines[id] = line
                onLine?(line)
            }
        }
        pendingEnglish = keep
    }

    /// A real English quote: ≥ 3 words, confident on average, and not on top of Korean speech.
    private func vetted(_ p: Phrase) -> Phrase? {
        let r = vettedCore(p)
        if env["LECTURE_DEBUG"] == "1" {
            FileHandle.standardError.write("EN phrase \(String(format: "%.2f-%.2f", p.start, p.end)) [\(p.tokens.map { "\($0.text)(\(String(format: "%.2f", $0.conf)))" }.joined(separator: " "))] → \(r == nil ? "rejected" : "accepted")\n".data(using: .utf8)!)
        }
        if env["LECTURE_DEBUG"] == "1" {
            let near = koFinals.flatMap(\.tokens).filter { $0.end > p.start - 0.5 && $0.start < p.end + 0.5 }
            FileHandle.standardError.write("   korean nearby: \(near.map { "\($0.text)[\(String(format: "%.2f-%.2f c%.2f", $0.start, $0.end, $0.conf))]" }.joined(separator: " "))\n".data(using: .utf8)!)
        }
        return r
    }

    private func vettedCore(_ p: Phrase) -> Phrase? {
        let solidKorean = koFinals.flatMap(\.tokens).filter { $0.hangul && $0.conf >= 0.5 }
        // seconds of a word that Korean speech actually covers (word edges jitter by tens of ms)
        func overlap(_ t: Token) -> Double {
            min(t.end - t.start, solidKorean.reduce(0) { $0 + max(0, min($1.end, t.end) - max($1.start, t.start)) })
        }
        let dur = max(0.01, p.end - p.start)
        let covered = p.tokens.reduce(0) { $0 + overlap($1) }
        let kept = p.tokens.filter { overlap($0) < 0.4 * ($0.end - $0.start) }
        let mean = kept.isEmpty ? 0 : kept.map(\.conf).reduce(0, +) / Double(kept.count)
        if env["LECTURE_DEBUG"] == "1" {
            FileHandle.standardError.write("   covered=\(String(format: "%.2f", covered))/\(String(format: "%.2f", dur)) kept=\(kept.count) mean=\(String(format: "%.3f", mean)) times=\(p.tokens.map { String(format: "%.2f-%.2f", $0.start, $0.end) })\n".data(using: .utf8)!)
        }
        guard covered / dur < 0.25 else { return nil }
        guard kept.count >= 3 else { return nil }
        guard mean >= 0.45 else { return nil }
        return Phrase(tokens: kept)
    }

    // MARK: Lifecycle

    /// Any thread.
    nonisolated func push(_ buffer: AVAudioPCMBuffer) {
        guard let c = input.continuation else { return }
        if case .enqueued = c.yield(AnalyzerInput(buffer: buffer)) { input.markFed() }   // not after the stream closed
    }

    /// Flush everything the recognizers still hold and wait for their last results — but never forever:
    /// with no audio at all the result streams would never end (stop before any sound, unreadable file).
    func finish() async {
        input.continuation?.finish()
        let analyzer = self.analyzer, readers = self.readers
        if input.fed {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        } else {
            await analyzer.cancelAndFinishNow()
            readers.forEach { $0.cancel() }               // nothing was heard: no results to wait for
        }
        // The backstop starts only now: finalizing a long imported file can legitimately take a while.
        let limit = Task {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }
            log("recognizer: results did not end, giving up waiting")
            await analyzer.cancelAndFinishNow()
            readers.forEach { $0.cancel() }
        }
        for r in readers { _ = await r.value }
        limit.cancel()
        placeEnglish(final: true)
    }

    func cancel() async {
        input.continuation?.finish()
        await analyzer.cancelAndFinishNow()
        readers.forEach { $0.cancel() }
    }
}
