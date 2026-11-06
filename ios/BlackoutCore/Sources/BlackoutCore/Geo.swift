import Foundation

/// A position shared in a check-in (spec/FORMAT.md, "Check-ins"): decimal degrees, and how sure the phone was.
public struct Spot: Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    /// Radius in meters the phone was sure of, if known.
    public let accuracy: Int?

    public init(lat: Double, lon: Double, accuracy: Int? = nil) { self.lat = lat; self.lon = lon; self.accuracy = accuracy }

    /// The last " 📍 LAT,LON ±Nm" in a text (spec/FORMAT.md, "Check-ins"), or nil if there is none or it is malformed.
    public static func last(in text: String) -> Spot? {
        guard let r = text.range(of: "📍 ", options: .backwards) else { return nil }
        let words = text[r.upperBound...].split(separator: " ", omittingEmptySubsequences: false)
        let ll = words.first?.split(separator: ",", omittingEmptySubsequences: false) ?? []
        let number: (Substring) -> Double? = { s in
            s.count <= 12 && s.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") } ? Double(s) : nil
        }
        guard ll.count == 2, let lat = number(ll[0]), let lon = number(ll[1]) else { return nil }
        var accuracy: Int?
        if words.count > 1, words[1].hasPrefix("±"), words[1].hasSuffix("m") {
            let digits = words[1].dropFirst().dropLast()
            if digits.count <= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }) { accuracy = Int(digits) }
        }
        let s = Spot(lat: lat, lon: lon, accuracy: accuracy)
        return s.isValid ? s : nil
    }

    public var isValid: Bool { lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon) }

    /// "45.46420,9.19000 ±12m": 5 decimals is about 1 m, more than a phone's GPS can tell.
    public var text: String {
        let ll = String(format: "%.5f,%.5f", lat, lon)
        guard let a = accuracy, (0...99_999).contains(a) else { return ll }
        return ll + " ±\(a)m"
    }
}

/// Distance and direction between two positions on the Earth (spherical model, good to about 0.5%).
public enum Geo {
    static let earthRadius = 6_371_008.8 // meters, mean radius

    /// Great-circle distance in meters (haversine).
    public static func distance(_ a: Spot, _ b: Spot) -> Double {
        let (p1, p2) = (rad(a.lat), rad(b.lat)), dp = rad(b.lat - a.lat), dl = rad(b.lon - a.lon)
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial direction from a to b, in degrees clockwise from true north (0..<360).
    public static func bearing(_ a: Spot, _ b: Spot) -> Double {
        let (p1, p2) = (rad(a.lat), rad(b.lat)), dl = rad(b.lon - a.lon)
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// "North", "Northeast", … for a bearing.
    public static func compassWord(_ bearing: Double) -> String {
        let words = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
        let i = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return words[i]
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
}
