import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

final class AppState: ObservableObject {
    @Published var trusted = false
    @Published var phones: [PhoneInfo] = []
    @Published var computer = ""
    @Published var hostURL = ""
    @Published var ipURL: String?
    @Published var useIP = UserDefaults.standard.bool(forKey: "useIP") { didSet { UserDefaults.standard.set(useIP, forKey: "useIP") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var activity = ""
    @Published var failure: String?

    var pairURL: String { useIP ? (ipURL ?? hostURL) : hostURL }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private let pairing = Pairing()
    private lazy var server = Server(pairing: pairing)
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var trustTimer: Timer?
    private var activityClear: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        refreshAddresses()
        state.trusted = AXIsProcessTrusted()

        server.onPhones = { [weak self] phones in self?.state.phones = phones; self?.updateIcon() }
        server.onActivity = { [weak self] label in self?.showActivity(label) }
        server.onFailure = { [weak self] msg in self?.state.failure = msg; self?.showWindow() }
        server.start(port: Env.port)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // Re-check permission and addresses in the background; cheap.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = AXIsProcessTrusted()
            if t != self.state.trusted { self.state.trusted = t }
            if self.window?.isVisible == true { self.refreshAddresses() }
        }

        if let path = Env.all["CHILL_SNAPSHOT"] { return snapshot(to: path) }
        if Env.headless { return }
        if !state.trusted { requestAccessibility() }
        // First launch, or permission missing: show the pairing window. Otherwise stay quietly in the menu bar.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") || !state.trusted {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showWindow()
        }
    }

    /// Opening the app again (Finder, Spotlight) brings up the pairing window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func refreshAddresses() {
        let c = pairing.computerName, h = pairing.hostURL, i = pairing.ipURL
        if state.computer != c { state.computer = c }
        if state.hostURL != h { state.hostURL = h }
        if state.ipURL != i { state.ipURL = i }
    }

    private func updateIcon() {
        let connected = !state.phones.isEmpty
        let names = connected
            ? ["rectangle.and.hand.point.up.left.fill", "hand.point.up.left.fill"]
            : ["rectangle.and.hand.point.up.left", "hand.point.up.left"]
        let img = names.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Chillpad") }.first
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = connected ? "Chillpad: \(state.phones[0].device) connected" : "Chillpad: waiting for your phone"
    }

    private func showActivity(_ label: String) {
        state.activity = label
        activityClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.state.activity = "" }
        activityClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if let p = state.phones.first {
            status = p.rtt.map { "\(p.device) connected · \($0) ms" } ?? "\(p.device) connected"
        } else {
            status = "Waiting for your phone"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        add(menu, "Pair a Phone…", #selector(showWindowAction))
        if !state.trusted { add(menu, "Allow Accessibility Access…", #selector(openAccessibility)) }
        menu.addItem(.separator())
        add(menu, "Launch at Login", #selector(toggleLogin)).state = state.launchAtLogin ? .on : .off
        add(menu, "Reset Pairing…", #selector(resetPairing))
        menu.addItem(.separator())
        add(menu, "Quit Chillpad", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showWindowAction() { showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        state.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @objc func resetPairing() {
        let a = NSAlert()
        a.messageText = "Reset pairing?"
        a.informativeText = "Every phone will be disconnected and has to scan a new QR code. The Chillpad icon on your phone's Home Screen will stop working until you add it again."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        pairing.reset()
        server.disconnectAll()
        refreshAddresses()
        showWindow()
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc func openAccessibility() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Renders the pairing view to a PNG and quits (used to check the layout without a screen).
    private func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let view = PairView(state: self.state, openAccessibility: {}, toggleLogin: {})
                .background(Color(white: 0.14)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Pairing window

    func showWindow() {
        refreshAddresses()
        if window == nil {
            let view = PairView(state: state, openAccessibility: { [weak self] in self?.openAccessibility() },
                                toggleLogin: { [weak self] in self?.toggleLogin() })
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Chillpad"
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: view)
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI

struct PairView: View {
    @ObservedObject var state: AppState
    var openAccessibility: () -> Void
    var toggleLogin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 12) {
                if let img = Pairing.qr(state.pairURL) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(14).background(RoundedRectangle(cornerRadius: 18).fill(.white))
                }
                Picker("", selection: $state.useIP) {
                    Text("Mac name").tag(false)
                    Text("IP address").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200).disabled(state.ipURL == nil)
                Text(state.pairURL).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).multilineTextAlignment(.center).frame(width: 248)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chillpad").font(.system(size: 26, weight: .bold))
                    Text("Your phone as a trackpad for \(state.computer)").foregroundStyle(.secondary)
                }

                if let failure = state.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }

                VStack(spacing: 0) {
                    row(icon: "hand.raised.fill",
                        title: "Accessibility",
                        detail: state.trusted ? "Chillpad can move the pointer." : "Needed so your phone can move the pointer.",
                        badge: state.trusted ? "Allowed" : nil, good: state.trusted) {
                        if !state.trusted { Button("Allow…", action: openAccessibility).controlSize(.small) }
                    }
                    Divider().padding(.leading, 40)
                    row(icon: "iphone",
                        title: state.phones.first.map { "\($0.device) connected" } ?? "No phone connected",
                        detail: phoneDetail,
                        badge: state.phones.isEmpty ? nil : "Live", good: true) { EmptyView() }
                    Divider().padding(.leading, 40)
                    row(icon: "power", title: "Launch at login", detail: "Always ready in the menu bar.", badge: nil, good: true) {
                        Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: { _ in toggleLogin() }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))

                VStack(alignment: .leading, spacing: 7) {
                    step(1, "Put your phone on the same Wi‑Fi as this Mac.")
                    step(2, "Scan the code with the Camera app.")
                    step(3, "In Safari tap Share, then Add to Home Screen.")
                }
                .font(.callout)

                Text(state.activity.isEmpty ? " " : state.activity)
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            .frame(width: 330, alignment: .leading)
        }
        .padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 22)
    }

    private var phoneDetail: String {
        guard let p = state.phones.first else { return "Scan the code to pair." }
        var parts: [String] = []
        if let r = p.rtt { parts.append("\(r) ms round trip") }
        parts.append("\(Int((p.onTime * 100).rounded()))% of packets on time")
        return parts.joined(separator: " · ")
    }

    private func row<T: View>(icon: String, title: String, detail: String, badge: String?, good: Bool,
                              @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let badge {
                Text(badge).font(.caption.weight(.semibold)).foregroundStyle(good ? .green : .orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((good ? Color.green : Color.orange).opacity(0.15)))
            }
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 14)
            Text(text)
        }
    }
}
