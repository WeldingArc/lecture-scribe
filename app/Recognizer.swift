// Apple's on-device speech recognition (SpeechAnalyzer, macOS 26+) for 강의 받아쓰기 v2.
//
// Two transcribers listen to the same audio. For a Korean lecture (강의 언어: 한국어, the default):
//   • Korean (ko-KR) — the transcript, plus live "volatile" previews.
//   • English (en-US) — only to rescue English quotes. The Korean model turns English speech into
//     low-confidence Latin gibberish ("Ht snot teve…") or skips it; where that happens and the English
//     model is confident, its words are spliced in at the right moment. Nothing is ever translated.
// For an English lecture (강의 언어: English) the roles swap: English writes the transcript and the previews, and a
// Korean aside replaces the English model's guess only where Korean is confident Hangul and English was unsure.

import AVFoundation
import Foundation
import Speech

struct Token {
    let start: Double, end: Double, conf: Double, text: String
    var index = -1                 // position in its result (the main model's tokens), -1 for the other model's
    var glued = false              // written right after the token before it, with no space ("마" + "이" = "마이")
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

    private let main: SpeechTranscriber              // writes the transcript (Korean, or English for an English lecture)
    private let aside: SpeechTranscriber             // rescues the other language
    private let mainIsKorean: Bool
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

    /// (main, aside): the main language gets live previews.
    static func transcribers(mainIsKorean: Bool = true) -> (SpeechTranscriber, SpeechTranscriber) {
        func make(_ id: String, previews: Bool) -> SpeechTranscriber {
            SpeechTranscriber(locale: Locale(identifier: id), transcriptionOptions: [],
                              reportingOptions: previews ? [.volatileResults] : [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
        return mainIsKorean ? (make("ko-KR", previews: true), make("en-US", previews: false))
                            : (make("en-US", previews: true), make("ko-KR", previews: false))
    }

    /// Makes sure the Korean and English speech models are on this Mac (macOS downloads them once).
    static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let (ko, en) = transcribers()
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == "ko-KR" }) else {
            throw NSError(domain: "LectureScribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "이 기기에서 한국어 음성 인식을 지원하지 않습니다."])
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

    /// `main`: the lecture's language, "ko" (default) or "en".
    init(main language: String = "ko") {
        mainIsKorean = language != "en"
        (main, aside) = Recognizer.transcribers(mainIsKorean: mainIsKorean)
        analyzer = SpeechAnalyzer(modules: [main, aside])
    }

    func start() async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input.continuation = continuation
        try await analyzer.start(inputSequence: stream)
        let (main, aside) = (self.main, self.aside)
        readers = [
            Task { [weak self] in
                do { for try await r in main.results { self?.korean(r) } } catch { self?.onError?(error) }
            },
            Task { [weak self] in
                do { for try await r in aside.results { self?.english(r) } } catch { self?.onError?(error) }
            },
        ]
    }

    private func tokens(_ text: AttributedString) -> [Token] {
        var out: [Token] = [], spaceBefore = true
        for run in text.runs {
            let raw = String(text[run.range].characters)
            let s = raw.trimmingCharacters(in: .whitespaces)
            defer { spaceBefore = raw.last?.isWhitespace ?? spaceBefore }
            guard !s.isEmpty, let tr = run.audioTimeRange else { if !raw.isEmpty { spaceBefore = true }; continue }
            out.append(Token(start: tr.start.seconds, end: tr.end.seconds, conf: run.transcriptionConfidence ?? 1, text: s,
                             index: out.count, glued: !spaceBefore && !(raw.first?.isWhitespace ?? false)))
        }
        return out
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
        if env["LECTURE_DEBUG"] == "1" { FileHandle.standardError.write("KORAW \(id) \(raw)\n".data(using: .utf8)!) }
        let toks = tokens(r.text)
        let seg = KoFinal(id: id, start: r.range.start.seconds, end: r.range.end.seconds, tokens: toks, raw: raw)
        koFinals.append(seg)
        koFinalizedThrough = max(koFinalizedThrough, seg.end)
        emitKorean(seg)
        placeEnglish(final: false)
    }

    /// Korean line text: Apple's own text unless gibberish has to go or English is spliced in.
    private func render(_ seg: KoFinal) -> String {
        let inside = acceptedInside(seg)
        // The main model's own try at words the other model wrote down goes — also under a phrase that sits on the
        // neighbouring line. (A Korean lecture's model writes accented English as confident Latin words; kept next to
        // the English rescue they doubled every word: "welcome welcome back. back.")
        let near = accepted.filter { $0.end + 1 > seg.start && $0.start - 1 < seg.end }
        let guessed = seg.tokens.filter { guess($0, near) }
        if !mainIsKorean {
            // English lecture: under a Korean aside on this line the English model's words go, as before; under one on a
            // neighbouring line only its unsure ones (< 0.5) — an aside the Korean model ended with "…굿 땡큐." must not
            // take "Good question." and "Thank you." with it; barely heard words (< 0.3) touching an aside go too
            // ("Yeah(0.09)" before "자 여기까지 이해되셨나요?")
            func goes(_ t: Token) -> Bool {
                inside.contains { mostly(t, under: $0) }
                    || near.contains { (t.conf < 0.5 && mostly(t, under: $0)) || (t.conf < 0.3 && mostly(t, under: $0, pad: guessPad, any: true)) }
            }
            let english = seg.tokens.filter { !goes($0) }
            guard !inside.isEmpty || english.count != seg.tokens.count else { return seg.raw }
            return join((english + inside.flatMap { $0.tokens }).sorted { $0.start < $1.start })
        }
        let garbage = seg.tokens.filter { $0.latinOnly && $0.conf < 0.6 }
        if garbage.isEmpty && inside.isEmpty && guessed.isEmpty { return seg.raw }
        // Its Latin words for a quote drift up to a second or more from the English model's ("The" 4.08–5.10 for "The"
        // at 5.34): a run of them that touches the quote goes as a whole, as far as 1.5 s beyond the quote's edges.
        let toks = seg.tokens
        var dropped = Set(toks.indices.filter { guess(toks[$0], near) })
        var i = 0
        while i < toks.count {
            guard !toks[i].hangul else { i += 1; continue }
            var j = i
            while j < toks.count, !toks[j].hangul { j += 1 }
            for p in near where (i..<j).contains(where: { dropped.contains($0) && guess(toks[$0], [p]) }) {
                for k in i..<j where toks[k].end > p.start - 1.5 && toks[k].start < p.end + 1.5 { dropped.insert(k) }
            }
            i = j
        }
        // A Korean word stretched over a quote was said before it or after it — Apple stretches either way ("공짜" back
        // over "There is no such thing as a free lunch."; "고양이입니다." forward over "Please write it down…"). Two words
        // glued across the quote — after a full stop ("뜻입니다.마셜") or a copula after 은/는 ("문장은입니다.") — are
        // split when each part has time enough to be said on its side (0.15 s a syllable). A word goes to the side with
        // time enough to say it; if both (or neither) have, after the quote — Apple stretches the word after a quote back
        // far more often. (Guessing from the English model's unsure words was tried: they are often its guesses at Korean
        // words Apple dropped, and they arrive in later results.)
        var korean: [(Token, Double, Double)] = []              // the token, its place, its own time (ties keep order)
        for (k, t) in toks.enumerated() where !(t.latinOnly && t.conf < 0.6) && !dropped.contains(k) {
            guard stretched(t), let p = near.filter({ $0.end > t.start && $0.end < t.end }).max(by: { $0.end < $1.end }) else {
                korean.append((t, t.start, t.start)); continue
            }
            func fits(_ text: String, _ seconds: Double) -> Bool { seconds >= max(0.25, 0.15 * spokenUnits(text)) }
            if let cut = splitPoint(t.text), fits(String(t.text[..<cut]), p.start - t.start), fits(String(t.text[cut...]), t.end - p.end) {
                korean.append((Token(start: t.start, end: t.start, conf: t.conf, text: String(t.text[..<cut]), glued: t.glued), t.start, t.start))
                korean.append((Token(start: p.end, end: t.end, conf: t.conf, text: String(t.text[cut...]), index: t.index), p.end, t.end))
                continue
            }
            let roomBefore = fits(t.text, p.start - t.start), roomAfter = fits(t.text, t.end - p.end)
            let saidBefore = roomBefore && !roomAfter
            if env["LECTURE_DEBUG"] == "1" {
                FileHandle.standardError.write(String(format: "   stretched %@ [%.2f-%.2f] over %.2f-%.2f: room %d/%d → %@\n",
                                                      t.text, t.start, t.end, p.start, p.end, roomBefore ? 1 : 0, roomAfter ? 1 : 0,
                                                      saidBefore ? "before" : "after").data(using: .utf8)!)
            }
            korean.append((t, saidBefore ? t.start : p.end, t.start))
        }
        // a quote stays in one piece: a Korean word whose place falls inside it goes to the nearer edge ("표 The 보세요.
        // early bird…" → "표 보세요. The early bird…"), keeping its order with the words around it
        for (k, (t, at, tie)) in korean.enumerated() {
            guard let p = inside.first(where: { at > $0.start && at < $0.end }) else { continue }
            korean[k] = (t, at - p.start < p.end - at ? p.start - 0.001 : p.end + 0.001, tie)
        }
        let english = inside.flatMap { p in p.tokens.enumerated().map { ($0.element, p.start, p.start + Double($0.offset) * 1e-6) } }
        return join((korean + english).sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0))
    }

    /// Where a token glued across a quote divides: after an internal full stop, or before a copula after 은/는 (not after
    /// 이/가 — "고양이입니다", "사업가입니다" are nouns).
    private func splitPoint(_ text: String) -> String.Index? {
        var cut: String.Index?                         // after the last full stop with more of the token after it
        var i = text.startIndex                        // ("말입니다.베이죠." → "말입니다." | "베이죠.")
        while i < text.endIndex {
            let next = text.index(after: i)
            if ".?!".contains(text[i]), next < text.endIndex, !".?!".contains(text[next]) { cut = next }
            i = next
        }
        return cut ?? text.range(of: "(?<=[가-힣][은는])(입니다|이에요|예요|이죠|이다)[.?!]?$", options: .regularExpression)?.lowerBound
    }


    /// Syllables to say: Hangul syllables plus half the other letters and digits.
    private func spokenUnits(_ text: String) -> Double {
        let syllables = text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        let others = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && !(0xAC00...0xD7A3).contains($0.value) }.count
        return Double(syllables) + Double(others) / 2
    }

    /// Whether `t` lies mostly (more than half) under `p` — or at all, with `any` — allowing `pad` seconds at its edges.
    private func mostly(_ t: Token, under p: Phrase, pad: Double = 0, any: Bool = false) -> Bool {
        let over = min(p.end + pad, t.end) - max(p.start - pad, t.start)
        return any ? over > 0 : over > 0.5 * (t.end - t.start)
    }

    /// Korean lecture: whether a Korean-model token is its guess at the words of an accepted English phrase — only words
    /// without Hangul (Latin letters, digits): a Korean word is never dropped, however unsure (unsure Hangul at a quote's
    /// edges was real speech: "꼭", "라는", "보세요."). The two models' word edges differ by up to a few hundred ms, and a
    /// line's first word can start in the silence before it ("He" 0.00–1.56 for "Hey" at 1.32), so its end counts too.
    private func guess(_ t: Token, _ phrases: [Phrase]) -> Bool {
        guard mainIsKorean else { return false }
        if t.hangul { return false }
        return phrases.contains { p in
            min(p.end + guessPad, t.end) - max(p.start - guessPad, t.start) > 0.5 * (t.end - t.start)
                || (t.end > p.start + 0.1 && t.end <= p.end + guessPad)
        }
    }
    private let guessPad = 0.15

    /// Words joined by spaces; punctuation sticks to the word before it and is never doubled.
    /// Words joined by spaces, as the model spaced them where they still follow each other; punctuation sticks to the
    /// word before it, is never doubled, and never starts a line.
    private func join(_ tokens: [Token]) -> String {
        let punct = CharacterSet.punctuationCharacters.union(.symbols)
        var out = "", prev: Token?
        for t in tokens {
            if t.text.unicodeScalars.allSatisfy({ punct.contains($0) }) {
                guard let last = out.unicodeScalars.last, !punct.contains(last) else { continue }
                out += t.text
            } else {
                let glue = t.glued && t.index >= 0 && prev.map { $0.index >= 0 && $0.index + 1 == t.index } == true
                out += (out.isEmpty || glue ? "" : " ") + t.text
            }
            prev = t
        }
        return out
    }

    private func emitKorean(_ seg: KoFinal) {
        // a line doesn't start with punctuation (left over from a guess that went, or as the model wrote it: ". 데카르트의")
        let text = String(render(seg).drop { $0.isWhitespace || ".,!?".contains($0) })
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
        for var t in tokens(r.text) {
            t.index = -1                                          // not a main-model token: never glued to one
            // English lecture: the Korean model writes everything, English speech as Latin guesses — only its runs of
            // Hangul can be Korean asides
            if !mainIsKorean, !t.hangul { flush(); continue }
            // an English quote doesn't start with punctuation (",(0.03)" pulled one a second early, over a Korean word) or
            // with an unsure word stretched over the Korean before it ("Tell,(0.35)" 0.36–2.64 sank "Knowledge is power…")
            if mainIsKorean, phrase.isEmpty, t.text.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.union(.symbols).contains($0) })
                || (t.conf < 0.5 && stretched(t)) { continue }
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
            for ok in vetted(p) {
                accepted.append(ok)
                let mid = (ok.start + ok.end) / 2
                if !koFinals.contains(where: { mid >= $0.start && mid <= $0.end }) {
                    let id = nextID; nextID += 1
                    let line = Line(id: id, start: ok.start, text: join(ok.tokens), final: true, end: ok.end)
                    ownLines[id] = line
                    onLine?(line)
                }
                // re-render: the phrase inside its line, the main model's guess at it gone from every line it touches
                for seg in koFinals where seg.end > ok.start - guessPad && seg.start < ok.end + guessPad { emitKorean(seg) }
            }
        }
        pendingEnglish = keep
    }

    /// A real English quote: ≥ 3 words, confident on average, and not on top of Korean speech.
    private func vetted(_ p: Phrase) -> [Phrase] {
        let r = vettedCore(p)
        if env["LECTURE_DEBUG"] == "1" {
            FileHandle.standardError.write("EN phrase \(String(format: "%.2f-%.2f", p.start, p.end)) [\(p.tokens.map { "\($0.text)(\(String(format: "%.2f", $0.conf)))" }.joined(separator: " "))] → \(r.isEmpty ? "rejected" : "accepted" + (r.count > 1 || r[0].tokens.count != p.tokens.count ? ": " + r.map { join($0.tokens) }.joined(separator: " | ") : ""))\n".data(using: .utf8)!)
        }
        if env["LECTURE_DEBUG"] == "1" {
            let near = koFinals.flatMap(\.tokens).filter { $0.end > p.start - 0.5 && $0.start < p.end + 0.5 }
            FileHandle.standardError.write("   korean nearby: \(near.map { "\($0.text)[\(String(format: "%.2f-%.2f c%.2f", $0.start, $0.end, $0.conf))]" }.joined(separator: " "))\n".data(using: .utf8)!)
        }
        return r
    }

    /// A word far longer than its letters take to say: the model stretched it over speech it didn't write ("말이"
    /// 6.66–10.14 across "Knowledge is power."), so its timing can't vouch for Korean speech there.
    private func stretched(_ t: Token) -> Bool {
        t.end - t.start > 0.5 + 0.5 * spokenUnits(t.text)
    }

    /// The main model's lines around a phrase (a whole lecture's words would be scanned for every phrase otherwise).
    private func finals(near p: Phrase) -> [KoFinal] {
        koFinals.filter { $0.end > p.start - 1 && $0.start < p.end + 1 }
    }

    private func vettedCore(_ p: Phrase) -> [Phrase] {
        if !mainIsKorean { return vettedKorean(p).map { [$0] } ?? [] }
        let near = finals(near: p).flatMap(\.tokens).filter { $0.hangul && $0.conf >= 0.5 }
        // seconds of a word that Korean speech actually covers (word edges jitter by tens of ms)
        func overlap(_ t: Token, _ korean: [Token]) -> Double {
            min(t.end - t.start, korean.reduce(0) { $0 + max(0, min($1.end, t.end) - max($1.start, t.start)) })
        }
        let dur = max(0.01, p.end - p.start)
        func covered(_ korean: [Token]) -> Double { p.tokens.reduce(0) { $0 + overlap($1, korean) } / dur }
        // A Korean word far longer than its letters take to say was stretched over speech it didn't write ("말이"
        // 6.66–10.14 over "Knowledge is power."). Only it covering the phrase doesn't sink it — if the English model heard
        // every word of the phrase surely (≥ 0.5): its unsure words there are often guesses at the Korean around the quote
        // ("Only(0.58) to(0.22) result(0.09)… practice makes perfect"), and cutting them off loses real words too ("Stay(0.21)").
        let firm = near.filter { !stretched($0) }
        let words = p.tokens.filter { !$0.text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.symbols).contains($0) } }
        let korean: [Token]
        if covered(near) < 0.25 { korean = near }
        else if covered(firm) < 0.25, words.allSatisfy({ $0.conf >= 0.5 }) { korean = firm }
        else {
            if env["LECTURE_DEBUG"] == "1" {
                FileHandle.standardError.write("   covered=\(String(format: "%.2f/%.2f", covered(near), covered(firm))) (all/firm) → too much Korean under it\n".data(using: .utf8)!)
            }
            return []
        }
        // words that Korean speech covers split it: two quotes with a Korean sentence between them, run together by the
        // English model, are two quotes, each judged on its own (≥ 3 words, confident on average)
        var parts: [[Token]] = [[]]
        for t in p.tokens {
            if t.end > t.start, overlap(t, korean) >= 0.4 * (t.end - t.start) { if !parts[parts.count - 1].isEmpty { parts.append([]) } }
            else { parts[parts.count - 1].append(t) }
        }
        return parts.compactMap { q in
            guard q.count >= 3, q.map(\.conf).reduce(0, +) / Double(q.count) >= 0.45 else { return nil }
            return Phrase(tokens: q)
        }
    }

    /// English lecture: a Korean aside — mostly Hangul, confident, and where the English model was unsure (its words
    /// there are a guess at Korean speech). Korean said over confident English is the Korean model mishearing English.
    private func vettedKorean(_ p: Phrase) -> Phrase? {
        let hangul = p.tokens.filter(\.hangul)
        guard hangul.count >= 2, Double(hangul.count) >= 0.7 * Double(p.tokens.count) else { return nil }
        let mean = p.tokens.map(\.conf).reduce(0, +) / Double(p.tokens.count)
        guard mean >= 0.6 else { return nil }
        let english = finals(near: p).flatMap(\.tokens).filter { $0.end > p.start && $0.start < p.end }
        if !english.isEmpty, english.map(\.conf).reduce(0, +) / Double(english.count) >= 0.5 { return nil }
        return p
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
