import SwiftUI
import CoreBluetooth
import BlackoutCore

/// How messages can leave this phone right now, in plain words for Home, Chat and People.
extension Engine {
    enum Reach: Equatable { case phones(Int), online(Int), radio, none }

    /// Phones in range come first; else the internet relays; else a LoRa radio; else nothing yet.
    var reach: Reach {
        if phones > 0 { return .phones(phones) }
        if relaysLinked > 0 { return .online(relaysLinked) }
        if radioLinked || meshcoreLinked { return .radio }
        return .none
    }

    /// Short line under a screen title: "2 phones in range", "Online · 4 relays", …
    var reachLine: String {
        switch reach {
        case .phones(let n): return "\(n) \(n == 1 ? "phone" : "phones") in range" + (relaysLinked > 0 ? " · online" : "")
        case .online(let n): return "Online · \(n) \(n == 1 ? "relay" : "relays")"
        case .radio: return "LoRa radio linked"
        case .none: return "No one in range right now"
        }
    }

    /// The connection details on Home and Connections, in plain words.
    var friendlyStatus: [String] {
        var out: [String] = []
        switch bluetooth {
        case .poweredOff: out.append("Bluetooth: off")
        case .unauthorized: out.append("Bluetooth: not allowed for DarkProof")
        case .unsupported: out.append("Bluetooth: not on this device")
        default: out.append("Bluetooth: " + count(bluetoothLinks, "phone"))
        }
        let apple = wifiLinks - wifiNetworkLinks
        out.append("Apple peer-to-peer: " + count(apple, "iPhone"))
        let d = UserDefaults.standard
        if !(d.object(forKey: "wifiNetwork") as? Bool ?? true) { out.append("Wi-Fi network: off") }
        else if Engine.saver { out.append("Wi-Fi network: paused by Battery saver") }
        else if localNetworkDenied { out.append("Wi-Fi network: Local Network not allowed") }
        else { out.append("Wi-Fi network: " + count(wifiNetworkLinks, "phone")) }
        out.append("LoRa (Meshtastic): " + (radioLinked ? "radio linked" : lora.hasRadio ? "looking for the radio" : "no radio paired"))
        out.append("LoRa (MeshCore): " + (meshcoreLinked ? "radio linked" : meshcore.hasRadio ? "looking for the radio" : "no radio paired"))
        if !(d.object(forKey: "internet") as? Bool ?? true) { out.append("Internet: off") }
        else if torSlow { out.append("Internet: Tor can't connect right now") }
        else if throughTor == false { out.append("Internet: starting Tor") }
        else { out.append("Internet: \(relaysLinked) of \(nostr.total) relays" + (throughTor == true ? " through Tor" : "")) }
        return out
    }

    private func count(_ n: Int, _ what: String) -> String { n == 0 ? "no \(what)s linked" : "\(n) \(what)\(n == 1 ? "" : "s") linked" }

    /// Something only the user can fix (Settings or Control Center) that stops phones from finding each other.
    var setupProblem: (title: String, text: String, settings: Bool)? {
        switch bluetooth {
        case .poweredOff:
            return ("Bluetooth is off", "Turn it on in Control Center so nearby phones can connect.", false)
        case .unauthorized:
            return ("Bluetooth is not allowed", "DarkProof needs Bluetooth to find phones nearby. Turn it on in Settings.", true)
        default: break
        }
        if localNetworkDenied {
            return ("Local Network is not allowed", "DarkProof needs it to connect over Wi-Fi, even with no internet. Turn it on in Settings.", true)
        }
        return nil
    }
}

/// Bluetooth off or not allowed, or Local Network refused: what to do, with the Settings button.
struct SetupProblemCard: View {
    @ObservedObject var engine: Engine

    var body: some View {
        if let p = engine.setupProblem {
            Card {
                Label(p.title, systemImage: "exclamationmark.triangle.fill").scaledFont(18, .bold).foregroundStyle(Theme.help)
                Text(p.text).scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if p.settings { OpenSettingsButton() }
            }
        }
    }
}
