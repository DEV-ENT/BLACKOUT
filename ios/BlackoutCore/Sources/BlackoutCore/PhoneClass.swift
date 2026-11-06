import Foundation

/// What an iPhone can do for the on-device AI: its memory class and roughly how fast its chip is.
/// Pure functions, so every iPhone model can be checked in unit tests without owning it.
public enum PhoneClass {
    /// Memory class in GB (4, 6, 8, 12…), from the bytes iOS reports. iOS reports a little less than the marketing
    /// size (an iPhone 15 with 6 GB reports about 5.6 GiB), so it rounds to the nearest class above.
    public static func memoryGB(bytes: UInt64) -> Int {
        let gib = Double(bytes) / 1_073_741_824
        return [3, 4, 6, 8, 12, 16].first { gib <= Double($0) + 0.2 } ?? Int(gib.rounded())
    }

    /// Rough AI speed compared with an iPhone 15 (A16 chip) = 1, from the hardware identifier such as "iPhone15,4".
    /// Based on the chip generation, not measured: the app replaces it with times measured on the phone itself.
    /// The first number of the identifier follows the chip: 11 = A12 (XS, XR) … 15 = A16 (14 Pro, 15) … 19 = 18 series.
    public static func speedFactor(machine: String) -> Double {
        guard machine.hasPrefix("iPhone"), let major = Int(machine.dropFirst(6).prefix { $0.isNumber }) else { return 1 }
        let byGeneration: [Int: Double] = [
            11: 0.3,  // A12: iPhone XS, XR
            12: 0.4,  // A13: iPhone 11, SE (2nd)
            13: 0.55, // A14: iPhone 12
            14: 0.75, // A15: iPhone 13, 14, SE (3rd)
            15: 1.0,  // A16: iPhone 14 Pro, 15 (measured)
            16: 1.25, // A17 Pro: iPhone 15 Pro
            17: 1.45, // A18: iPhone 16
            18: 1.7,  // A19: iPhone 17
            19: 2.0,  // iPhone 18
        ]
        if let f = byGeneration[major] { return f }
        return major > 19 ? 2.0 : 0.3 // newer than the table: at least as fast as the newest known; older: the slowest
    }

    /// Seconds per answer expected on a phone, from the range measured on an iPhone 15.
    public static func estimate(onIPhone15 range: ClosedRange<Double>, factor: Double) -> ClosedRange<Int> {
        let f = max(factor, 0.1)
        return Int((range.lowerBound / f).rounded())...Int((range.upperBound / f).rounded())
    }

    /// The typical time of recent answers: the median, so one very long answer doesn't skew it.
    public static func typical(_ seconds: [Double]) -> Double? {
        guard !seconds.isEmpty else { return nil }
        let s = seconds.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
