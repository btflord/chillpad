Chillpad — install

1. Drag Chillpad into the Applications folder.
2. Open Chillpad from Applications.
3. Allow Accessibility when asked (System Settings → Privacy & Security → Accessibility → Chillpad on).
4. Scan the QR code with your iPhone camera, then in Safari tap Share → Add to Home Screen.


If macOS says Chillpad "can't be opened" or "Apple could not verify" it

Chillpad isn't notarized by Apple, so the first launch needs one extra approval:

1. Click Done in the warning.
2. Open System Settings → Privacy & Security.
3. Scroll down to the message about Chillpad and click "Open Anyway", then confirm.

You only need to do this once.

If you see "Chillpad is damaged and can't be opened", open Terminal and run:

    xattr -dr com.apple.quarantine /Applications/Chillpad.app

then open Chillpad again.


Requirements: macOS 13 Ventura or later. Runs natively on Apple silicon (M1 and later) and on Intel Macs.
Your iPhone and Mac need to be on the same Wi‑Fi (or the Mac joined to the iPhone's Personal Hotspot).
