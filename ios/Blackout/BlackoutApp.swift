import SwiftUI

@main
struct BlackoutApp: App {
    init() {
        OfflineMap.shared.setUp()
        Mesh.shared.startIfSetUp() // also when iOS relaunches the app in the background for Bluetooth
        #if DEBUG
        let args = CommandLine.arguments // devicectl ... launch --console it.darkproof.mesh aiSelfTest <model file>
        if let i = args.firstIndex(of: "aiSelfTest") { LocalAi.selfTest(args.indices.contains(i + 1) ? args[i + 1] : nil) }
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}
