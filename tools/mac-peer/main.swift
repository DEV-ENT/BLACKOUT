// TEST TOOL, not part of the app. Turns this Mac into a Blackout node over real Bluetooth LE, using the iPhone app's
// own BleLink.swift and the shared core, so an iPhone can be tested over a real radio without a second phone.
// It joins the group, prints what it sees, and answers every message it receives with "Mac got: <text>".
//
// Build and run: tools/mac-peer/run.sh  (asks once for Bluetooth permission)
import Foundation

let codeFile = CommandLine.arguments.dropFirst().first ?? ""
guard let code = (try? String(contentsOfFile: codeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
      !code.isEmpty else {
    print("usage: BlackoutMacPeer <file containing the group code>"); exit(2)
}

let name = "Mac test peer"
let nodeId = "mac-" + String(Packet.newId().prefix(8))
let crypto = GroupCrypto(code: code)
var ble: BleLink!

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)"); fflush(stdout)
}

func say(_ text: String) {
    let id = Packet.newId(), ts = Int64(Date().timeIntervalSince1970 * 1000)
    guard let c = try? crypto.seal(id: id, ts: ts, sender: nodeId, name: name, text: text) else { return }
    router.publish(Packet(id: id, ts: ts, ttl: 16, cipher: c))
    log("sent: \(text)")
}

let router = MeshRouter(send: { peer, p in ble.send(peer, p) }, deliver: { p in
    guard let m = crypto.open(p) else { log("relayed a packet from another group (\(p.id))"); return }
    log("received from \(m.name) (\(m.text.utf8.count) bytes): \(m.text)")
    if m.sender != nodeId { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { say("Mac got: \(m.text)") } }
})

ble = BleLink(code: code, nodeId: nodeId, router: router) { log($0) }
log("node \(nodeId) starting; waiting for Bluetooth")
ble.start()
say("Hello from the Mac test peer") // stored, then delivered as soon as a link comes up
say("Long test START " + String(repeating: "0123456789", count: 60) + " END") // needs many Bluetooth chunks
RunLoop.main.run()
