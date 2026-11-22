import AppKit

/// Talks to Juno (the voice dictation app) on this Mac, so the phone's mic button can
/// dictate and run voice commands through it. Local distributed notifications only.
///
///   out  app.juno.remote  ["action": press | release | command | cancel | wakeOn | wakeOff | hello]
///   in   app.juno.state   ["phase", "mode", "handsFree", "wake", "level"]
///
/// Chillpad works the same without Juno; the phone just doesn't show the mic button.
final class JunoBridge {
    static let bundleID = "app.juno.Juno"
    private static let remote = Notification.Name("app.juno.remote")
    private static let stateName = Notification.Name("app.juno.state")

    private let center = DistributedNotificationCenter.default()
    /// Called on the main queue with a JSON object to forward to every phone.
    var onUpdate: ((String) -> Void)?

    private(set) var installed = false
    private(set) var running = false
    private var state: [String: Any] = ["phase": "idle", "mode": "dictation", "handsFree": false, "wake": false]
    private var pending: [String] = []
    private var launching = false
    private var lastHeard = Date.distantPast

    func start() {
        refresh()
        center.addObserver(forName: Self.stateName, object: nil, queue: .main) { [weak self] n in
            self?.heard(n.userInfo ?? [:])
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleID else { return }
                self?.refresh()
                if name == NSWorkspace.didTerminateApplicationNotification { self?.state["phase"] = "idle" }
                self?.push()
            }
        }
        if running { post("hello") }
    }

    private func refresh() {
        installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// An action from the phone. Starts Juno first if it isn't running.
    func send(_ action: String) {
        refresh()
        guard installed else { return }
        if running && !launching {
            post(action)
            return
        }
        // Juno needs a moment to start; hold the press so the first words aren't lost.
        if action == "release", pending.last == "press" { pending.removeLast(); pending.append("tap") } else { pending.append(action) }
        guard !launching, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        launching = true
        // Juno may be running even if the process list hasn't caught up (it was just restarted).
        // Ask first; launching an app that's already open would pop its settings window.
        post("hello")
        let asked = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.launching, self.lastHeard < asked else { return }   // it answered: heard() sent the queue
            self.state["phase"] = "starting"
            self.push()
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.launchTimedOut() }
            }
        }
    }

    /// Re-check whether Juno is installed or running and tell the phones (a phone just connected).
    func refreshAndPush() {
        refresh()
        if running { post("hello") }
        push()
    }

    private func launchTimedOut() {
        guard launching else { return }
        launching = false
        pending.removeAll()
        state["phase"] = "idle"
        push()
    }

    private func heard(_ info: [AnyHashable: Any]) {
        lastHeard = Date()
        running = true
        if launching {
            launching = false
            let queued = pending
            pending.removeAll()
            for a in queued {
                if a == "tap" { post("press"); post("release") } else { post(a) }
            }
        }
        if info["phase"] == nil, let level = info["level"] as? Double {   // level-only tick
            onUpdate?("[\"vl\",\(String(format: "%.3f", level))]")
            return
        }
        for (k, v) in info { if let k = k as? String, k != "v" { state[k] = v } }
        push()
    }

    private func post(_ action: String) {
        center.postNotificationName(Self.remote, object: nil, userInfo: ["action": action], deliverImmediately: true)
    }

    /// Current availability + state, as the phone protocol's ["vs", {...}] message.
    func snapshot() -> String {
        var s = state
        s["installed"] = installed
        s["running"] = running
        let data = (try? JSONSerialization.data(withJSONObject: ["vs", s])) ?? Data("[\"vs\",{}]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func push() { onUpdate?(snapshot()) }
}
