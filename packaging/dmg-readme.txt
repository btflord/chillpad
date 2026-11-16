Chillpad — install

1. Drag Chillpad into the Applications folder.
2. Open Chillpad from Applications.
3. Allow Accessibility when asked (System Settings → Privacy & Security → Accessibility → Chillpad on).
4. Scan the QR code with your iPhone camera, then in Safari tap Share → Add to Home Screen.


"Apple could not verify Chillpad is free of malware"

Chillpad is a free, open-source app that isn't notarized by Apple (that needs a paid
developer account), so macOS asks you to approve it once. Nothing is wrong with the app.

1. Click Done in the warning (not Move to Trash).
2. Open System Settings → Privacy & Security.
3. Scroll down to "Chillpad was blocked…" and click Open Anyway.
4. Enter your password, then click Open Anyway again.

You only need to do this once. After that Chillpad opens normally.


Prefer no warning at all? Install from Terminal instead:

    curl -fsSL https://raw.githubusercontent.com/btflord/chillpad/main/install.sh | bash

It downloads the same app from GitHub and puts it in Applications. Source code:
https://github.com/btflord/chillpad


Requirements: macOS 13 Ventura or later. Runs natively on Apple silicon (M1 and later) and on Intel Macs.
Your iPhone and Mac need to be on the same Wi‑Fi (or the Mac joined to the iPhone's Personal Hotspot).
