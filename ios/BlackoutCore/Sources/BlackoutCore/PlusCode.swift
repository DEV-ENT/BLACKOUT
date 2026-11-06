import Foundation

/// Plus Codes (Open Location Code, github.com/google/open-location-code, Apache-2.0): a position as a short code like
/// "8FQFF57R+M2" that Google Maps, Apple Maps (search) and other map apps understand, and that is easy to read out.
/// Full codes only (no short codes relative to a town). Same results as Android (PlusCode.kt) and the reference
/// implementation, checked against its test data.
public enum PlusCode {
    public static let alphabet = "23456789CFGHJMPQRVWX"
    /// 10 digits: about 14 × 14 m, as precise as a phone's GPS.
    public static let defaultLength = 10
    private static let digits = Array(alphabet)
    private static let separatorPosition = 8, maxDigits = 15, pairLength = 10, gridColumns: Int64 = 4, gridRows: Int64 = 5
    private static let latPrecision: Int64 = 25_000_000 // 8000 × 5^5: integer steps per degree at 15 digits
    private static let lngPrecision: Int64 = 8_192_000  // 8000 × 4^5

    /// The area a code stands for, in degrees.
    public struct Area: Equatable, Sendable {
        public let latLo: Double, lonLo: Double, latHi: Double, lonHi: Double
        public let length: Int
        /// The middle of the area, as the reference computes it.
        public var center: Spot { Spot(lat: min(latLo + (latHi - latLo) / 2, 90), lon: min(lonLo + (lonHi - lonLo) / 2, 180)) }
    }

    /// The full Plus Code of a position: `length` digits (2, 4, 6, 8, or 10 to 15). Latitudes are clipped to ±90 and
    /// longitudes wrapped. Nil for NaN, infinity, an absurd longitude or an unsupported length.
    public static func encode(lat: Double, lon: Double, length: Int = defaultLength) -> String? {
        guard lat.isFinite, lon.isFinite, abs(lon) <= 1e9 else { return nil }
        guard length >= 2, length >= pairLength || length % 2 == 0 else { return nil }
        let (la, ln) = toIntegers(lat: lat, lon: lon)
        return encodeIntegers(la, ln, length)
    }

    /// Degrees to the reference's integers (floor of degrees × precision, clipped and wrapped).
    static func toIntegers(lat: Double, lon: Double) -> (Int64, Int64) {
        var la = Int64((min(max(lat, -90), 90) * Double(latPrecision)).rounded(.down)) + 90 * latPrecision
        if la < 0 { la = 0 } else if la >= 180 * latPrecision { la = 180 * latPrecision - 1 }
        var ln = Int64((lon * Double(lngPrecision)).rounded(.down)) + 180 * lngPrecision
        if ln < 0 { ln = ln % (360 * lngPrecision) + 360 * lngPrecision } else if ln >= 360 * lngPrecision { ln %= 360 * lngPrecision }
        return (la, ln)
    }

    static func encodeIntegers(_ latInt: Int64, _ lngInt: Int64, _ codeLength: Int) -> String {
        let length = min(codeLength, maxDigits)
        var la = latInt, ln = lngInt
        var rev: [Character] = []
        if length > pairLength {
            for _ in 0..<(maxDigits - pairLength) {
                rev.append(digits[Int((la % gridRows) * gridColumns + ln % gridColumns)])
                la /= gridRows; ln /= gridColumns
            }
        } else {
            la /= 3125; ln /= 1024 // gridRows^5, gridColumns^5
        }
        for i in 0..<(pairLength / 2) {
            rev.append(digits[Int(ln % 20)]); rev.append(digits[Int(la % 20)])
            la /= 20; ln /= 20
            if i == 0 { rev.append("+") }
        }
        var code = String(rev.reversed())
        if length < separatorPosition {
            code = String(code.prefix(length)) + String(repeating: "0", count: separatorPosition - length) + "+"
        }
        return String(code.prefix(max(separatorPosition + 1, length + 1)))
    }

    /// The area of a full code (any case), or nil if it is not a valid full code. Digits after the 15th are ignored.
    public static func decode(_ code: String) -> Area? {
        guard isFull(code) else { return nil }
        let values = upper(code).filter { $0 != "+" && $0 != "0" }.prefix(maxDigits).map { Int64(digits.firstIndex(of: $0)!) }
        var la = -90 * latPrecision, ln = -180 * lngPrecision
        var latPlace = latPrecision * 400, lngPlace = lngPrecision * 400
        var i = 0
        while i < min(values.count, pairLength) {
            latPlace /= 20; lngPlace /= 20
            la += values[i] * latPlace; ln += values[i + 1] * lngPlace
            i += 2
        }
        while i < values.count {
            latPlace /= gridRows; lngPlace /= gridColumns
            la += values[i] / gridColumns * latPlace; ln += values[i] % gridColumns * lngPlace
            i += 1
        }
        return Area(latLo: Double(la) / Double(latPrecision), lonLo: Double(ln) / Double(lngPrecision),
                    latHi: Double(la + latPlace) / Double(latPrecision), lonHi: Double(ln + lngPlace) / Double(lngPrecision),
                    length: values.count)
    }

    /// Whether `code` is a valid Plus Code (full or short), following the reference's rules.
    public static func isValid(_ code: String) -> Bool {
        let c = Array(upper(code))
        guard c.count >= 2, let sep = c.firstIndex(of: "+"), sep == c.lastIndex(of: "+"),
              sep % 2 == 0, sep <= separatorPosition else { return false }
        func index(_ ch: Character) -> Int { digits.firstIndex(of: ch) ?? -1 }
        if sep == separatorPosition, index(c[0]) > 8 || index(c[1]) > 17 { return false }
        var padding = false
        for i in 0..<sep {
            let ch = c[i]
            if index(ch) < 0 && ch != "0" { return false }
            if padding {
                if ch != "0" { return false }
            } else if ch == "0" {
                padding = true
                if sep < separatorPosition || ![2, 4, 6].contains(i) { return false }
            }
        }
        if c.count > sep + 1 {
            if padding || c.count == sep + 2 { return false }
            for ch in c[(sep + 1)...] where index(ch) < 0 { return false }
        }
        return true
    }

    /// Whether `code` is a valid full code (8 digits before the "+"), which decode() accepts.
    public static func isFull(_ code: String) -> Bool { isValid(code) && Array(code).firstIndex(of: "+") == separatorPosition }

    /// ASCII letters to upper case, nothing else (so no "ß" becomes "SS").
    private static func upper(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (97...122).contains($0.value) ? Unicode.Scalar($0.value - 32)! : $0 }))
    }
}
