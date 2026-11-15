import AppKit
import ApplicationServices
import CoreGraphics

/// Milliseconds on a monotonic clock.
@inline(__always) func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

enum Env {
    static let all = ProcessInfo.processInfo.environment
    /// Log every injected event to stderr.
    static let debug = all["CHILL_DEBUG"] != nil
    /// Log only: never touch the real pointer or keyboard (used by tests).
    static let dry = all["CHILL_DRY"] != nil
    static let headless = all["CHILL_HEADLESS"] != nil
    /// Turn off late-packet coasting (to compare against in tests).
    static let noSmooth = all["CHILL_NO_SMOOTH"] != nil
    static let port = UInt16(all["CHILL_PORT"] ?? "") ?? 8787
}

private let logStart = nowMs()
func dlog(_ s: @autoclosure () -> String) {
    guard Env.debug else { return }
    fputs(String(format: "%9.1f %@\n", nowMs() - logStart, s()), stderr)
}

/// Posts native pointer, scroll and keyboard events. Only ever used from the network queue.
final class Input {
    private let src = CGEventSource(stateID: .hidSystemState)
    private let doubleClickInterval = NSEvent.doubleClickInterval

    init() {
        // Don't freeze the physical trackpad/keyboard after we post synthetic events.
        src?.localEventsSuppressionInterval = 0
    }

    // MARK: Displays

    private var cachedDisplays: [CGRect] = []
    private var displaysStamp = 0.0
    private func displays() -> [CGRect] {
        let now = nowMs()
        if now - displaysStamp < 1000, !cachedDisplays.isEmpty { return cachedDisplays }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)
        cachedDisplays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        displaysStamp = now
        return cachedDisplays
    }

    private func clamp(_ p: CGPoint, from old: CGPoint) -> CGPoint {
        let ds = displays()
        if ds.contains(where: { $0.contains(p) }) { return p }
        let d = ds.first(where: { $0.contains(old) }) ?? ds.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: min(max(p.x, d.minX), d.maxX - 1), y: min(max(p.y, d.minY), d.maxY - 1))
    }

    // MARK: Pointer

    private var pos = CGEvent(source: nil)?.location ?? .zero
    private var lastPosted = CGEvent(source: nil)?.location ?? .zero

    /// If the user moved the real trackpad since our last event, continue from there.
    private func syncPos() {
        guard let real = CGEvent(source: nil)?.location else { return }
        if abs(real.x - lastPosted.x) > 1.5 || abs(real.y - lastPosted.y) > 1.5 {
            pos = real
            lastPosted = real
        }
    }

    private var held: Set<String> = []
    private var clickCount = 1
    private var lastDownTime = 0.0
    private var lastDownPos = CGPoint.zero
    private var lastDownButton = ""

    func move(_ dx: Double, _ dy: Double, tag: String = "") {
        dlog(String(format: "m %.2f %.2f %@", dx, dy, tag))
        if Env.dry { return }
        syncPos()
        pos = clamp(CGPoint(x: pos.x + dx, y: pos.y + dy), from: pos)
        let type: CGEventType
        let btn: CGMouseButton
        if held.contains("l") { type = .leftMouseDragged; btn = .left }
        else if held.contains("r") { type = .rightMouseDragged; btn = .right }
        else if held.contains("o") { type = .otherMouseDragged; btn = .center }
        else { type = .mouseMoved; btn = .left }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: btn) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        if !held.isEmpty { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        e.post(tap: .cghidEventTap)
        lastPosted = pos
    }

    func button(_ b: String, down: Bool, single: Bool = false) {
        dlog("\(down ? "d" : "u") \(b)\(single ? " single" : "")")
        if down {
            if held.contains(b) { return }
            held.insert(b)
        } else {
            if !held.contains(b) { return }
            held.remove(b)
        }
        if Env.dry { return }
        syncPos()
        if down {
            let now = nowMs() / 1000
            let near = hypot(pos.x - lastDownPos.x, pos.y - lastDownPos.y) < 8
            if !single, b == lastDownButton, near, now - lastDownTime < doubleClickInterval {
                clickCount = min(clickCount + 1, 3)
            } else {
                clickCount = 1
            }
            lastDownTime = now; lastDownPos = pos; lastDownButton = b
        }
        let type: CGEventType
        switch (b, down) {
        case ("r", true): type = .rightMouseDown
        case ("r", false): type = .rightMouseUp
        case ("o", true): type = .otherMouseDown
        case ("o", false): type = .otherMouseUp
        case (_, true): type = .leftMouseDown
        default: type = .leftMouseUp
        }
        let mb: CGMouseButton = b == "r" ? .right : (b == "o" ? .center : .left)
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: mb) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    func click(_ b: String) { button(b, down: true); button(b, down: false) }

    /// Never leave a button stuck down (phone disconnected mid-drag).
    func releaseAll() { for b in held { button(b, down: false) } }

    // MARK: Scroll

    private var accX = 0.0, accY = 0.0
    private let scrollPhaseField = CGEventField(rawValue: 99)!     // kCGScrollWheelEventScrollPhase
    private let momentumPhaseField = CGEventField(rawValue: 123)!  // kCGScrollWheelEventMomentumPhase

    /// phase: 1 began, 2 changed, 4 ended. momentum: 1 begin, 2 continue, 3 end.
    func scroll(_ dx: Double, _ dy: Double, phase: Int64, momentum: Int64, tag: String = "") {
        dlog(String(format: "s %.2f %.2f %d %d %@", dx, dy, phase, momentum, tag))
        if Env.dry { return }
        accX += dx; accY += dy
        let ix = accX.rounded(.towardZero), iy = accY.rounded(.towardZero)
        accX -= ix; accY -= iy
        if phase == 1 || phase == 4 { accX = 0; accY = 0 }
        if ix == 0, iy == 0, phase == 2 || momentum == 2 { return }
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(scrollPhaseField, value: phase)
        e.setIntegerValueField(momentumPhaseField, value: momentum)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "fwddelete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    private static let fnKeys: Set<String> = ["left", "right", "down", "up", "home", "end", "pageup", "pagedown", "fwddelete"]
    private static let arrows: Set<String> = ["left", "right", "down", "up"]

    func key(_ name: String, mods: [String]) {
        let n = name.lowercased()
        dlog("k \(n) \(mods.joined(separator: "+"))")
        guard let code = Input.keyCodes[n] else { return }
        if Env.dry { return }
        var f: CGEventFlags = []
        for m in mods {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt", "opt": f.insert(.maskAlternate)
            case "ctrl": f.insert(.maskControl)
            default: break
            }
        }
        if Input.fnKeys.contains(n) { f.insert(.maskSecondaryFn) }
        if Input.arrows.contains(n) { f.insert(.maskNumericPad) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
    }

    func type(_ s: String) {
        dlog("t \(s.count) chars")
        if Env.dry { return }
        for ch in s {
            if ch == "\n" || ch == "\r" { key("return", mods: []); continue }
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Media / system keys: 0 vol up, 1 vol down, 2 bright up, 3 bright down, 7 mute, 16 play, 17 next, 18 prev.
    func mediaKey(_ code: Int) {
        dlog("x \(code)")
        if Env.dry { return }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (code << 16) | (state << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
