// CameraFinder — finds the lecturer's camera in a lecture picture and gives its rectangle.
//
// The camera is where pixels keep changing while the rest of the picture holds still. Each frame is reduced to a small
// grayscale picture (2×2 pixels per cell of a ~96-column grid); every cell keeps a fading score of how often it changed
// lately. A frame in which most of the picture changed at once (a new slide, a scroll, a full-window video) teaches
// nothing. A patch that keeps changing, stays compact and lasts is a candidate; it is shown once it sits near an edge of
// the picture or has kept going across a slide change (a GIF in a slide stops with its slide — and is then forgotten
// quickly). The patch only covers what moved (the person), so its box is snapped outward to the long straight edges of
// the inset. Cost per frame: one tiny downscale and a few thousand cells.

import CoreGraphics
import Foundation

final class CameraFinder {
    struct Found: Equatable {
        let rect: CGRect          // 0–1, origin at the top-left of the picture
        let confidence: Double    // 0–1
    }

    let cols: Int, rows: Int                    // the cell grid
    private let fw: Int, fh: Int                // the small picture: 2×2 pixels per cell
    private var prev: [Float]?                  // the previous frame's cells
    private var fine: [Float] = []              // the latest small picture (for the edges)
    private var activity: [Float]               // fading count of changes per cell
    private var activeSince: [Double]           // when each cell's current run of activity began
    private var survived: [Bool]                // kept changing across a slide change
    private var lastChanged: [Double]           // when each cell last changed
    private var recent: [Float]                 // the same count, fading in 2 s: is it moving right now?
    private var cut: (t: Double, before: [Bool])?
    private var history: [[Float]] = []         // the last ~12 s of cell pictures
    private var lastT: Double?
    private var current: (rect: CGRect, confidence: Double, seen: Double)?
    private var pending: (rect: CGRect, count: Int)?

    private let tau = 20.0                      // seconds for a cell's score to fade to 37 %
    private let activeRate: Float = 0.10        // changed in ≥ 10 % of recent frames
    private let hold = 45.0                     // a lecturer who sits still stays marked this long

    init(aspect: Double, cols: Int = 96) {      // aspect = width / height of the picture
        self.cols = cols
        rows = max(16, Int((Double(cols) / max(0.2, aspect)).rounded()))
        fw = cols * 2; fh = rows * 2
        activity = [Float](repeating: 0, count: cols * rows)
        activeSince = [Double](repeating: .infinity, count: cols * rows)
        survived = [Bool](repeating: false, count: cols * rows)
        lastChanged = [Double](repeating: -1000, count: cols * rows)
        recent = [Float](repeating: 0, count: cols * rows)
    }

    /// Feed frames in time order (twice a second is plenty). Returns the camera's rectangle while one is known.
    @discardableResult
    func add(_ image: CGImage, at t: Double) -> Found? {
        guard let small = downscale(image) else { return current.map { Found(rect: $0.rect, confidence: $0.confidence) } }
        return add(fine: small, at: t)
    }

    /// The same, from a grayscale picture already made (the slide detector's 320×180 signature).
    @discardableResult
    func add(gray px: [UInt8], width w: Int, height h: Int, at t: Double) -> Found? {
        var small = [Float](repeating: 0, count: fw * fh)
        for y in 0..<fh {
            let y0 = y * h / fh, y1 = max(y0 + 1, (y + 1) * h / fh)
            for x in 0..<fw {
                let x0 = x * w / fw, x1 = max(x0 + 1, (x + 1) * w / fw)
                var sum = 0, n = 0
                for yy in y0..<y1 { for xx in x0..<x1 { sum += Int(px[yy * w + xx]); n += 1 } }
                small[y * fw + x] = Float(sum) / Float(n)
            }
        }
        return add(fine: small, at: t)
    }

    private func add(fine small: [Float], at t: Double) -> Found? {
        fine = small
        var cells = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let y = r * 2, x = c * 2
                cells[r * cols + c] = (small[y * fw + x] + small[y * fw + x + 1] + small[(y + 1) * fw + x] + small[(y + 1) * fw + x + 1]) / 4
            }
        }
        defer { prev = cells; lastT = t; history.append(cells); if history.count > 24 { history.removeFirst() } }
        guard let p = prev, let lt = lastT else { return nil }
        let dt = max(0.05, t - lt)
        let diffs = (0..<cells.count).map { abs(cells[$0] - p[$0]) }
        let noise = diffs.sorted()[diffs.count / 2]
        let limit = max(3, noise * 3)
        let changed = diffs.map { $0 > limit }
        let share = Double(changed.filter { $0 }.count) / Double(changed.count)
        let decay = Float(exp(-dt / tau))
        let steady = 1 / (1 - decay)                                   // a cell that changes in every frame
        func rate(_ i: Int) -> Float { activity[i] / steady }

        if share > 0.06 {                                              // a new slide or a scroll: nothing to learn
            if cut == nil { cut = (t, (0..<cells.count).map { rate($0) >= activeRate }) }
            return report(t)
        }
        for i in 0..<cells.count {
            activity[i] = activity[i] * decay + (changed[i] ? 1 : 0)
            if changed[i] { lastChanged[i] = t }
            recent[i] = recent[i] * Float(exp(-dt / 2)) + (changed[i] ? 1 : 0)
            let on = rate(i) >= activeRate
            if on && activeSince[i] == .infinity { activeSince[i] = t } else if !on { activeSince[i] = .infinity; survived[i] = false }
        }
        if let c = cut, t - c.t >= 5 {                                 // after a slide change: what kept going is a camera,
            var inBox = 0, keptInBox = 0                               // what stopped went with the slide (a GIF): forget it
            for i in 0..<cells.count where c.before[i] {
                let still = lastChanged[i] > c.t + 1                   // changed again after the slide had changed
                if still { survived[i] = true } else { activity[i] *= 0.25 }
                if let cur = current, cur.rect.contains(CGPoint(x: (Double(i % cols) + 0.5) / Double(cols), y: (Double(i / cols) + 0.5) / Double(rows))) {
                    inBox += 1; if still { keptInBox += 1 }
                }
            }
            if inBox > 0, Double(keptInBox) / Double(inBox) < 0.1 { current = nil; pending = nil }   // the box went with the slide (a still lecturer still moves a little)
            cut = nil
        }
        // nothing new right after a slide change: what kept going and what went with the slide is known only 5 s later
        if cut == nil, let best = bestPatch(t, (0..<cells.count).map { rate($0) }, cells) { accept(best.rect, best.confidence, t) }
        return report(t)
    }

    private func report(_ t: Double) -> Found? {
        if let c = current, t - c.seen > hold { current = nil }
        return current.map { Found(rect: $0.rect, confidence: $0.confidence) }
    }

    /// Keep the shown box steady: small moves are smoothed, a different place must show up three times in a row.
    private func accept(_ r: CGRect, _ confidence: Double, _ t: Double) {
        if let c = current, inside(r, c.rect) >= 0.7 {                // part of the same camera: keep the box
            current = (c.rect, max(confidence, c.confidence * 0.98), t)
            pending = nil
            return
        }
        if let c = current, iou(c.rect, r) >= 0.4 {
            let k: CGFloat = 0.35
            let m = CGRect(x: c.rect.minX + (r.minX - c.rect.minX) * k, y: c.rect.minY + (r.minY - c.rect.minY) * k,
                           width: c.rect.width + (r.width - c.rect.width) * k, height: c.rect.height + (r.height - c.rect.height) * k)
            current = (m, max(confidence, c.confidence * 0.98), t)
            pending = nil
            return
        }
        if let p = pending, iou(p.rect, r) >= 0.5 { pending = (r, p.count + 1) } else { pending = (r, 1) }
        if pending!.count >= 3 { current = (r, confidence, t); pending = nil }
    }

    /// The most camera-like patch of lasting change, as a rectangle snapped to the inset's edges.
    private func bestPatch(_ t: Double, _ rates: [Float], _ now: [Float]) -> (rect: CGRect, confidence: Double)? {
        let on = rates.map { $0 >= activeRate }
        let closed = erode(dilate(on))                                 // the person's moving parts as one patch
        var seen = [Bool](repeating: false, count: closed.count)
        var best: (rect: CGRect, confidence: Double)?
        for start in 0..<closed.count where closed[start] && !seen[start] {
            var stack = [start], cells: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                cells.append(i)
                let r = i / cols, c = i % cols
                for dr in -1...1 {
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let rr = r + dr, cc = c + dc
                        guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                        let j = rr * cols + cc
                        if closed[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            let rs = cells.map { $0 / cols }, cs = cells.map { $0 % cols }
            let c0 = cs.min()!, c1 = cs.max()!, r0 = rs.min()!, r1 = rs.max()!
            let w = c1 - c0 + 1, h = r1 - r0 + 1
            let area = Double(w * h) / Double(cols * rows), fill = Double(cells.count) / Double(w * h)
            let aspect = Double(w) / Double(h)
            guard area >= 0.003, area <= 0.25, fill >= 0.2, aspect >= 0.3, aspect <= 4 else { continue }
            let live = cells.filter { on[$0] }
            guard !live.isEmpty else { continue }
            let meanRate = Double(live.reduce(Float(0)) { $0 + rates[$1] }) / Double(live.count)
            let age = t - (live.map { activeSince[$0] }.min() ?? t)
            let movingNow = Double(live.filter { recent[$0] >= 1.3 }.count) / Double(live.count)   // changed in several of the last frames
            guard meanRate >= 0.12, age >= 3, movingNow >= 0.2 else { continue }   // still moving now, not one change fading
            let corner = min(Double(c0), Double(cols - 1 - c1)) / Double(cols) < 0.25 && min(Double(r0), Double(rows - 1 - r1)) / Double(rows) < 0.3
            let kept = Double(live.filter { survived[$0] }.count) / Double(live.count) > 0.3
            // a small patch near a corner is shown at once; anything else (a video in a slide) must keep going across a
            // slide change first; whatever repeats itself exactly is an animation, never a camera
            guard (corner && area <= 0.06) || kept, !periodic(c0, c1, r0, r1, now) else { continue }
            let confidence = min(1, sqrt(meanRate) * min(1, age / 10) * (0.6 + 0.4 * fill) * (kept ? 1.2 : 1))
            if best == nil || confidence > best!.confidence { best = (snap(c0, c1, r0, r1), confidence) }
        }
        return best
    }

    /// The patch returned to exactly an earlier picture (an animated GIF looping); a camera never does.
    private func periodic(_ c0: Int, _ c1: Int, _ r0: Int, _ r1: Int, _ now: [Float]) -> Bool {
        guard history.count >= 6 else { return false }
        for h in history.dropLast(2) {
            var sum: Float = 0
            for r in r0...r1 { for c in c0...c1 { sum += abs(now[r * cols + c] - h[r * cols + c]) } }
            if sum / Float((r1 - r0 + 1) * (c1 - c0 + 1)) < 1.0 { return true }
        }
        return false
    }

    /// Moves each side of the patch's box outward (or a little inward) to the strongest long straight edge nearby —
    /// the border of the camera inset — or to the picture's own edge.
    private func snap(_ c0: Int, _ c1: Int, _ r0: Int, _ r1: Int) -> CGRect {
        var x0 = c0 * 2, x1 = (c1 + 1) * 2, y0 = r0 * 2, y1 = (r1 + 1) * 2   // fine pixels; x1/y1 exclusive
        let growX = max(4, x1 - x0, fw * 12 / 100), growY = max(4, y1 - y0, fh * 12 / 100)
        func vStrength(_ x: Int) -> Double {                           // edge between columns x-1 and x
            guard x > 0, x < fw else { return 1 }                      // the picture's own edge
            guard y1 > y0 else { return 0 }
            var hit = 0
            for y in y0..<y1 where abs(fine[y * fw + x] - fine[y * fw + x - 1]) > 10 { hit += 1 }
            return Double(hit) / Double(y1 - y0)
        }
        func hStrength(_ y: Int) -> Double {
            guard y > 0, y < fh else { return 1 }
            guard x1 > x0 else { return 0 }
            var hit = 0
            for x in x0..<x1 where abs(fine[y * fw + x] - fine[(y - 1) * fw + x]) > 10 { hit += 1 }
            return Double(hit) / Double(x1 - x0)
        }
        func pick(_ from: Int, _ to: Int, _ strength: (Int) -> Double, _ fallback: Int) -> Int {
            var best = fallback, bestS = 0.55
            let step = from <= to ? 1 : -1
            var p = from
            while true {
                let s = strength(p)
                if s > bestS + 0.05 { best = p; bestS = s }
                if p == to { break }
                p += step
            }
            return best
        }
        for _ in 0..<2 {                    // a side may move in by 2 px, but never past 2 px from the other side
            x0 = pick(max(0, min(fw, x0 + 2, x1 - 2)), max(0, x0 - growX), vStrength, x0)
            x1 = pick(min(fw, max(0, x1 - 2, x0 + 2)), min(fw, x1 + growX), vStrength, x1)
            y0 = pick(max(0, min(fh, y0 + 2, y1 - 2)), max(0, y0 - growY), hStrength, y0)
            y1 = pick(min(fh, max(0, y1 - 2, y0 + 2)), min(fh, y1 + growY), hStrength, y1)
        }
        guard x1 > x0, y1 > y0 else {       // can't happen now — but a box inside out must never reach a range
            return CGRect(x: Double(c0) / Double(cols), y: Double(r0) / Double(rows),
                          width: Double(c1 - c0 + 1) / Double(cols), height: Double(r1 - r0 + 1) / Double(rows))
        }
        return CGRect(x: Double(x0) / Double(fw), y: Double(y0) / Double(fh), width: Double(x1 - x0) / Double(fw), height: Double(y1 - y0) / Double(fh))
    }

    private func dilate(_ m: [Bool]) -> [Bool] {
        var out = m
        for r in 0..<rows { for c in 0..<cols where !m[r * cols + c] {
            outer: for dr in -1...1 { for dc in -1...1 {
                let rr = r + dr, cc = c + dc
                if rr >= 0, rr < rows, cc >= 0, cc < cols, m[rr * cols + cc] { out[r * cols + c] = true; break outer }
            } }
        } }
        return out
    }

    private func erode(_ m: [Bool]) -> [Bool] {
        var out = m
        for r in 0..<rows { for c in 0..<cols where m[r * cols + c] {
            outer: for dr in -1...1 { for dc in -1...1 {
                let rr = r + dr, cc = c + dc
                if rr >= 0, rr < rows, cc >= 0, cc < cols, !m[rr * cols + cc] { out[r * cols + c] = false; break outer }
            } }
        } }
        return out
    }

    private func downscale(_ image: CGImage) -> [Float]? {
        var buf = [UInt8](repeating: 0, count: fw * fh)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: fw, height: fh))
            return true
        }
        return ok ? buf.map { Float($0) } : nil
    }
}

/// How much of `a` lies inside `b`.
private func inside(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull, a.width > 0, a.height > 0 else { return 0 }
    return Double(i.width * i.height) / Double(a.width * a.height)
}

private func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
    let inter = Double(i.width * i.height)
    return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
}
