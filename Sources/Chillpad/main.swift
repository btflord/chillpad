import AppKit

// Chillpad: a menu bar app that lets a phone's browser act as this Mac's trackpad.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
