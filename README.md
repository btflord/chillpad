# Chillpad

Use your iPhone as a trackpad and keyboard for your Mac. The phone side is a web page in Safari, so there is nothing to install from the App Store. The Mac side is a small menu bar app.

```
iPhone (Safari) ── Wi‑Fi WebSocket ──▶ Chillpad.app ── CGEvent ──▶ macOS pointer, scroll, keys
```

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./scripts/build.sh install
```

This builds a universal `Chillpad.app`, copies it to `/Applications` and launches it.

1. macOS asks for **Accessibility** access. Turn on Chillpad in System Settings → Privacy & Security → Accessibility. Without it the pointer can't move.
2. Scan the QR code in the Chillpad window with the iPhone camera.
3. In Safari tap **Share → Add to Home Screen**. From then on Chillpad opens full screen from its own icon.

The menu bar icon shows the connection, and has Launch at Login, Pair a Phone and Reset Pairing.

## Gestures

| Gesture | Action |
| --- | --- |
| 1 finger move / tap | Move pointer / click (double-tap = double-click) |
| Hold, then move | Drag (or tap, then touch and slide) |
| 2 fingers move / tap | Scroll with momentum / right-click |
| Pinch | Zoom (⌘+ / ⌘−) |
| 3 fingers up / down | Mission Control / App windows |
| 3 fingers left / right | Switch spaces |
| 3 finger tap | Middle click |

The bottom bar has a keyboard (with esc, tab, arrows and sticky ⌘ ⌥ ⌃), Mission Control, volume and play/pause. Speed, acceleration, scroll speed, natural scrolling, touch prediction and haptics are in the settings sheet.

## How it stays responsive

- **No middlemen.** One native process receives the packets and posts the events. TCP has Nagle's algorithm off, so every packet leaves immediately.
- **Tiny packets, sent at once.** Pointer and scroll moves are 17-byte binary frames sent from inside the touch handler, not batched to the next frame.
- **Touch prediction.** On fast moves the page uses iOS's predicted touch position to run about a frame ahead. The lead is paid back as the finger slows, so total travel always equals the real finger travel.
- **Wi‑Fi hiccup smoothing.** Every packet carries the phone's clock. The Mac learns the clock offset, notices when the next packet is overdue, and coasts on the last velocity for up to 48 ms, then settles the difference from the packets that follow. Packets that arrive on time pass through untouched, so this adds no latency.
- **Scroll momentum on the Mac.** The glide after a flick is generated locally at 120 Hz, so it is even regardless of the network.
- **Fast recovery.** The page replaces a dead connection within about a second of returning to the app.

`scripts/jitter-test.mjs` replays 60 Hz pointer motion with simulated network delays against a dry-run instance. In a 50 ms stall the longest pointer freeze drops from about 66 ms to about 28 ms, with identical total travel.

## Notes

- Phone and Mac must be on the same network. With no Wi‑Fi, turn on the iPhone's Personal Hotspot and join it from the Mac.
- Pairing uses a secret code in the link, stored in `~/Library/Application Support/Chillpad/token`. Reset Pairing in the menu makes a new one.
- Traffic is plain HTTP on your local network, so use it on networks you trust.
- Bluetooth and AirDrop can't be used from a web page on iOS (Safari has no Web Bluetooth), so Wi‑Fi is the transport.
- The app is signed ad hoc unless a developer identity is in your keychain. With ad hoc signing, macOS asks for Accessibility again after each rebuild.
- If the pointer stutters about once a second, AirDrop/AirPlay discovery (AWDL) is taking the Mac's Wi‑Fi radio off-channel. Turning AirDrop off, or using 5 GHz, usually fixes it.
- Port 8787 by default. `CHILL_PORT`, `CHILL_DEBUG=1` (log events) and `CHILL_DRY=1` (log without touching the pointer) are available when running the binary directly.

## Layout

```
Sources/Chillpad/   Swift app: Server (HTTP + WebSocket), Session (protocol, smoothing), Input (CGEvent), AppUI
web/                the phone page
packaging/          Info.plist, app icon
scripts/            build.sh, make-icon.swift, jitter-test.mjs
```
