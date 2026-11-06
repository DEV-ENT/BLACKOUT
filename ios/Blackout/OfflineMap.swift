import Foundation
import MapLibre
import BlackoutCore

/// Street maps from OpenFreeMap (OpenStreetMap data, dark style), saved on the phone for offline use while there is
/// internet. OpenFreeMap's terms (openfreemap.org/tos, "Offline Downloads") allow an app to download areas if each
/// download is at most 3,000 tiles or 50 MB, uses at most 4 parallel requests, and sends a User-Agent naming the app.
final class OfflineMap: NSObject, ObservableObject {
    static let shared = OfflineMap()
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/dark")!
    static let radiusKm = 10.0  // the saved area is about 20 km across
    static let maxZoom = 14.0   // OpenFreeMap's tiles stop at 14; the map zooms further by enlarging them
    static let maxTiles = 3_000
    static let maxBytes: UInt64 = 50_000_000

    enum State: Equatable {
        case none
        case downloading(Double)
        case ready(bytes: UInt64, center: Spot, ts: Int64)
        case failed(String)
    }

    @Published private(set) var state = State.none
    private var pack: MLNOfflinePack?
    private struct Context: Codable { let lat: Double; let lon: Double; let ts: Int64 }

    /// Call once at launch, before any map is shown.
    func setUp() {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 4
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        c.httpAdditionalHeaders = ["User-Agent": "DarkProof/\(v) (iOS; +https://github.com/DEV-ENT/DarkProof)"]
        #if DEBUG
        if CommandLine.arguments.contains("noInternet") { c.protocolClasses = [NoInternet.self] } // test the saved map
        #endif
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = c
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(progressChanged), name: .MLNOfflinePackProgressChanged, object: nil)
        nc.addObserver(self, selector: #selector(packFailed), name: .MLNOfflinePackError, object: nil)
        MLNOfflineStorage.shared.addObserver(self, forKeyPath: "packs", options: [.initial, .new], context: nil)
    }

    /// The saved area as a box around `c`.
    static func bounds(around c: Spot) -> MLNCoordinateBounds {
        let dLat = radiusKm / 111.32, dLon = radiusKm / (111.32 * max(0.1, cos(c.lat * .pi / 180)))
        return MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: c.lat - dLat, longitude: c.lon - dLon),
                                   ne: CLLocationCoordinate2D(latitude: c.lat + dLat, longitude: c.lon + dLon))
    }

    /// Tiles a download of `b` from zoom 0 to `maxZoom` needs (standard web map tiling).
    static func tileCount(_ b: MLNCoordinateBounds) -> Int {
        (0...Int(maxZoom)).reduce(0) { sum, z in
            let n = Double(1 << z)
            func x(_ lon: Double) -> Int { Int(floor((lon + 180) / 360 * n)) }
            func y(_ lat: Double) -> Int {
                let r = lat * .pi / 180
                return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n))
            }
            return sum + (x(b.ne.longitude) - x(b.sw.longitude) + 1) * (y(b.sw.latitude) - y(b.ne.latitude) + 1)
        }
    }

    /// Saves the map around `c`, replacing any saved area.
    func download(around c: Spot) {
        if case .downloading = state { return }
        let b = Self.bounds(around: c)
        guard Self.tileCount(b) <= Self.maxTiles else { state = .failed("This area needs too many map tiles."); return }
        let region = MLNTilePyramidOfflineRegion(styleURL: Self.styleURL, bounds: b, fromZoomLevel: 0, toZoomLevel: Self.maxZoom)
        let ctx = (try? JSONEncoder().encode(Context(lat: c.lat, lon: c.lon, ts: Int64(Date().timeIntervalSince1970 * 1000)))) ?? Data()
        state = .downloading(0)
        removeAll {
            MLNOfflineStorage.shared.addPack(for: region, withContext: ctx) { [weak self] pack, error in
                guard let self else { return }
                guard let pack, error == nil else { self.state = .failed(error?.localizedDescription ?? "Couldn't start the download."); return }
                self.pack = pack
                pack.resume()
            }
        }
    }

    func cancel() { removeAll { [weak self] in self?.state = .none } }
    func delete() { cancel() }

    private func removeAll(then done: @escaping () -> Void) {
        let packs = MLNOfflineStorage.shared.packs ?? []
        pack = nil
        guard !packs.isEmpty else { return done() }
        let group = DispatchGroup()
        for p in packs { p.suspend(); group.enter(); MLNOfflineStorage.shared.removePack(p) { _ in group.leave() } }
        group.notify(queue: .main, execute: done)
    }

    private func update(_ p: MLNOfflinePack) {
        let pr = p.progress
        if pr.countOfBytesCompleted > Self.maxBytes { // over OpenFreeMap's limit: stop and remove it
            removeAll { [weak self] in self?.state = .failed("This area is bigger than 50 MB.") }
            return
        }
        switch p.state {
        case .complete:
            let c = (try? JSONDecoder().decode(Context.self, from: p.context)).map { (Spot(lat: $0.lat, lon: $0.lon), $0.ts) }
            state = .ready(bytes: pr.countOfBytesCompleted, center: c?.0 ?? Spot(lat: 0, lon: 0), ts: c?.1 ?? 0)
        case .active:
            let f = pr.countOfResourcesExpected > 0 ? Double(pr.countOfResourcesCompleted) / Double(pr.countOfResourcesExpected) : 0
            state = .downloading(min(0.99, f))
        case .inactive where pr.countOfResourcesCompleted < pr.countOfResourcesExpected || pr.countOfResourcesExpected == 0:
            state = .downloading(0) // cut off, e.g. the app was closed: carry on
            p.resume()
        default: break
        }
    }

    @objc private func progressChanged(_ n: Notification) {
        guard let p = n.object as? MLNOfflinePack else { return }
        DispatchQueue.main.async {
            guard MLNOfflineStorage.shared.packs?.contains(p) == true else { return } // removed or cancelled
            self.pack = p; self.update(p)
        }
    }

    @objc private func packFailed(_ n: Notification) {
        let e = n.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
        DispatchQueue.main.async { self.state = .failed(e?.localizedDescription ?? "The download failed. Try again.") }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "packs" else { return }
        DispatchQueue.main.async {
            guard self.pack == nil, let p = MLNOfflineStorage.shared.packs?.first else { return }
            self.pack = p
            p.requestProgress() // answers with a progress notification, which sets the state
        }
    }
}

#if DEBUG
/// Debug builds, launch argument `noInternet`: every map request fails as if there were no internet, to check that
/// the saved map works on its own.
final class NoInternet: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif
