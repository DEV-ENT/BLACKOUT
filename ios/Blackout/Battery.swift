import UIKit
import BlackoutCore

/// "About 9 h left": the battery level sampled over time while the phone is unplugged, saved on the phone. The
/// estimate shows only once it means something: at least 20 minutes and 3% of drain measured since unplugging.
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    private struct Sample: Codable { let ts: Double; let level: Double }
    private let key = "batterySamples"
    private var samples: [Sample]
    @Published private(set) var hoursLeft: Double?

    private init() {
        samples = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Sample].self, from: $0) } ?? []
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.sample() }
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.sample() }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.sample() }
        sample()
    }

    /// Records the current level; charging starts the measurement over. Main thread.
    func sample() {
        let d = UIDevice.current
        let level = Double(d.batteryLevel)
        guard level >= 0 else { hoursLeft = nil; return } // unknown, e.g. the Simulator
        if d.batteryState == .charging || d.batteryState == .full { samples = []; save(); hoursLeft = nil; return }
        let now = Date().timeIntervalSince1970
        if let last = samples.last, last.level < level - 0.02 { samples = [] } // charged meanwhile (app was closed)
        if samples.last?.level != level || samples.isEmpty { samples.append(Sample(ts: now, level: level)) }
        samples = Array(samples.filter { now - $0.ts < 6 * 3600 }.suffix(200))
        save()
        hoursLeft = Self.estimate(samples.map { ($0.ts, $0.level) }, now: now)
    }

    /// Hours until empty at the pace of the last few hours, or nil when the data doesn't say much yet.
    static func estimate(_ s: [(ts: Double, level: Double)], now: Double) -> Double? {
        guard let first = s.first, let last = s.last else { return nil }
        let span = last.ts - first.ts, drop = first.level - last.level
        guard span >= 20 * 60, drop >= 0.03 else { return nil }
        let perHour = drop / (span / 3600)
        let left = last.level / perHour - (now - last.ts) / 3600
        return left >= 0.5 && left <= 96 ? left : nil
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(samples), forKey: key) }

    /// "about 9 h left", "about 40 min left".
    static func text(_ hours: Double) -> String {
        hours < 1 ? "about \(Int((hours * 60 / 10).rounded() * 10)) min left" : "about \(Int(hours.rounded())) h left"
    }
}
