import AppKit
import CoreImage
import Foundation
import SystemConfiguration

/// The secret pairing code, this Mac's addresses, and the QR code that carries them.
final class Pairing {
    private let lock = NSLock()
    private var _token = ""
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chillpad")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("token")
        let saved = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if saved.count >= 10, saved.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            _token = saved
        } else {
            reset()
        }
    }

    var token: String { lock.lock(); defer { lock.unlock() }; return _token }

    /// New code: every phone has to scan again.
    func reset() {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        lock.lock(); _token = t; lock.unlock()
        try? t.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Constant-time comparison.
    func matches(_ candidate: String?) -> Bool {
        let a = Array((candidate ?? "").utf8), b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    var hostURL: String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost"
        return "http://\(name).local:\(Env.port)/pad?k=\(token)"
    }

    var ipURL: String? {
        guard let ip = Pairing.lanIP() else { return nil }
        return "http://\(ip):\(Env.port)/pad?k=\(token)"
    }

    /// First private IPv4 address, preferring Wi‑Fi (en0).
    static func lanIP() -> String? {
        var found: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((name, String(cString: host)))
            }
        }
        return (found.first { $0.0 == "en0" } ?? found.first)?.1
    }

    /// Crisp black-on-white QR code, rendered locally (no internet needed).
    static func qr(_ text: String, size: CGFloat = 520) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scale = (size / out.extent.width).rounded(.down)
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
