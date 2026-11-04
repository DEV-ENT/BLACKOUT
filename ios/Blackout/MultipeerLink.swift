import Foundation
import MultipeerConnectivity
import CryptoKit
import BlackoutCore

/// iPhone-to-iPhone link over Apple peer-to-peer (Bluetooth and Wi-Fi), spec/FORMAT.md "Apple peer-to-peer".
final class MultipeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let prefix = "mc:"
    static let serviceType = "blackout-mesh"
    private let q = DispatchQueue(label: "mc")
    private let me: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let group: String
    private let router: MeshRouter
    private let onStatus: (String) -> Void
    private var found: [String: MCPeerID] = [:] // node id -> peer currently in range (q only)

    init(code: String, nodeId: String, router: MeshRouter, onStatus: @escaping (String) -> Void) {
        group = SHA256.hash(data: Data(("mc:" + code.precomposedStringWithCanonicalMapping).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        me = MCPeerID(displayName: nodeId)
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["g": group], serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        self.router = router; self.onStatus = onStatus
        super.init()
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        report()
    }

    /// Called by the router, possibly while it holds its lock, so only queue the work.
    func send(_ peer: String, _ p: Packet) {
        let name = String(peer.dropFirst(Self.prefix.count)), data = p.encode()
        q.async {
            guard let target = self.session.connectedPeers.first(where: { $0.displayName == name }) else { return }
            try? self.session.send(data, toPeers: [target], with: .reliable)
        }
    }

    /// Only the phone with the smaller node id invites, so two phones never invite each other at once.
    private func invite(_ peer: MCPeerID) {
        guard me.displayName < peer.displayName, !session.connectedPeers.contains(peer) else { return }
        browser.invitePeer(peer, to: session, withContext: Data(group.utf8), timeout: 20)
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        q.async {
            guard info?["g"] == self.group else { return } // another group
            self.found[peerID.displayName] = peerID
            self.invite(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        q.async { self.found[peerID.displayName] = nil }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        onStatus("Nearby iPhones: not available (\(error.localizedDescription))")
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(context == Data(group.utf8), session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        onStatus("Nearby iPhones: not available (\(error.localizedDescription))")
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        q.async {
            let id = Self.prefix + peerID.displayName
            switch state {
            case .connected:
                self.router.peerUp(id)
            case .notConnected:
                self.router.peerDown(id)
                self.q.asyncAfter(deadline: .now() + 5) { // still in range: try again
                    if let p = self.found[peerID.displayName] { self.invite(p) }
                }
            default:
                break
            }
            self.report()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let p = Packet.decode(data) else { return }
        q.async { self.router.receive(from: Self.prefix + peerID.displayName, p) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}

    private func report() { onStatus("Nearby iPhones: \(session.connectedPeers.count) connected") }
}
