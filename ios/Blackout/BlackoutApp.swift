import SwiftUI
import BlackoutCore

@main
struct BlackoutApp: App {
    init() {
        OfflineMap.shared.setUp()
        Notifier.shared.setUp() // before launch ends, so tapping an alert that relaunched the app is handled
        Mesh.shared.startIfSetUp() // also when iOS relaunches the app in the background for Bluetooth
        #if DEBUG
        let args = CommandLine.arguments // devicectl ... launch --console it.darkproof.mesh aiSelfTest <model file>
        if let i = args.firstIndex(of: "aiSelfTest") { LocalAi.selfTest(args.indices.contains(i + 1) ? args[i + 1] : nil) }
        if let i = args.firstIndex(of: "interopTest"), args.indices.contains(i + 1) { InteropTest.run(args[i + 1]) }
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}

#if DEBUG
/// Debug builds only: `simctl launch booted it.darkproof.mesh interopTest 127.0.0.1:7777` links to the Android app's
/// LAN test listener, then sends a check-in with battery and position, a place and a small photo, for the mixed-group test.
enum InteropTest {
    static func run(_ address: String) {
        guard let i = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: i)...]) else { return }
        let host = String(address[..<i])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let e = Mesh.shared.engine else { DebugLog.write("interop: no group"); return }
            e.wifi.connect(host: host, port: port)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let spot = Spot(lat: 45.46420, lon: 9.19000, accuracy: 12)
                e.send(CheckIn.safe.text(battery: 64, spot: spot))
                e.send(Place(kind: .water, note: "Fountain in the square", spot: spot).text, isPublic: true)
                let img = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { c in
                    UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
                    UIColor.white.setFill(); c.fill(CGRect(x: 100, y: 60, width: 120, height: 120))
                }
                if let jpeg = PhotoShrinker.jpeg(img) { e.send(Photo.text(caption: "From the iPhone"), photo: jpeg) }
                DebugLog.write("interop: sent check-in, place, photo")
            }
        }
    }
}
#endif
