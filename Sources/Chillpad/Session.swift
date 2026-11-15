import Foundation

// The phone stamps every stream packet with its own clock. Wi‑Fi delivers them with a
// little jitter and, now and then, a stall of tens of milliseconds. ClockSync learns the
// phone→Mac clock offset from the fastest packets so we can tell exactly how late a
// packet is, and StreamSmoother fills a late gap by coasting on the last known velocity,
// then pays the guess back out of the packets that follow. Packets that arrive on time
// pass straight through untouched, so smoothing never adds latency.

final class ClockSync {
    private(set) var offset = Double.infinity   // macTime - phoneTime of the fastest path seen
    var ready: Bool { offset.isFinite }
    private(set) var total = 0, late = 0

    func observe(phone t: Double, arrival: Double, slack: Double) {
        let o = arrival - t
        if o < offset { offset = o } else { offset += min(o - offset, 0.05) }  // drift slowly upward
        total += 1
        if o - offset > slack { late += 1 }
        if total >= 600 { total /= 2; late /= 2 }   // rolling window
    }
    /// Share of recent packets that arrived on time, 0...1.
    var onTime: Double { total < 30 ? 1 : 1 - Double(late) / Double(total) }
}

final class StreamSmoother {
    private let clock: ClockSync
    private(set) var live = false
    private var count = 0
    private var lastT = 0.0           // phone clock of the newest packet
    private var interval = 16.7       // phone's packet cadence, learned
    private var vx = 0.0, vy = 0.0    // units per ms on the phone clock
    private var debtX = 0.0, debtY = 0.0   // coasted distance not yet paid back
    private var shownMs = 0.0         // coasting already emitted since the newest packet
    private var hist: [(t: Double, dx: Double, dy: Double)] = []   // last ~40 ms of packets
    private let easeBack: Bool        // pointer: glide back if we overshot. scroll: never reverse.
    private static let maxCoastMs = 48.0
    private static let window = 40.0

    init(clock: ClockSync, easeBack: Bool) { self.clock = clock; self.easeBack = easeBack }

    private var slack: Double { max(4, interval * 0.4) }

    /// A real packet. Returns the movement to apply now.
    func packet(_ dx: Double, _ dy: Double, t: Double, now: Double) -> (Double, Double) {
        clock.observe(phone: t, arrival: now, slack: slack)
        let dt = t - lastT
        if !live || dt > 120 || dt < 0 {
            live = true; count = 0; debtX = 0; debtY = 0
            hist.removeAll(keepingCapacity: true)
        } else {
            count += 1
            if dt >= 5, dt < 60 { interval += (dt - interval) * 0.2 }   // ignore same-frame pairs
        }
        lastT = t
        shownMs = 0
        // Velocity over a short window, so uneven packet spacing can't produce spikes.
        hist.append((t, dx, dy))
        while let f = hist.first, t - f.t > StreamSmoother.window { hist.removeFirst() }
        vx = 0; vy = 0
        if hist.count >= 3, let f = hist.first, t - f.t >= 12 {
            for h in hist.dropFirst() { vx += h.dx; vy += h.dy }
            vx /= t - f.t; vy /= t - f.t
        }
        return (settle(dx, &debtX), settle(dy, &debtY))
    }

    /// Pay coasted distance back out of the real movement that follows.
    private func settle(_ d: Double, _ debt: inout Double) -> Double {
        if debt == 0 { return d }
        var out = d
        if d != 0, (d > 0) == (debt > 0) {
            let use = min(abs(d), abs(debt)) * (d > 0 ? 1 : -1)
            out -= use; debt -= use
        }
        if debt != 0 {   // we coasted past where the finger really went
            if easeBack {
                let back = abs(debt) < 0.5 ? debt : debt * 0.5
                out -= back; debt -= back
            } else if d != 0 {
                debt = 0   // direction changed: a touch of extra scroll is invisible, a reversal is not
            }
        }
        return out
    }

    /// Called every few ms. Returns coasting movement if the next packet is overdue.
    func tick(now: Double) -> (Double, Double)? {
        guard live, count >= 3, clock.ready, !Env.noSmooth else { return nil }
        let lateBy = (now - clock.offset) - (lastT + interval) - slack
        guard lateBy > 0 else { return nil }
        let target = min(lateBy, StreamSmoother.maxCoastMs)
        guard target > shownMs + 0.5, hypot(vx, vy) > 0.08 else { return nil }
        // Confidence fades linearly to zero over maxCoastMs: integrate v·(1 − t/max).
        let cap = StreamSmoother.maxCoastMs
        let f = { (ms: Double) in ms - ms * ms / (2 * cap) }
        let dms = f(target) - f(shownMs)
        shownMs = target
        let ex = vx * dms, ey = vy * dms
        debtX += ex; debtY += ey
        return (ex, ey)
    }

    func end() { live = false; debtX = 0; debtY = 0; vx = 0; vy = 0; hist.removeAll(keepingCapacity: true) }
}

/// One connected phone: turns protocol messages into input events.
final class PhoneSession {
    private let input: Input
    private let queue: DispatchQueue
    private let reply: (String) -> Void
    let clock = ClockSync()
    private lazy var pointer = StreamSmoother(clock: clock, easeBack: true)
    private lazy var scroller = StreamSmoother(clock: clock, easeBack: false)
    private var fingers = 0

    var device = "iPhone"
    var rtt: Int?
    var onActivity: ((String) -> Void)?
    var onInfo: (() -> Void)?

    private var pendMX = 0.0, pendMY = 0.0, pendMoveCoast = false
    private var pendSX = 0.0, pendSY = 0.0, pendScrollCoast = false
    private var scrolling = false
    private var momentum: (vx: Double, vy: Double, last: Double, first: Bool)?
    private var timer: DispatchSourceTimer?

    init(input: Input, queue: DispatchQueue, reply: @escaping (String) -> Void) {
        self.input = input; self.queue = queue; self.reply = reply
    }

    // MARK: Stream packets (binary): [op u8][dx f32][dy f32][phoneTime f64], little endian

    func binary(_ b: ArraySlice<UInt8>) {
        guard b.count >= 17 else { return }
        let s = b.startIndex
        let dx = clampNum(Double(f32(b, s + 1)), 4000), dy = clampNum(Double(f32(b, s + 5)), 4000)
        let t = f64(b, s + 9)
        guard t.isFinite else { return }
        let now = nowMs()
        switch b[s] {
        case 1:
            let (ox, oy) = pointer.packet(dx, dy, t: t, now: now)
            pendMX += ox; pendMY += oy
            if dx != 0 || dy != 0 { onActivity?("Moving") }
        case 2:
            stopMomentum()
            let (ox, oy) = scroller.packet(dx, dy, t: t, now: now)
            pendSX += ox; pendSY += oy
            if dx != 0 || dy != 0 { onActivity?("Scrolling") }
        default: return
        }
        ensureTimer()
    }

    /// Emit whatever accumulated while draining the socket: one event, not a burst.
    func flush() {
        if pendMX != 0 || pendMY != 0 {
            input.move(pendMX, pendMY, tag: pendMoveCoast ? "coast" : "")
            pendMX = 0; pendMY = 0
        }
        pendMoveCoast = false
        if pendSX != 0 || pendSY != 0 || (scroller.live && !scrolling) {
            if scroller.live {
                input.scroll(pendSX, pendSY, phase: scrolling ? 2 : 1, momentum: 0, tag: pendScrollCoast ? "coast" : "")
                scrolling = true
            }
            pendSX = 0; pendSY = 0
        }
        pendScrollCoast = false
    }

    // MARK: Everything else (JSON text)

    private static let buttons: Set<String> = ["l", "r", "o"]
    private static let modNames: Set<String> = ["cmd", "shift", "alt", "opt", "ctrl"]
    private static let media: Set<Int> = [0, 1, 2, 3, 7, 16, 17, 18]

    func text(_ s: String) {
        guard let data = s.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let op = m.first as? String else { return }
        flush()   // keep moves ordered before clicks and keys
        let a = m.count > 1 ? m[1] : NSNull()
        let b = m.count > 2 ? m[2] : NSNull()
        switch op {
        case "f":   // finger count changed
            let n = (a as? NSNumber)?.intValue ?? 0
            if n > fingers { stopMomentum() }   // a new finger landing catches the glide, like a real trackpad
            fingers = n
            if n != 1 { pointer.end() }
            if n == 0, scroller.live {   // safety net: a scroll that never sent its end
                scroller.end()
                if scrolling { input.scroll(0, 0, phase: 4, momentum: 0); scrolling = false }
            }
        case "c":
            if let k = a as? String, PhoneSession.buttons.contains(k) {
                input.click(k)
                onActivity?(k == "r" ? "Right click" : k == "o" ? "Middle click" : "Click")
            }
        case "d":
            if let k = a as? String, PhoneSession.buttons.contains(k) { input.button(k, down: true, single: true); onActivity?("Dragging") }
        case "u":
            if let k = a as? String, PhoneSession.buttons.contains(k) { input.button(k, down: false) }
        case "se":
            scroller.end()
            if scrolling { input.scroll(0, 0, phase: 4, momentum: 0); scrolling = false }
            startMomentum(clampNum(num(a), 20), clampNum(num(b), 20))
        case "k":
            guard let k = (a as? String)?.lowercased(), Input.keyCodes[k] != nil else { return }
            let mods = ((b as? String) ?? "").split(separator: "+").map(String.init)
            guard mods.allSatisfy(PhoneSession.modNames.contains) else { return }
            input.key(k, mods: mods)
            onActivity?(mods.isEmpty ? k : mods.joined(separator: " ") + " " + k)
        case "t":
            if let str = a as? String, !str.isEmpty { input.type(String(str.prefix(2000))); onActivity?("Typing") }
        case "x":
            let n = (a as? NSNumber)?.intValue ?? -1
            if PhoneSession.media.contains(n) { input.mediaKey(n); onActivity?("Media key") }
        case "z":
            let up = num(a) > 0
            input.key(up ? "=" : "-", mods: ["cmd"])
            onActivity?(up ? "Zoom in" : "Zoom out")
        case "p":
            reply("[\"p\",\(num(a))]")
            if let r = b as? NSNumber { rtt = r.intValue; onInfo?() }
        case "hello":
            device = String(((a as? String) ?? "iPhone").prefix(40))
            onInfo?()
        default: break
        }
    }

    func close() {
        flush()
        timer?.cancel(); timer = nil
        pointer.end(); scroller.end()
        if scrolling { input.scroll(0, 0, phase: 4, momentum: 0); scrolling = false }
        if momentum != nil { input.scroll(0, 0, phase: 0, momentum: 3); momentum = nil }
        input.releaseAll()
    }

    // MARK: Scroll momentum, run on the Mac so the glide is perfectly even

    private func startMomentum(_ vx: Double, _ vy: Double) {
        stopMomentum()
        guard hypot(vx, vy) >= 0.15 else { return }   // px per ms
        momentum = (vx, vy, nowMs(), true)
        ensureTimer()
    }

    private func stopMomentum() {
        guard momentum != nil else { return }
        momentum = nil
        input.scroll(0, 0, phase: 0, momentum: 3)
    }

    // MARK: 250 Hz service timer, alive only while something is in motion

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4), leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        let now = nowMs()
        if let (ex, ey) = pointer.tick(now: now) { pendMX += ex; pendMY += ey; pendMoveCoast = true }
        if let (ex, ey) = scroller.tick(now: now) { pendSX += ex; pendSY += ey; pendScrollCoast = true }
        flush()
        if var m = momentum {
            let dt = now - m.last
            if dt >= 7.5 {   // ~120 Hz
                let decay = exp(-dt / 316)
                m.vx *= decay; m.vy *= decay; m.last = now
                if hypot(m.vx, m.vy) < 0.02 {
                    stopMomentum()
                } else {
                    input.scroll(m.vx * dt, m.vy * dt, phase: 0, momentum: m.first ? 1 : 2)
                    m.first = false
                    momentum = m
                }
            }
        }
        if !pointer.live, !scroller.live, momentum == nil { timer?.cancel(); timer = nil }
    }

    // MARK: Helpers

    private func num(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private func clampNum(_ v: Double, _ lim: Double) -> Double { v.isFinite ? max(-lim, min(lim, v)) : 0 }
    private func f32(_ b: ArraySlice<UInt8>, _ o: Int) -> Float {
        Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
    }
    private func f64(_ b: ArraySlice<UInt8>, _ o: Int) -> Double {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << UInt64(8 * i) }
        return Double(bitPattern: v)
    }
}
