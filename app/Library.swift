// The session library of 강의 받아쓰기. Every lecture is one transcript ("<name>.txt") plus its
// recording ("<name>.m4a") in the output folder; the app shows each pair as one session (list, open,
// rename, delete) while the files stay ordinary files that can also be opened or shared directly.

import AVFoundation
import Foundation

enum Library {
    struct Line { let t: Double; let text: String }

    enum Problem: Error { case empty, exists, missing }

    /// A transcript written by Session: header line, "[mm:ss] text" lines, optional "── 중요 문장 ──" tail.
    static func parse(_ text: String) -> (header: String, lines: [Line])? {
        // tolerate files re-saved by other editors: a byte-order mark, Windows line endings
        let rows = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
            .replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let header = rows.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.hasPrefix("강의 녹취 · ") || header.hasPrefix("파일 받아쓰기 · ") else { return nil }
        var lines: [Line] = []
        for row in rows.dropFirst() {
            if row.hasPrefix("──") { break }                 // the tail: "── 중요 문장 ──" (v1: "── 출석 문구 후보 ──")
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else { continue }
            let fields = row[row.index(after: row.startIndex)..<close].split(separator: ":")
            let nums = fields.compactMap { f in f.allSatisfy(\.isASCII) ? Int(f) : nil }.filter { (0...99_999).contains($0) }
            guard (2...3).contains(fields.count), nums.count == fields.count else { continue }
            let text = row[row.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(Line(t: Double(nums.reduce(0) { $0 * 60 + $1 }), text: text)) }
        }
        return (header, lines)
    }

    private static let dateRE = try! NSRegularExpression(pattern: #"(\d{4})-(\d{2})-(\d{2})(?: \(.\) (\d{2}):(\d{2}))?"#)
    private static let defaultNameRE = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}시\d{2}분 강의( \(\d+\))?$"#)

    /// When the session happened: the header's date and time (file transcriptions: the file's time of day).
    static func date(header: String, file: URL) -> Date {
        let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(timeIntervalSince1970: 0)
        let part = header.hasPrefix("파일 받아쓰기") ? (header.components(separatedBy: " · ").last ?? header) : header
        guard let m = dateRE.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) else { return created }
        func n(_ i: Int) -> Int? { Range(m.range(at: i), in: part).flatMap { Int(part[$0]) } }
        var c = DateComponents()
        c.year = n(1); c.month = n(2); c.day = n(3)
        if let h = n(4), let mi = n(5) {
            c.hour = h; c.minute = mi
        } else {
            let t = Calendar.current.dateComponents([.hour, .minute, .second], from: created)
            c.hour = t.hour; c.minute = t.minute; c.second = t.second
        }
        return Calendar.current.date(from: c) ?? created
    }

    static func audioURL(_ dir: URL, _ id: String) -> URL? {
        ["m4a", "wav"].lazy.map { dir.appendingPathComponent("\(id).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Audio length, cached per file version (opening every m4a on each refresh adds up).
    private final class Durations: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: (Date, Double)] = [:]
        func get(_ url: URL) -> Double {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            lock.lock(); let hit = cache[url.path]; lock.unlock()
            if let hit, hit.0 == mod { return hit.1 }
            guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return 0 }
            let s = Double(f.length) / f.fileFormat.sampleRate
            lock.lock(); cache[url.path] = (mod, s); lock.unlock()
            return s
        }
    }
    private static let durations = Durations()

    private static func load(_ dir: URL, _ id: String) -> (header: String, lines: [Line], txt: URL)? {
        let txt = dir.appendingPathComponent("\(id).txt")
        guard let data = try? Data(contentsOf: txt), let text = String(data: data, encoding: .utf8),
              let p = parse(text) else { return nil }
        return (p.header, p.lines, txt)
    }

    private static func cues(_ lines: [Line], _ keywords: NSRegularExpression?) -> [Line] {
        guard let kw = keywords else { return [] }
        return lines.filter { kw.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
    }

    /// `busy`: sessions still being written (recording, or saving after 정지) — not playable, not editable.
    private static func common(_ dir: URL, _ id: String, _ p: (header: String, lines: [Line], txt: URL),
                               recording: String?, busy: Set<String>) -> [String: Any] {
        let live = p.header.hasPrefix("강의 녹취")
        let audio = busy.contains(id) ? nil : audioURL(dir, id)
        let seconds = audio.map { durations.get($0) } ?? (p.lines.last?.t ?? 0)
        let custom = live && defaultNameRE.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) == nil
        return ["id": id, "kind": live ? "live" : "file", "custom": custom,
                "date": date(header: p.header, file: p.txt).timeIntervalSince1970,
                "seconds": (seconds * 10).rounded() / 10, "count": p.lines.count,
                "audio": audio != nil, "recording": id == recording, "saving": busy.contains(id) && id != recording,
                "slides": SlidesPDF.count(dir.appendingPathComponent("\(id).pdf"))]
    }

    /// Every session in the folder, newest first.
    static func scan(_ dir: URL, keywords: NSRegularExpression?, recording: String?, busy: Set<String>) -> [[String: Any]] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var out: [[String: Any]] = []
        for txt in items where txt.pathExtension.lowercased() == "txt" {
            let id = txt.deletingPathExtension().lastPathComponent.nfc
            guard let p = load(dir, id) else { continue }
            var s = common(dir, id, p, recording: recording, busy: busy)
            let hits = cues(p.lines, keywords)
            s["cues"] = hits.prefix(20).map { [$0.t, $0.text] }
            s["cueCount"] = hits.count
            s["preview"] = String((p.lines.first?.text ?? "").prefix(140))
            out.append(s)
        }
        return out.sorted { ($0["date"] as? Double ?? 0) > ($1["date"] as? Double ?? 0) }
    }

    /// One session with its whole transcript.
    static func session(_ dir: URL, id raw: String, recording: String?, busy: Set<String>) -> [String: Any]? {
        let id = raw.nfc
        guard let p = load(dir, id) else { return nil }
        var s = common(dir, id, p, recording: recording, busy: busy)
        s["ev"] = "session"
        s["header"] = p.header
        s["lines"] = p.lines.map { [$0.t, $0.text] }
        return s
    }

    static func files(_ dir: URL, _ id: String) -> [URL] {
        ["txt", "m4a", "wav", "pdf"].map { dir.appendingPathComponent("\(id).\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A name that works as a file name on every system.
    static func clean(_ name: String) -> String {
        var s = name.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(100)).trimmingCharacters(in: .whitespaces).nfc
    }

    /// "name (2)", "name (3)" … — the first that no session uses yet.
    static func uniqueName(_ dir: URL, _ base: String) -> String {
        if files(dir, base).isEmpty { return base }
        var i = 2
        while !files(dir, "\(base) (\(i))").isEmpty { i += 1 }
        return "\(base) (\(i))"
    }

    /// Renames the transcript and its recording together. Returns the new id.
    static func rename(_ dir: URL, id: String, to raw: String) throws -> String {
        let name = clean(raw)
        guard !name.isEmpty else { throw Problem.empty }
        if name == id { return id }
        let fm = FileManager.default
        let mine = files(dir, id)
        guard mine.contains(where: { $0.pathExtension == "txt" }) else { throw Problem.missing }
        let caseSensitive = (try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        let viaTemp = !caseSensitive && name.lowercased() == id.lowercased()   // "Lecture" → "lecture" on a Mac volume
        if !viaTemp, !files(dir, name).isEmpty { throw Problem.exists }
        var done: [(URL, URL)] = []
        do {
            for from in mine.sorted(by: { $0.pathExtension != "txt" && $1.pathExtension == "txt" }) {   // transcript last
                let to = dir.appendingPathComponent("\(name).\(from.pathExtension)")
                if viaTemp {
                    let tmp = dir.appendingPathComponent(".\(UUID().uuidString).\(from.pathExtension)")
                    try fm.moveItem(at: from, to: tmp)
                    do { try fm.moveItem(at: tmp, to: to) } catch { try? fm.moveItem(at: tmp, to: from); throw error }
                } else {
                    try fm.moveItem(at: from, to: to)
                }
                done.append((from, to))
            }
        } catch {
            for (from, to) in done.reversed() { try? fm.moveItem(at: to, to: from) }
            throw error
        }
        return name
    }

    // MARK: Delete (undoable)

    /// A deleted session waits here first, so "되돌리기" is instant. Mac: it then goes on to the Trash
    /// (Finder can restore it; a sandboxed app can't take things back out of the Trash itself).
    /// iPhone/iPad have no Trash: it stays here a few days, then it's removed.
    struct Deleted { let id: String; let bin: URL; let moved: [(from: URL, to: URL)] }

    static var deletedDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureScribe/Deleted")
    }

    static func delete(_ dir: URL, id: String) throws -> Deleted {
        let fm = FileManager.default
        let bin = deletedDir.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        do {
            for u in files(dir, id) {
                let to = bin.appendingPathComponent(u.lastPathComponent)
                try fm.moveItem(at: u, to: to)
                moved.append((u, to))
            }
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            try? fm.removeItem(at: bin)
            throw error
        }
        return Deleted(id: id, bin: bin, moved: moved)
    }

    static func undo(_ d: Deleted) throws -> String {
        let fm = FileManager.default
        guard let dir = d.moved.first?.from.deletingLastPathComponent() else { return d.id }
        let name = uniqueName(dir, d.id)
        var back: [(URL, URL)] = []
        do {
            for (from, held) in d.moved {
                let target = dir.appendingPathComponent("\(name).\(from.pathExtension)")
                try fm.moveItem(at: held, to: target)
                back.append((held, target))
            }
        } catch {
            for (held, target) in back.reversed() { try? fm.moveItem(at: target, to: held) }
            throw error
        }
        try? fm.removeItem(at: d.bin)                                    // the empty holding folder
        return name
    }

    /// Mac: hands a deleted session on to the Trash. iPhone/iPad: nothing yet (see purge).
    static func finalize(_ bin: URL) {
        #if os(macOS)
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
        var left = items.count
        for u in items {
            do { try fm.trashItem(at: u, resultingItemURL: nil); left -= 1 } catch { log("trash failed: \(error)") }
        }
        if left == 0 { try? fm.removeItem(at: bin) }
        #endif
    }

    /// At launch: Mac → leftovers go to the Trash; iPhone/iPad → removed after `days`.
    static func finalizeLeftovers(days: Double = 3) {
        let fm = FileManager.default
        let bins = (try? fm.contentsOfDirectory(at: deletedDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for bin in bins {
            #if os(macOS)
            finalize(bin)
            #else
            let made = (try? bin.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(made) > days * 86400 { try? fm.removeItem(at: bin) }
            #endif
        }
    }
}
