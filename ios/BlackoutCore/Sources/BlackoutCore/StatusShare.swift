import Foundation

/// A check-in as plain text for other apps: satellite messengers, text messages once the network is back, anything.
/// It leaves DarkProof unencrypted. Kept under 160 characters, the limit of satellite messengers such as Garmin inReach,
/// with the map link last so messaging apps make it tappable. The position also comes as a Plus Code, which rescuers can
/// type into any map app. Same text as the Android app (Protocol.kt).
public enum StatusShare {
    public static func text(_ c: CheckIn, name: String, battery: Int?, spot: Spot?) -> String {
        var t = c.rawValue
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(24))
        if !n.isEmpty { t += " — " + n }
        t += "."
        if let b = battery, (0...100).contains(b) { t += " Battery \(b)%." }
        if let spot, spot.isValid {
            let lat = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), spot.lat)
            let lon = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), spot.lon)
            t += " \(lat), \(lon)"
            if let a = spot.accuracy, (0...99_999).contains(a) { t += " ±\(a) m" }
            if let code = spot.plusCode { t += " (\(code))" }
            t += " https://osm.org/?mlat=\(lat)&mlon=\(lon)"
        }
        return t
    }
}
