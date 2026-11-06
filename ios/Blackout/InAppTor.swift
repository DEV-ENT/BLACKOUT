import Foundation
import CTor
import TorCore

/// Tor inside DarkProof (iCepa's Tor.framework) for "Connect through Tor" (spec/FORMAT.md, "Tor"), so no other app is
/// needed. Tor can run only once per launch, so once started it keeps running until the app quits; with the switch
/// off, nothing uses it. Whether Tor is ready is found out by NostrLink's Tor check through it. Touched only on `q`.
final class InAppTor {
    static let shared = InAppTor()
    private let q = DispatchQueue(label: "tor")
    private var thread: TorThread?
    private var port = 0

    /// A session configuration that goes only through Tor's SOCKS port. Starts Tor the first time.
    func sessionConfiguration() -> URLSessionConfiguration? {
        q.sync {
            if thread == nil { start() }
            guard port > 0 else { return nil }
            let c = URLSessionConfiguration.ephemeral
            // "localhost", not 127.0.0.1: with the address, real devices resolve host names outside Tor (Tor.framework's note).
            c.connectionProxyDictionary = [kCFProxyTypeKey: kCFProxyTypeSOCKS,
                                           kCFStreamPropertySOCKSProxyHost: "localhost",
                                           kCFStreamPropertySOCKSProxyPort: port]
            return c
        }
    }

    private func start() {
        guard let p = Self.freePort() else { return }
        let fm = FileManager.default
        var dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var noBackup = URLResourceValues(); noBackup.isExcludedFromBackup = true
        try? dir.setResourceValues(noBackup)
        let c = TorConfiguration()
        c.ignoreMissingTorrc = true
        c.clientOnly = true
        c.dataDirectory = dir // keeps what Tor learned about the network, so later starts are faster
        c.socksPort = UInt(p)
        let t = TorThread(configuration: c)
        t.start()
        thread = t; port = p
    }

    /// A TCP port on 127.0.0.1 that nothing listens on right now.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return ok ? Int(UInt16(bigEndian: a.sin_port)) : nil
    }
}
