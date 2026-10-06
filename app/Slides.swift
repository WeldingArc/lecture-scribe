// Slides for 강의 받아쓰기: notices when the lecture's picture turns to a new slide, keeps one image
// per slide, and makes a PDF with every slide and what was said while it was on screen.
// Sources: the lecture window on a Mac (ScreenSlides.swift) or the video track of an imported file.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Comparing frames

/// A 320×180 grayscale thumbnail of a frame, compared tile by tile (16 × 9 tiles of 20×20 pixels) and pixel by
/// pixel — fine enough that body text shows, so two slides with the same layout but different words differ.
struct Signature: Sendable {
    static let w = 320, h = 180, tw = 20, th = 20, cols = 16, rows = 9
    static let tiles = cols * rows
    let px: [UInt8]
    let tileBG: [Int]                          // each tile's background: its most common brightness
    let contrast: Double                       // a blank (black or single-colour) frame has none

    init(px: [UInt8], tileBG: [Int], contrast: Double) { self.px = px; self.tileBG = tileBG; self.contrast = contrast }

    init?(_ image: CGImage) {
        var buf = [UInt8](repeating: 0, count: Signature.w * Signature.h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: Signature.w, height: Signature.h, bitsPerComponent: 8,
                                      bytesPerRow: Signature.w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: Signature.w, height: Signature.h))
            return true
        }
        guard ok else { return nil }
        px = buf
        var bgs = [Int]()
        for r in 0..<Signature.rows {
            for c in 0..<Signature.cols {
                var hist = [Int](repeating: 0, count: 32), sums = [Int](repeating: 0, count: 32)
                for y in r * Signature.th..<(r + 1) * Signature.th {
                    for x in c * Signature.tw..<(c + 1) * Signature.tw { let v = Int(buf[y * Signature.w + x]); hist[v >> 3] += 1; sums[v >> 3] += v }
                }
                let m = hist.indices.max { hist[$0] < hist[$1] }!
                bgs.append(sums[m] / max(1, hist[m]))
            }
        }
        tileBG = bgs
        let mean = Double(buf.reduce(0) { $0 + Int($1) }) / Double(buf.count)
        contrast = (buf.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(buf.count)).squareRoot()
    }
}

/// How a picture differs from an earlier one, over the tiles we trust. Every strongly changed pixel is one of:
/// added (background before, ink now), removed (ink before, background now), faded (the same ink, paler — an earlier
/// bullet dimmed as the next one appears) or altered (ink replaced by other ink, or the background itself changed).
/// Judged against each tile's own background, so it doesn't matter how lines of text fall into tiles.
struct FrameDiff {
    var changed = [Bool](repeating: false, count: Signature.tiles)
    var tileMeanDiff = [Double](repeating: 0, count: Signature.tiles)   // even faint changes (a fade, compression noise)
    var tiles = 0
    var added = 0, removed = 0, altered = 0, faded = 0
    var meanAbs = 0.0
    var total: Int { added + removed + altered }
    /// Only new content on empty space, nothing taken away: a slide being built up (bullets appearing one by one).
    var grew: Bool { added > 0 && removed <= max(2, min(added / 12, 20)) && altered <= max(3, total / 8) }
    /// Only content taken away, nothing new: an earlier step of the same slide.
    var shrank: Bool { removed > 0 && added <= max(2, min(removed / 12, 20)) && altered <= max(3, total / 8) }

    init(_ old: Signature, _ new: Signature, trusted: [Bool]) {
        let n = Signature.tw * Signature.th
        var sumAll = 0, pixels = 0
        for r in 0..<Signature.rows {
            for c in 0..<Signature.cols {
                let i = r * Signature.cols + c
                guard trusted[i] else { continue }
                let bg = old.tileBG[i], bgMoved = abs(bg - new.tileBG[i]) > 16
                var sum = 0, strong = 0
                for y in r * Signature.th..<(r + 1) * Signature.th {
                    for x in c * Signature.tw..<(c + 1) * Signature.tw {
                        let k = y * Signature.w + x, a = Int(old.px[k]), b = Int(new.px[k]), d = abs(a - b)
                        sum += d
                        guard d > 28 else { continue }
                        strong += 1
                        if bgMoved { altered += 1; continue }
                        let da = abs(a - bg), db = abs(b - bg)
                        if da <= 18 && db > 18 { added += 1 } else if da > 18 && db <= 18 { removed += 1 }
                        else if db < da - 10 && (a - bg) * (b - bg) > 0 { faded += 1 } else { altered += 1 }
                    }
                }
                sumAll += sum; pixels += n
                tileMeanDiff[i] = Double(sum) / Double(n)
                if Double(sum) / Double(n) > 4 || strong * 50 >= n { changed[i] = true; tiles += 1 }     // a colour change, or ≥ 2% sharp
            }
        }
        meanAbs = pixels > 0 ? Double(sumAll) / Double(pixels) : 0
    }

    /// One patch of strongly changed pixels (8-connected).
    struct Blob { var size = 0, added = 0, removed = 0, x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min; var pixels: [Int] = [] }

    /// The patches of strongly changed pixels (ignoring specks under 3 pixels), at most `limit` of them.
    static func blobs(_ old: Signature, _ new: Signature, trusted: [Bool], limit: Int = 120) -> [Blob] {
        let w = Signature.w, h = Signature.h
        var kind = [Int8](repeating: 0, count: w * h)                  // 0 none, 1 added, 2 removed, 3 other
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / Signature.th) * Signature.cols + x / Signature.tw
                guard trusted[i] else { continue }
                let k = y * w + x, a = Int(old.px[k]), b = Int(new.px[k])
                guard abs(a - b) > 28 else { continue }
                let bg = old.tileBG[i], da = abs(a - bg), db = abs(b - bg)
                kind[k] = da <= 18 && db > 18 ? 1 : (da > 18 && db <= 18 ? 2 : 3)
            }
        }
        var out: [Blob] = [], stack: [Int] = []
        for k0 in 0..<(w * h) where kind[k0] != 0 {
            var b = Blob()
            stack.append(k0)
            var seen = [k0]; let first = kind[k0]; kind[k0] = -first
            while let k = stack.popLast() {
                let x = k % w, y = k / w
                b.size += 1; b.pixels.append(k)
                if -kind[k] == 1 { b.added += 1 } else if -kind[k] == 2 { b.removed += 1 }
                b.x0 = min(b.x0, x); b.x1 = max(b.x1, x); b.y0 = min(b.y0, y); b.y1 = max(b.y1, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let j = ny * w + nx
                        if kind[j] > 0 { kind[j] = -kind[j]; stack.append(j); seen.append(j) }
                    }
                }
            }
            _ = seen
            if b.size >= 3 { out.append(b); if out.count >= limit { break } }
        }
        return out
    }
}

extension Signature {
    /// This picture with some tiles taken from another one.
    func merged(with other: Signature, tiles take: [Bool]) -> Signature {
        var p = px, bg = tileBG
        for r in 0..<Signature.rows {
            for c in 0..<Signature.cols where take[r * Signature.cols + c] {
                bg[r * Signature.cols + c] = other.tileBG[r * Signature.cols + c]
                for y in r * Signature.th..<(r + 1) * Signature.th {
                    let row = y * Signature.w
                    for x in c * Signature.tw..<(c + 1) * Signature.tw { p[row + x] = other.px[row + x] }
                }
            }
        }
        return Signature(px: p, tileBG: bg, contrast: contrast)
    }
}

// MARK: - Detecting slides

/// Decides when the picture shows a new slide. Feed it frames in time order (live: twice a second;
/// files: once a second). A picture counts once it has held still for `settle` seconds, so transitions, fades,
/// animations and scrolling don't make pages. Each new picture is compared with the current slide's fullest picture:
/// content only added (a bullet appearing) updates the page, content only taken away is an earlier step of it, and
/// anything else — however small, like one revised number — is another slide, unless it is one of the things that
/// change on their own: a pointer that moved, the lecturer's camera, subtitles, a clock, a chat, a playing video
/// (parts that keep moving are ignored until they have been still for a few seconds). A return to an earlier slide is
/// recognised rather than captured twice.
final class SlideDetector {
    enum Event: Equatable { case new(Int, Double), again(Int, Double), update(Int) }

    let settle: Double
    private var slides: [Signature] = []                  // each slide's fullest picture
    private var current: Int?
    /// The current slide as it should look now: its fullest picture, with what we decided to ignore (a camera, a pointer,
    /// a clock) as it is now.
    private var ref: Signature?
    private var last: Signature?
    private var lastT = 0.0
    private var candidate: (sig: Signature, since: Double)?
    private var streak = [Int](repeating: 0, count: Signature.tiles)            // consecutive frames each tile moved
    private var movedAt = [Double](repeating: -1000, count: Signature.tiles)  // when a tile last moved like a camera or video
    private var ticks = [[Double]](repeating: [], count: Signature.tiles)     // when each tile had tiny changes (a clock?)
    private var spots: [(box: Box, t: Double, since: Double)] = []            // recent small, local changes (and their picture)
    private var subtitlesSeen = -1000.0                                       // when subtitles at the bottom last changed
    private var recent: [(t: Double, sig: Signature)] = []                    // the last 30 s of frames
    private var noise = 0.0, speckNoise = 0.0                                 // frame-to-frame jitter of a still picture
    private var pointerSeen = -1000.0                                         // when a pointer was last seen moving
    private var now = 0.0
    /// The motion going on now: when it started, the still picture before it, frames during it, scrolling frames, the
    /// tiles that moved, and what had been learned before it.
    private var episode: (start: Double, from: Signature, frames: [Signature], scrolls: Int, tiles: Set<Int>, movedAt: [Double])?
    private let hold = 6.0                                                    // seconds a moving part stays ignored after it stops

    init(settle: Double) { self.settle = settle }

    /// Tests: explains each decision.
    var trace: ((String) -> Void)?

    private var trusted: [Bool] { movedAt.map { now - $0 > hold } }

    func step(_ t: Double, _ sig: Signature) -> Event? {
        now = t
        defer { last = sig; lastT = t }
        recent.append((t, sig))
        if let f = recent.first, t - f.t > 30 { recent.removeFirst() }
        guard let prev = last else { candidate = (sig, t); return nil }
        let all = [Bool](repeating: true, count: Signature.tiles)
        let moving = FrameDiff(prev, sig, trusted: all)
        // a camera or a video moves as one or two compact patches while the rest holds still; a fade, a scroll or a
        // transition touches many separate lines at once (if only faintly) — that must not teach us to ignore those places
        // — or, in a video call, as several small ones (a strip of participants' cameras)
        let faint = moving.tileMeanDiff.map { $0 > max(0.8, noise * 2) }
        let faintPatches = SlideDetector.patches(faint), faintShare = Double(faint.filter { $0 }.count) / Double(Signature.tiles)
        var local = faintShare < 0.6 && (faintPatches.count <= 2 || (faintShare < 0.2 && faintPatches.allSatisfy { $0.count <= 12 }))
        let scroll = moving.tiles > 0 && SlideDetector.scrolled(prev, sig, moving.changed)    // a document scrolling: nothing to learn
        if scroll { local = false }
        // a pointer moving about (the presenter's cursor, a laser) is not a moving part to learn: it would hide the slide
        // wherever it went. Looked for where nothing is known to move (a camera beside it keeps moving too).
        let known = trusted
        let free = FrameDiff(prev, sig, trusted: known)
        var pointerTiles = Set<Int>()
        if free.total > 0, free.total < 500, free.tiles <= 4 {
            let marks = FrameDiff.blobs(prev, sig, trusted: known)
            if SlideDetector.pointerOnly(marks, free, moved: true) {
                pointerSeen = t
                for b in marks { for k in b.pixels { pointerTiles.insert((k / Signature.w / Signature.th) * Signature.cols + (k % Signature.w) / Signature.tw) } }
            }
        }
        // A camera or a video moves in frame after frame; a cut to the next slide moves once. Only what keeps moving is
        // learned (and ignored until it has been still for a few seconds) — once the motion proves not to be a transition:
        // it goes on longer than any transition, or it stops without having been a blend from one picture to the next.
        // A fade, a wipe or a scroll between two slides is forgotten.
        for i in 0..<Signature.tiles { streak[i] = moving.changed[i] && local && !pointerTiles.contains(i) ? streak[i] + 1 : 0 }
        if moving.total > 0, moving.total < 80, moving.tiles <= 2 {      // a tiny change: a clock ticking, maybe
            for i in 0..<Signature.tiles where moving.changed[i] { ticks[i] = (ticks[i] + [t]).suffix(3) }
        }
        let persistent = Set((0..<Signature.tiles).filter { streak[$0] >= 2 })
        if moving.tiles > 0 {
            if episode == nil { episode = (t, prev, [], 0, [], movedAt) }
            if episode!.frames.count < 12 { episode!.frames.append(sig) }
            if scroll { episode!.scrolls += 1 }
            episode!.tiles.formUnion(persistent)
            if t - episode!.start >= 3.5 { learnMoving(t, persistent) }   // only what is moving now
        } else if let ep = episode, ep.frames.count >= 2 {               // (one moving frame: too short to tell or to learn)
            episode = nil
            let tr = ep.scrolls * 2 >= ep.frames.count || (t - ep.start < 6 && SlideDetector.transition(from: ep.from, through: ep.frames, to: sig))
            if tr { movedAt = ep.movedAt } else { learnMoving(t, ep.tiles) }
        } else { episode = nil }
        guard sig.contrast > 6 else { candidate = nil; return nil }      // black / blank frame (a transition)
        let mask = trusted
        let usable = mask.filter { $0 }.count
        guard usable >= 30 else { candidate = nil; return nil }          // mostly moving video: not slides
        let motion = FrameDiff(prev, sig, trusted: mask)
        let movedShare = Double(motion.tiles) / Double(usable)
        if movedShare < 0.03 {
            noise = noise == 0 ? motion.meanAbs : noise * 0.95 + motion.meanAbs * 0.05
            speckNoise = speckNoise * 0.95 + Double(motion.total) * 0.05
        }
        let calm = max(1.2, noise * 2.2), specks = max(6, speckNoise * 3)
        let still = movedShare < 0.03 && motion.meanAbs < calm && Double(motion.total) < specks

        let cand: (sig: Signature, since: Double)
        if let c = candidate {
            let d = FrameDiff(c.sig, sig, trusted: mask)
            cand = Double(d.tiles) / Double(usable) < 0.03 && d.meanAbs < calm * 1.5 && Double(d.total) < specks ? c : (sig, t)
        } else { cand = (sig, t) }
        candidate = cand
        guard still, t - cand.since >= settle else { return nil }

        guard var r = ref, let ci = current else { return accept(sig, cand.since, mask) }   // the first steady picture
        // a camera, a person beside the slide: what changed there while it moved is part of the picture now — but not
        // when a big part was moving (a video filling the window may have been replaced by the next slide meanwhile)
        let hidden = Signature.tiles - usable
        if hidden > 0, Double(hidden) < 0.5 * Double(Signature.tiles) { r = r.merged(with: sig, tiles: mask.map { !$0 }) }
        ref = r
        let d = FrameDiff(r, sig, trusted: mask)
        let box = bounds(d)
        let blobs = d.total < 2500 ? FrameDiff.blobs(r, sig, trusted: mask) : []
        func why(_ reason: String) {
            let line = String(format: "t=%.1f tiles=%d added=%d removed=%d altered=%d faded=%d box=%@ → %@", t, d.tiles, d.added, d.removed,
                              d.altered, d.faded, box.map { "r\($0.r0)-\($0.r1) c\($0.c0)-\($0.c1)" } ?? "-", reason)
            trace?(line)
        }
        func absorb(_ reason: String) -> Event? {                         // not a slide change: it is part of the picture now
            var touched = d.changed                                       // every tile the change touched, faint edges too
            for b in blobs { for k in b.pixels { touched[(k / Signature.w / Signature.th) * Signature.cols + (k % Signature.w) / Signature.tw] = true } }
            ref = r.merged(with: sig, tiles: touched)
            candidate = nil
            why(reason)
            return nil
        }
        // the same picture — unless a few coherent marks changed (one word in small text is only a handful of pixels,
        // but several glyphs; noise makes no such patches)
        if d.total < 8 && d.tiles <= 1 && blobs.count < 3 {
            candidate = nil
            return nil
        }
        if SlideDetector.movedObject(blobs, d) { return absorb("a pointer moved") }
        if SlideDetector.pointerOnly(blobs, d, moved: t - pointerSeen > 30) { return absorb("a pointer came, went or moved") }
        // captions (a band whose text is replaced) or a chat (a narrow column at the side) changing again within seconds
        let spot = box.map { (SlideDetector.band($0) && !d.grew) || SlideDetector.sideColumn($0) } ?? false
        if spot, let b = box {
            if spots.contains(where: { t - $0.t < 8 && $0.since != cand.since && SlideDetector.sameSpot($0.box, b) }) {
                spots.append((b, t, cand.since))
                return absorb("changes again in the same place")
            }
            if !spots.contains(where: { $0.since == cand.since }) { spots.append((b, t, cand.since)) }
        }
        // ink taken away somewhere while ink was added: something was replaced (a number, a word) — an edit, not a build
        let replaced = blobs.contains { $0.removed >= 3 } && blobs.contains { $0.added >= 3 }
        if d.grew, !replaced, d.added >= 20 || blobs.count >= 2 {        // built up: the page keeps the fuller picture
            slides[ci] = sig
            ref = sig
            candidate = nil
            why("update")
            return .update(ci)
        }
        if d.shrank, !replaced, d.removed >= 30 { candidate = nil; why("an earlier step"); return nil }   // stepped back: the fuller one stays
        if cameraOnly(d) { return absorb("camera") }                     // the lecturer's camera: someone else, or moved
        guard let b = box else { candidate = nil; return nil }
        if subtitles(b) { subtitlesSeen = t; return absorb("subtitles") }
        if d.total < 150 {                                                // small: a clock or counter — or a real edit
            let changed = (0..<Signature.tiles).filter { d.changed[$0] }
            let ticking = changed.contains { i in ticks[i].filter { t - $0 < 6 }.count >= 2 }    // changed twice within seconds
            if clockPlace(b) || ticking { return absorb("clock") }
        }
        // only a band or a column changed, away from the title: wait a while before calling it a slide — a player's
        // controls, a notification or a chat line come and go again (a real slide change is still dated to when it came)
        if spot, let b = box, !(b.r0 <= 2 && b.c0 < Signature.cols * 2 / 3), t - cand.since < 5.5 { return nil }
        spots.removeAll { t - $0.t > 30 }
        why("accept")
        return accept(sig, cand.since, mask)                              // the content really changed: another slide
    }

    private struct Box { let r0: Int, r1: Int, c0: Int, c1: Int }

    /// The 4-connected patches of changed tiles.
    private static func patches(_ changed: [Bool]) -> [[Int]] {
        var seen = [Bool](repeating: false, count: Signature.tiles), out: [[Int]] = []
        for start in 0..<Signature.tiles where changed[start] && !seen[start] {
            var stack = [start], tiles: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                tiles.append(i)
                let r = i / Signature.cols, c = i % Signature.cols
                for (rr, cc) in [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
                where rr >= 0 && rr < Signature.rows && cc >= 0 && cc < Signature.cols {
                    let j = rr * Signature.cols + cc
                    if changed[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            out.append(tiles)
        }
        return out
    }

    /// Ignore what moved until it has been still for `hold` seconds, with a tile's margin (a person gesturing reaches
    /// a little further).
    private func learnMoving(_ t: Double, _ tiles: Set<Int>) {
        for i in tiles {
            let r = i / Signature.cols, c = i % Signature.cols
            for rr in max(0, r - 1)...min(Signature.rows - 1, r + 1) {
                for cc in max(0, c - 1)...min(Signature.cols - 1, c + 1) { movedAt[rr * Signature.cols + cc] = t }
            }
        }
    }

    /// Did the picture (its largest changed part) move up or down as a whole — a page or a document scrolling? The
    /// earlier frame, shifted by up to 60 of its 180 rows, then matches far better than unshifted.
    static func scrolled(_ a: Signature, _ b: Signature, _ changed: [Bool]) -> Bool {
        guard let main = patches(changed).max(by: { $0.count < $1.count }), main.count >= 4 else { return false }
        let cols = main.map { $0 % Signature.cols }, rows = main.map { $0 / Signature.cols }
        let x0 = cols.min()! * Signature.tw, x1 = (cols.max()! + 1) * Signature.tw
        let y0 = rows.min()! * Signature.th, y1 = (rows.max()! + 1) * Signature.th
        func agree(_ dy: Int) -> Double {
            let lo = max(y0, -dy), hi = min(y1, Signature.h - dy)
            guard lo < hi else { return 0 }
            var ok = 0, n = 0
            for y in lo..<hi {
                let row = y * Signature.w, from = (y + dy) * Signature.w
                for x in stride(from: x0, to: x1, by: 2) { if abs(Int(b.px[row + x]) - Int(a.px[from + x])) <= 10 { ok += 1 }; n += 1 }
            }
            return n > 0 ? Double(ok) / Double(n) : 0
        }
        let base = agree(0)
        guard base < 0.97 else { return false }
        var best = 0.0
        for dy in -60...60 where dy != 0 { best = max(best, agree(dy)) }
        return best >= 0.85 && (1 - best) <= 0.35 * (1 - base)
    }

    /// Was this motion a transition from one picture to another — every frame in between a blend of the two (a fade),
    /// or passing through a blank frame (a fade through black)? A camera, a video or a person wanders instead: somewhere
    /// they change what is the same before and after.
    static func transition(from a: Signature, through frames: [Signature], to b: Signature) -> Bool {
        if frames.contains(where: { $0.contrast <= 8 }) { return true }
        var idx: [Int] = [], same: [Int] = [], span = 0.0
        for k in 0..<a.px.count {
            let d = abs(Int(a.px[k]) - Int(b.px[k]))
            if d > 20 { idx.append(k); span += Double(d) } else if d <= 6 { same.append(k) }
        }
        guard idx.count >= 50 else { return false }                       // it came back to where it was: a gesture, not a transition
        span /= Double(idx.count)
        for f in frames.dropLast() {
            var excess = 0
            for k in idx {
                let x = Int(f.px[k]), p = Int(a.px[k]), q = Int(b.px[k])
                excess += abs(x - p) + abs(x - q) - abs(p - q)
            }
            if Double(excess) / Double(idx.count) > 0.25 * span + 4 { return false }
            let strayed = same.reduce(0) { $0 + (abs(Int(f.px[$1]) - Int(a.px[$1])) > 30 ? 1 : 0) }
            if strayed > max(30, same.count / 2000) { return false }
        }
        return true
    }

    /// A pointer (cursor, highlight ring, laser, annotation arrow) that moved: what disappeared in one place appeared,
    /// with the same shape, in another — nothing else changed.
    static func movedObject(_ blobs: [FrameDiff.Blob], _ d: FrameDiff) -> Bool {
        guard blobs.count >= 2, blobs.count < 120 else { return false }
        let gone = blobs.filter { $0.removed * 10 >= $0.size * 6 }, came = blobs.filter { $0.removed * 10 < $0.size * 3 }
        guard !gone.isEmpty, !came.isEmpty, gone.count + came.count >= blobs.count - 1 else { return false }
        func extent(_ bs: [FrameDiff.Blob]) -> (x0: Int, x1: Int, y0: Int, y1: Int, size: Int) {
            (bs.map(\.x0).min()!, bs.map(\.x1).max()!, bs.map(\.y0).min()!, bs.map(\.y1).max()!, bs.reduce(0) { $0 + $1.size })
        }
        let g = extent(gone), c = extent(came)
        guard g.size >= 6, g.size <= 2500, Double(c.size) / Double(g.size) > 0.5, Double(c.size) / Double(g.size) < 2 else { return false }
        let gw = g.x1 - g.x0 + 1, gh = g.y1 - g.y0 + 1, cw = c.x1 - c.x0 + 1, ch = c.y1 - c.y0 + 1
        guard abs(gw - cw) <= max(3, max(gw, cw) / 3), abs(gh - ch) <= max(3, max(gh, ch) / 3) else { return false }
        let apart = g.x1 < c.x0 || c.x1 < g.x0 || g.y1 < c.y0 || c.y1 < g.y0
        guard apart else { return false }                                // in the same place: replaced, not moved
        // the same shape: overlay the two, each from its own corner
        let gp = Set(gone.flatMap(\.pixels).map { ($0 % Signature.w - g.x0) * 1000 + ($0 / Signature.w - g.y0) })
        let cp = Set(came.flatMap(\.pixels).map { ($0 % Signature.w - c.x0) * 1000 + ($0 / Signature.w - c.y0) })
        let common = gp.intersection(cp).count
        let alike = abs(g.size - c.size) * 4 <= max(g.size, c.size) && abs(gw - cw) * 4 <= max(gw, cw) + 4 && abs(gh - ch) * 4 <= max(gh, ch) + 4
        return Double(common) / Double(max(1, gp.union(cp).count)) >= (alike ? 0.15 : 0.35)
    }

    private func bounds(_ d: FrameDiff) -> Box? {
        let on = (0..<Signature.tiles).filter { d.changed[$0] }
        guard !on.isEmpty else { return nil }
        let rows = on.map { $0 / Signature.cols }, cols = on.map { $0 % Signature.cols }
        return Box(r0: rows.min()!, r1: rows.max()!, c0: cols.min()!, c1: cols.max()!)
    }

    /// A band one or two lines high (captions).
    private static func band(_ b: Box) -> Bool { b.r1 - b.r0 + 1 <= 2 }

    /// A narrow column in the right third (a chat panel).
    private static func sideColumn(_ b: Box) -> Bool { b.c1 - b.c0 + 1 <= 5 && b.c0 >= Signature.cols * 2 / 3 }

    /// Only a small mark vanished somewhere and/or appeared somewhere else, each compact and square or upright (not a
    /// wide word): a cursor, a laser dot, a highlight ring — even where the new spot shows it only faintly.
    /// `moved`: it must have moved (vanished in one place, appeared in another) — a mark that only appears is taken for a
    /// pointer only while one has been seen moving recently (otherwise it may be a changed digit or a quiz answer).
    static func pointerOnly(_ blobs: [FrameDiff.Blob], _ d: FrameDiff, moved: Bool = false) -> Bool {
        guard !blobs.isEmpty, blobs.count < 120, d.total < 500, d.tiles <= 8 else { return false }
        let gone = blobs.filter { $0.removed * 10 >= $0.size * 6 }, came = blobs.filter { $0.removed * 10 < $0.size * 6 }
        func compact(_ bs: [FrameDiff.Blob]) -> Bool {
            guard !bs.isEmpty else { return true }
            let w = bs.map(\.x1).max()! - bs.map(\.x0).min()! + 1, h = bs.map(\.y1).max()! - bs.map(\.y0).min()! + 1
            return w <= 32 && h <= 32 && h >= 3 && Double(w) <= 1.5 * Double(h)
        }
        guard compact(gone), compact(came) else { return false }
        guard !gone.isEmpty, !came.isEmpty else { return !moved }
        // both: it must have moved somewhere else — in the same place it was replaced (a "?" turning into "③")
        let gx0 = gone.map(\.x0).min()!, gx1 = gone.map(\.x1).max()!, gy0 = gone.map(\.y0).min()!, gy1 = gone.map(\.y1).max()!
        let cx0 = came.map(\.x0).min()!, cx1 = came.map(\.x1).max()!, cy0 = came.map(\.y0).min()!, cy1 = came.map(\.y1).max()!
        return gx1 + 8 < cx0 || cx1 + 8 < gx0 || gy1 + 8 < cy0 || cy1 + 8 < gy0
    }

    /// The same place again: for a chat, the same column (new messages land lower down); for captions, the same band.
    private static func sameSpot(_ a: Box, _ b: Box) -> Bool {
        if sideColumn(a) && sideColumn(b) {
            let w = min(a.c1, b.c1) - max(a.c0, b.c0) + 1
            return Double(w) >= 0.5 * Double(min(a.c1 - a.c0 + 1, b.c1 - b.c0 + 1))
        }
        return overlap(a, b) >= 0.5
    }

    /// How much two boxes overlap, as a share of the smaller one.
    private static func overlap(_ a: Box, _ b: Box) -> Double {
        let h = min(a.r1, b.r1) - max(a.r0, b.r0) + 1, w = min(a.c1, b.c1) - max(a.c0, b.c0) + 1
        guard h > 0, w > 0 else { return 0 }
        let smaller = min((a.r1 - a.r0 + 1) * (a.c1 - a.c0 + 1), (b.r1 - b.r0 + 1) * (b.c1 - b.c0 + 1))
        return Double(h * w) / Double(smaller)
    }

    /// Only the lecturer's camera changed (someone else in it, or it moved to another corner): every patch of changed
    /// tiles is a compact box in a corner (a camera, or a person standing beside the slide) — not the top-left, where
    /// titles and logos live — mostly changed, at most 12% of the picture each.
    private func cameraOnly(_ d: FrameDiff) -> Bool {
        let found = SlideDetector.patches(d.changed)
        return !found.isEmpty && found.allSatisfy(cameraPatch)
    }

    private func cameraPatch(_ tiles: [Int]) -> Bool {
        let rows = tiles.map { $0 / Signature.cols }, cols = tiles.map { $0 % Signature.cols }
        let b = Box(r0: rows.min()!, r1: rows.max()!, c0: cols.min()!, c1: cols.max()!)
        let w = b.c1 - b.c0 + 1, h = b.r1 - b.r0 + 1
        // within a tile of the edges: an inset camera has a margin, and the person moving in it may not reach its border
        let top = b.r0 <= 1, bottom = b.r1 >= Signature.rows - 2, left = b.c0 <= 1, right = b.c1 >= Signature.cols - 2
        let aspect = Double(w) / Double(h)
        return (top || bottom) && (left || right) && !(top && left) && Double(w * h) / Double(Signature.tiles) <= 0.12 &&
            aspect >= 0.5 && aspect <= 2.4 && Double(tiles.count) >= 0.5 * Double(w * h)
    }

    /// Subtitles at the bottom of the picture, across the middle. (Captions elsewhere — inside a player in a browser
    /// window — are recognised by changing again and again in the same band.)
    private func subtitles(_ b: Box) -> Bool {
        b.r0 >= Signature.rows - 2 && b.c0 <= Signature.cols / 2 && b.c1 >= Signature.cols / 2 - 1
    }

    /// Where a clock, a timer or a page number sits: the top-right corner, the bottom row, the bottom-right corner.
    private func clockPlace(_ b: Box) -> Bool {
        (b.r1 <= 1 && b.c0 >= Signature.cols - 4) || b.r0 >= Signature.rows - 1 || (b.r0 >= Signature.rows - 2 && b.c0 >= Signature.cols - 4)
    }

    private func accept(_ sig: Signature, _ settled: Double, _ mask: [Bool]) -> Event {
        candidate = nil
        let since = shownSince(sig, settled, mask)
        // back to an earlier slide: the same picture, or an earlier step of it — give or take what changes on its own
        // (the camera, a cursor or laser resting elsewhere, a ticking timer, subtitles)
        var m = mask
        for i in 0..<Signature.tiles where ticks[i].count >= 2 {          // a timer: ticks seconds apart, lately
            let k = ticks[i]
            if now - k[k.count - 1] < 60, k[k.count - 1] - k[k.count - 2] < 6 { m[i] = false }
        }
        if now - subtitlesSeen < 60 {
            for r in (Signature.rows - 2)..<Signature.rows { for c in 0..<Signature.cols { m[r * Signature.cols + c] = false } }
        }
        var best: (i: Int, total: Int)?
        for (i, s) in slides.enumerated() {                              // (the current one too: a camera back where it was)
            let d = FrameDiff(s, sig, trusted: m)
            let blobs = d.total < 2500 ? FrameDiff.blobs(s, sig, trusted: m) : []
            let same = (d.total < 8 && d.tiles <= 1 && blobs.count < 3) || cameraOnly(d) || incidentalOnly(d, blobs)
            let earlierStep = d.shrank && d.removed >= 30                 // a whole bullet or more missing, nothing new
            if same || earlierStep, best == nil || d.total < best!.total { best = (i, d.total) }
        }
        if let b = best {
            current = b.i
            ref = slides[b.i]
            return .again(b.i, since)
        }
        slides.append(sig)
        current = slides.count - 1
        ref = sig
        return .new(slides.count - 1, since)
    }

    /// When the new picture really came: the earliest of the latest frames that already show it, give or take a cursor
    /// still moving about — which delays the decision, not the moment the slide changed.
    private func shownSince(_ sig: Signature, _ settled: Double, _ mask: [Bool]) -> Double {
        guard let old = ref else { return settled }
        var since = settled
        for f in recent.reversed() {
            if f.t >= settled { continue }
            let toNew = FrameDiff(f.sig, sig, trusted: mask)
            let identical = toNew.total == 0 && toNew.tiles == 0 && toNew.meanAbs < 0.1
            if !identical {                                               // otherwise only a pointer elsewhere, in a calm frame
                guard toNew.meanAbs <= max(1.2, noise * 2.2), toNew.total >= 8 || toNew.tiles > 1 else { break }
                let marks = toNew.total < 500 ? FrameDiff.blobs(f.sig, sig, trusted: mask) : []
                guard !marks.isEmpty, SlideDetector.pointerOnly(marks, toNew) || SlideDetector.movedObject(marks, toNew) else { break }
            }
            guard FrameDiff(f.sig, old, trusted: mask).total > max(40, toNew.total * 4) else { break }   // not the slide before
            since = f.t
        }
        return since
    }

    /// Every difference is something that changes on its own: inside a camera in a corner, or a pointer resting elsewhere
    /// (while a pointer has been about) — at most two compact groups of marks, one where it was and one where it is,
    /// each only vanished or only appeared. Never lines of text, never something replaced in place (a revised digit).
    private func incidentalOnly(_ d: FrameDiff, _ blobs: [FrameDiff.Blob]) -> Bool {
        guard !blobs.isEmpty, blobs.count < 120 else { return false }
        let cam = Set(SlideDetector.patches(d.changed).filter(cameraPatch).flatMap { $0 })
        var groups: [(x0: Int, x1: Int, y0: Int, y1: Int, came: Bool)] = []
        for b in blobs {
            let tiles = Set(b.pixels.map { ($0 / Signature.w / Signature.th) * Signature.cols + ($0 % Signature.w) / Signature.tw })
            if tiles.isSubset(of: cam) { continue }
            let came = b.removed * 10 < b.size * 3, gone = b.removed * 10 >= b.size * 6
            guard now - pointerSeen < 120, came || gone else { return false }
            if let k = groups.firstIndex(where: { $0.came == came && $0.x0 - 4 <= b.x1 && b.x0 <= $0.x1 + 4 && $0.y0 - 4 <= b.y1 && b.y0 <= $0.y1 + 4 }) {
                let g = groups[k]
                groups[k] = (min(g.x0, b.x0), max(g.x1, b.x1), min(g.y0, b.y0), max(g.y1, b.y1), came)
            } else { groups.append((b.x0, b.x1, b.y0, b.y1, came)) }
            guard groups.count <= 2 else { return false }
        }
        guard groups.allSatisfy({ $0.x1 - $0.x0 < 32 && $0.y1 - $0.y0 < 32 }) else { return false }
        if groups.count == 2, groups[0].came != groups[1].came {          // vanished where something appeared: replaced
            let a = groups[0], b = groups[1]
            if a.x0 <= b.x1 + 2 && b.x0 <= a.x1 + 2 && a.y0 <= b.y1 + 2 && b.y0 <= a.y1 + 2 { return false }
        }
        return true
    }
}

// MARK: - Collecting a session's slides

/// One session's slides: runs the detector, keeps each slide as a JPEG in the app's own folder as soon
/// as it's found (so a crash loses nothing), and remembers which slide was on screen when.
final class SlideCollector: @unchecked Sendable {
    let dir: URL
    var onCount: (@Sendable (Int) -> Void)?
    private let detector: SlideDetector
    private let queue = DispatchQueue(label: "lecture.slides", qos: .utility)
    private var timeline: [(slide: Int, from: Double)] = []
    private var count = 0
    private var closed = false

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureScribe/Slides")
    }

    /// `transcript`: the session's .txt, so a crash-left folder can still become a PDF later.
    init(settle: Double, transcript: URL) throws {
        detector = SlideDetector(settle: settle)
        dir = SlideCollector.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(transcript.path.utf8).write(to: dir.appendingPathComponent("transcript.path"))
    }

    /// Any thread; frames are handled in order on the collector's own queue.
    func add(_ image: CGImage, at t: Double) {
        queue.async { [self] in
            guard !closed, let sig = Signature(image), let ev = detector.step(t, sig) else { return }
            switch ev {
            case .new(let i, let since):
                save(image, i)
                timeline.append((i, since))
                count += 1
                onCount?(count)
            case .again(let i, let since):
                if timeline.last?.slide != i { timeline.append((i, since)) }
            case .update(let i):
                save(image, i)
            }
            writeTimeline()
        }
    }

    private func save(_ image: CGImage, _ i: Int) {
        let url = dir.appendingPathComponent(String(format: "%04d.jpg", i + 1))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, scaled(image, max: 1920), [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func writeTimeline() {
        let rows = timeline.map { "\($0.slide)\t\($0.from)" }.joined(separator: "\n")
        try? Data(rows.utf8).write(to: dir.appendingPathComponent("timeline.tsv"), options: .atomic)
    }

    /// Slides turned off mid-session: stop and throw away what was collected (a PDF being written is not kept).
    func discard() {
        queue.sync { closed = true; discarded = true }
        try? FileManager.default.removeItem(at: dir)
    }
    private var discarded = false
    private var isDiscarded: Bool { queue.sync { discarded } }

    /// Stops taking frames and waits for the last ones. Returns how many slides were found.
    func close() -> Int {
        queue.sync { closed = true; return count }
    }

    /// Writes "<name>.pdf" next to the transcript; then the working folder goes. Returns the slide count.
    @discardableResult
    func makePDF(transcript: URL, lines: [(Double, Double, String)], end: Double) -> Int {
        let n = close()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard n > 0 else { return 0 }
        return SlidesPDF.build(from: dir, transcript: transcript, lines: lines, end: end, cancelled: { [weak self] in self?.isDiscarded ?? false })
    }
}

private func scaled(_ image: CGImage, max side: Int) -> CGImage {
    let w = image.width, h = image.height
    guard Swift.max(w, h) > side else { return image }
    let k = Double(side) / Double(Swift.max(w, h))
    let nw = Int(Double(w) * k), nh = Int(Double(h) * k)
    guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? image
}

// MARK: - Slides from a video file

enum VideoSlides {
    /// Does the file have a picture at all?
    static func hasVideo(_ url: URL) async -> Bool {
        ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []).isEmpty == false
    }

    /// Reads one frame per second into the collector, up to `until()` seconds (중지 part-way: as far as it was transcribed).
    /// `progress` gets 0…1.
    static func extract(_ url: URL, into collector: SlideCollector, until: @escaping @Sendable () -> Double = { .infinity },
                        progress: @escaping @Sendable (Double) -> Void) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let times = stride(from: 0.5, to: duration, by: 1.0).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var done = 0
        for await result in gen.images(for: times) {
            if Task.isCancelled { break }
            done += 1
            if case .success(_, let image, let actual) = result {
                if actual.seconds > until() { break }
                collector.add(image, at: actual.seconds)
            }
            if done % 10 == 0 { progress(Double(done) / Double(times.count)) }
        }
        progress(1)
    }
}

// MARK: - The PDF

/// A4 pages: a cover, then for each slide its picture, when it was shown, and the sentences said
/// while it was on screen (sentences before the first slide go with the first one).
enum SlidesPDF {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 50
    private static let ink = CGColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)
    private static let muted = CGColor(srgbRed: 0.45, green: 0.47, blue: 0.53, alpha: 1)
    private static let accent = CGColor(srgbRed: 0.62, green: 0.49, blue: 0.24, alpha: 1)
    private static let hairline = CGColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1)

    /// The UI's Pretendard, so the PDF looks like the app (falls back to the system font).
    private static let fontsReady: Bool = {
        let dirs = [env["LECTURE_DEV_DIR"].map { $0 + "/ui/fonts" }, Bundle.main.resourcePath.map { $0 + "/ui/fonts" }].compactMap { $0 }
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".otf") {
                CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: d + "/" + f) as CFURL, .process, nil)
            }
        }
        return true
    }()

    /// Pretendard (or the system's Korean font), without contextual alternates: Pretendard swaps % ( ) = − for
    /// alternates next to Hangul, and those glyphs have no Unicode in the PDF — copied or searched text would lose them.
    private static func font(_ size: CGFloat, _ weight: String) -> CTFont {
        _ = fontsReady
        let name = "Pretendard-\(weight)"
        let found = CTFontCreateWithName(name as CFString, size, nil)
        let f = (CTFontCopyPostScriptName(found) as String) == name ? found : CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let off: [[CFString: Any]] = ["calt", "case"].map { [kCTFontOpenTypeFeatureTag: $0 as CFString, kCTFontOpenTypeFeatureValue: 0] }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: off] as CFDictionary)
        return CTFontCreateCopyWithAttributes(f, size, nil, desc)
    }

    private static func text(_ s: String, _ f: CTFont, _ color: CGColor, kern: CGFloat = 0, line: CGFloat = 1.0) -> NSAttributedString {
        var spacing = CTFontGetSize(f) * (line - 1)
        let para = withUnsafePointer(to: &spacing) { p in
            let settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: p)]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let out = NSMutableAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ])
        // Pretendard's glyphs for most symbols get no Unicode in a PDF (copy and search would lose them): only what it
        // carries is drawn with it, everything else with the system's Korean font in the same weight.
        if (CTFontCopyPostScriptName(f) as String).hasPrefix("Pretendard") {
            let weight = (CTFontCopyPostScriptName(f) as String).replacingOccurrences(of: "Pretendard-", with: "")
            let sys = CTFontCreateWithName(("AppleSDGothicNeo-" + (weight == "ExtraLight" ? "UltraLight" : weight)) as CFString, CTFontGetSize(f), nil)
            let ns = s as NSString
            for i in 0..<ns.length where !pretendardKeeps(ns.character(at: i)) {
                out.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: sys, range: NSRange(location: i, length: 1))
            }
        }
        return out
    }

    /// What Pretendard carries into a PDF's text layer (checked character by character): Hangul, ASCII letters and
    /// digits, a little punctuation, circled numbers and Roman numerals.
    private static func pretendardKeeps(_ c: unichar) -> Bool {
        switch c {
        case 0x09, 0x0A, 0x20, 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x21, 0x23, 0x2A, 0x2C, 0x2E, 0x2F, 0x3A, 0x3B, 0x3F, 0x5C: return true      // ! # * , . / : ; ? \
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return true             // Hangul
        case 0x00B7, 0x2022, 0x2026, 0x203B, 0x2460...0x2473, 0x2160...0x216B: return true // · • … ※ ①–⑳ Ⅰ–Ⅻ
        default: return false
        }
    }

    /// At most `max` characters, cut at a space where possible, with "…".
    private static func shortened(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return (cut.count >= max / 2 ? cut : head).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `title` in at most `lines` lines of `width`, broken between words (a Korean word is never split in two, unless
    /// it alone is wider than a line) and cut with "…" when it doesn't fit.
    private static func fitted(_ title: String, width: CGFloat, lines maxLines: Int,
                               _ make: (String) -> NSAttributedString) -> NSAttributedString {
        func w(_ s: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(make(s) as CFAttributedString), nil, nil, nil))
        }
        let room = width - 1
        var words = title.split(separator: " ").map(String.init), lines: [String] = [], cur = "", i = 0
        while i < words.count, lines.count < maxLines {
            let next = cur.isEmpty ? words[i] : cur + " " + words[i]
            if w(next) <= room { cur = next; i += 1; continue }
            if cur.isEmpty {                                          // one word wider than a line: split it
                var head = ""
                for ch in words[i] { if w(head + String(ch)) > room { break }; head.append(ch) }
                if head.isEmpty { head = String(words[i].prefix(1)) }
                lines.append(head)
                words[i] = String(words[i].dropFirst(head.count))
            } else { lines.append(cur); cur = "" }
        }
        if !cur.isEmpty, lines.count < maxLines { lines.append(cur); cur = "" }
        if i < words.count || !cur.isEmpty, var last = lines.last {   // more left: end the last line with "…"
            while w(last + "…") > room, let sp = last.lastIndex(of: " ") { last = String(last[..<sp]) }
            while w(last + "…") > room, last.count > 1 { last.removeLast() }
            lines[lines.count - 1] = last.trimmingCharacters(in: .whitespaces) + "…"
        }
        return make(lines.joined(separator: "\n"))
    }

    private static func flow(_ ctx: CGContext, _ s: NSAttributedString, from start: Int, in rect: CGRect) -> Int {
        let setter = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        let seen = CTFrameGetVisibleStringRange(frame)
        return seen.location + seen.length
    }

    private static func line(_ ctx: CGContext, _ s: NSAttributedString, at p: CGPoint, alignRight: Bool = false) {
        let l = CTLineCreateWithAttributedString(s as CFAttributedString)
        let w = CTLineGetTypographicBounds(l, nil, nil, nil)
        ctx.textPosition = CGPoint(x: alignRight ? p.x - w : p.x, y: p.y)
        CTLineDraw(l, ctx)
    }

    private static func footer(_ ctx: CGContext, _ title: String, _ n: Int) {
        let f = font(7.5, "Light")
        let full = CTLineCreateWithAttributedString(text("강의 받아쓰기 · \(title)", f, muted, kern: 0.3) as CFAttributedString)
        let room = Double(page.width - margin * 2 - 40)                      // a long title stops short of the page number
        let l = CTLineGetTypographicBounds(full, nil, nil, nil) <= room ? full
            : CTLineCreateTruncatedLine(full, room, .end, CTLineCreateWithAttributedString(text("…", f, muted) as CFAttributedString)) ?? full
        ctx.textPosition = CGPoint(x: margin, y: 30)
        CTLineDraw(l, ctx)
        line(ctx, text("\(n)", f, muted), at: CGPoint(x: page.width - margin, y: 30), alignRight: true)
    }

    /// Splits each line into sentences, each with an estimated start (by its position in the line):
    /// the recognizer often returns several sentences as one line, spanning a slide change.
    static func sentences(_ lines: [(Double, Double, String)]) -> [(Double, String)] {
        var out: [(Double, String)] = []
        for (k, l) in lines.enumerated() {
            let stop = l.1 > l.0 ? l.1 : (k + 1 < lines.count ? max(lines[k + 1].0, l.0) : l.0 + 1)
            let parts = l.2.replacingOccurrences(of: #"([.?!。])\s+"#, with: "$1\n", options: .regularExpression)
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let total = max(1, parts.reduce(0) { $0 + $1.count })
            let next = k + 1 < lines.count ? max(l.0, lines[k + 1].0) : Double.infinity    // times never run backwards
            var at = 0
            for p in parts {
                out.append((min(l.0 + (stop - l.0) * Double(at) / Double(total), next), p))
                at += p.count
            }
        }
        return out
    }

    /// Builds the PDF from a collector's folder. Returns the number of slides.
    /// `lines`: (start, end, text); end 0 = unknown.
    static func build(from dir: URL, transcript: URL, lines rawLines: [(Double, Double, String)], end: Double,
                      cancelled: () -> Bool = { false }) -> Int {
        let lines = sentences(rawLines)
        let fm = FileManager.default
        let images: [(Int, CGImage)] = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
            .compactMap { name in
                guard let n = Int(name.prefix(4)), let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return (n - 1, img)
            }
        guard !images.isEmpty else { return 0 }
        // when each slide was on screen
        let rows = (try? String(contentsOf: dir.appendingPathComponent("timeline.tsv"), encoding: .utf8)) ?? ""
        var timeline: [(Int, Double)] = rows.split(separator: "\n").compactMap { r in
            let f = r.split(separator: "\t")
            guard f.count == 2, let i = Int(f[0]), let t = Double(f[1]) else { return nil }
            return (i, t)
        }
        if timeline.isEmpty { timeline = images.map { ($0.0, 0) } }
        // A slide is seen a moment after it appears (frames are sampled), and lecturers start talking as
        // they click: a sentence starting up to a second before a slide is spotted belongs to it.
        let lead = 1.0
        var spans: [Int: [(Double, Double)]] = [:]
        for (k, entry) in timeline.enumerated() {
            let from = k == 0 ? 0 : entry.1 - lead                          // talk before the first slide goes with it
            let to = k + 1 < timeline.count ? timeline[k + 1].1 - lead : max(end, entry.1) + 1
            spans[entry.0, default: []].append((from, to))
        }
        let firstShown = Dictionary(timeline.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

        let header = (try? String(contentsOf: transcript, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
        let name = transcript.deletingPathExtension().lastPathComponent.nfc
        let title = coverTitle(name: name, header: header, file: transcript)
        let pdfURL = transcript.deletingPathExtension().appendingPathExtension("pdf")
        let part = transcript.deletingLastPathComponent().appendingPathComponent(".\(pdfURL.lastPathComponent).part")
        var box = page
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "강의 받아쓰기",
                                     kCGPDFContextKeywords: "slides=\(images.count)"]
        guard let ctx = CGContext(part as CFURL, mediaBox: &box, info as CFDictionary) else { return 0 }
        var pageNo = 0

        // cover
        ctx.beginPDFPage(nil); pageNo += 1
        line(ctx, text("강 의 노 트", font(10, "Regular"), accent, kern: 2), at: CGPoint(x: margin, y: page.height - 150))
        let titleBox = CGRect(x: margin, y: page.height - 260, width: page.width - margin * 2, height: 92)
        _ = flow(ctx, fitted(title, width: titleBox.width, lines: 2) { text($0, font(26, "Light"), ink, line: 1.3) }, from: 0, in: titleBox)
        let said = rawLines.filter { !$0.2.isEmpty }.count                // as the transcript counts them (not split sentences)
        let summary = "\(header.isEmpty ? "" : header + "\n")슬라이드 \(images.count)장 · 문장 \(said)개 · \(fmtTime(end))"
        _ = flow(ctx, text(summary, font(10.5, "Light"), muted, line: 1.6), from: 0,
                 in: CGRect(x: margin, y: page.height - 340, width: page.width - margin * 2, height: 70))
        if let first = images.first?.1 {
            let w = page.width - margin * 2, h = min(w * CGFloat(first.height) / CGFloat(first.width), 300)
            let r = CGRect(x: margin, y: 120, width: h * CGFloat(first.width) / CGFloat(first.height), height: h)
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
            ctx.draw(first, in: r); ctx.restoreGState()
            ctx.setStrokeColor(hairline); ctx.setLineWidth(0.6)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath()
        }
        footer(ctx, title, pageNo)
        ctx.endPDFPage()

        // one page (or more) per slide
        let bodyFont = font(10.5, "Light"), timeFont = font(8.5, "Regular")
        for (n, (i, image)) in images.enumerated() {
            let mine = lines.filter { l in (spans[i] ?? []).contains { l.0 >= $0.0 && l.0 < $0.1 } }
            let said = NSMutableAttributedString()
            for (k, l) in mine.enumerated() {
                said.append(text("\(fmtTime(l.0))   ", timeFont, accent, kern: 0.4, line: 1.75))
                said.append(text(l.1 + (k + 1 < mine.count ? "\n" : ""), bodyFont, ink, line: 1.75))
            }
            if mine.isEmpty { said.append(text("이 슬라이드가 보이는 동안 받아 적은 말이 없어요.", bodyFont, muted, line: 1.75)) }

            var start = 0, first = true
            repeat {
                ctx.beginPDFPage(nil); pageNo += 1
                let top = page.height - 56
                let head = first ? "슬라이드 \(n + 1)" : "슬라이드 \(n + 1) (계속)"
                line(ctx, text(head, font(10, "Regular"), accent, kern: 1.2), at: CGPoint(x: margin, y: top))
                if let t = firstShown[i] {
                    line(ctx, text(fmtTime(t), font(9, "Light"), muted, kern: 0.6), at: CGPoint(x: page.width - margin, y: top), alignRight: true)
                }
                var textTop = top - 22
                if first {
                    let w = page.width - margin * 2
                    let h = min(w * CGFloat(image.height) / CGFloat(image.width), 360)
                    let iw = h * CGFloat(image.width) / CGFloat(image.height)
                    let r = CGRect(x: margin + (w - iw) / 2, y: top - 16 - h, width: iw, height: h)
                    ctx.saveGState(); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.clip()
                    ctx.draw(image, in: r); ctx.restoreGState()
                    ctx.setStrokeColor(hairline); ctx.setLineWidth(0.6)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.strokePath()
                    textTop = r.minY - 26
                    line(ctx, text("이 슬라이드에서 한 말", font(8.5, "Regular"), muted, kern: 0.8), at: CGPoint(x: margin, y: textTop + 2))
                    textTop -= 14
                }
                let area = CGRect(x: margin, y: 54, width: page.width - margin * 2, height: max(40, textTop - 54))
                let next = flow(ctx, said, from: start, in: area)
                footer(ctx, title, pageNo)
                ctx.endPDFPage()
                if next <= start { break }                                 // nothing fitted: don't loop forever
                start = next
                first = false
            } while start < said.length
        }
        ctx.closePDF()
        if cancelled() { try? fm.removeItem(at: part); return 0 }      // 슬라이드 PDF was turned off meanwhile
        do {
            var dest = pdfURL, k = 2                                      // never replace a PDF that's already there
            while fm.fileExists(atPath: dest.path) { dest = pdfURL.deletingLastPathComponent().appendingPathComponent("\(name) (\(k)).pdf"); k += 1 }
            try fm.moveItem(at: part, to: dest)
        } catch {
            log("slides pdf: \(error)")
            try? fm.removeItem(at: part)
            return 0
        }
        return images.count
    }

    /// "2026년 10월 6일 화요일 오후 2:00 강의" for the app's default names; the name itself otherwise.
    static func coverTitle(name: String, header: String, file: URL) -> String {
        if name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}시\d{2}분 강의( \(\d+\))?$"#, options: .regularExpression) != nil {
            let d = Library.date(header: header, file: file), c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: d)
            let h = c.hour ?? 0, days = ["일", "월", "화", "수", "목", "금", "토"]
            return "\(c.year!)년 \(c.month!)월 \(c.day!)일 \(days[(c.weekday ?? 1) - 1])요일 \(h < 12 ? "오전" : "오후") \(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", c.minute ?? 0)) 강의"
        }
        return name.replacingOccurrences(of: #" 받아쓰기( \(\d+\))?$"#, with: "", options: .regularExpression)
    }

    /// How many slides a session's PDF holds (from its keywords), or 0.
    static func count(_ pdf: URL) -> Int {
        guard let doc = CGPDFDocument(pdf as CFURL), let info = doc.info else { return 0 }
        var raw: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Keywords", &raw), let s = raw, let k = CGPDFStringCopyTextString(s) as String?,
              let n = Int(k.replacingOccurrences(of: "slides=", with: "")) else { return 0 }
        return n
    }
}

/// A crash or a quit during recording leaves a collector folder behind: turn it into the PDF.
func recoverSlides() {
    let fm = FileManager.default
    for dir in (try? fm.contentsOfDirectory(at: SlideCollector.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
        let mod = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        guard Date().timeIntervalSince(mod) > 60 else { continue }
        if let p = try? String(contentsOf: dir.appendingPathComponent("transcript.path"), encoding: .utf8),
           let txt = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8), let parsed = Library.parse(txt) {
            let lines = parsed.lines.map { ($0.t, 0.0, $0.text) }        // ends unknown: up to the next line
            let n = SlidesPDF.build(from: dir, transcript: URL(fileURLWithPath: p), lines: lines, end: lines.last?.0 ?? 0)
            log("recovered \(n) slides for an earlier session")
        }
        try? fm.removeItem(at: dir)
    }
}
