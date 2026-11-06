import CoreLocation
import BlackoutCore

/// GPS works without internet. Used only when you share your position in check-ins (Settings) and while the
/// compass to a friend is open; never in the background.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    static let shareKey = "shareLocation" // UserDefaults: put my position in check-ins

    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLLocationDirection? // degrees from true north; nil without a compass
    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()
    private var watchers = 0
    private var waiting: [(CLLocation?) -> Void] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.headingFilter = 2
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var denied: Bool { authorization == .denied || authorization == .restricted }
    static var sharing: Bool { UserDefaults.standard.bool(forKey: shareKey) }

    func requestPermission() { if authorization == .notDetermined { manager.requestWhenInUseAuthorization() } }

    /// Live position and heading, e.g. while the compass is open. Balance every call with `stop()`.
    func watch() {
        watchers += 1
        requestPermission()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        heading = nil
    }

    /// My position for a check-in: a fix from the last 2 minutes, else a new one, waiting at most 10 seconds.
    /// nil if location is off, not allowed, or the phone can't get a fix in time. Main thread.
    func forCheckIn(_ done: @escaping (Spot?) -> Void) {
        guard Self.sharing, allowed else { return done(nil) }
        let toSpot: (CLLocation?) -> Spot? = { l in
            guard let l, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 500 else { return nil }
            return Spot(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: Int(l.horizontalAccuracy.rounded()))
        }
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < 120, toSpot(l) != nil { return done(toSpot(l)) }
        var finished = false
        let finish: (CLLocation?) -> Void = { l in if !finished { finished = true; done(toSpot(l)) } }
        waiting.append(finish)
        manager.requestLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        location = l
        let w = waiting; waiting = []
        w.forEach { $0(l) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let w = waiting; waiting = []
        w.forEach { $0(nil) }
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard h.headingAccuracy >= 0 else { return }
        heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        authorization = m.authorizationStatus
        if allowed && watchers > 0 { m.startUpdatingLocation() }
    }
}

extension CLLocation {
    var spot: Spot { Spot(lat: coordinate.latitude, lon: coordinate.longitude, accuracy: Int(horizontalAccuracy.rounded())) }
}
