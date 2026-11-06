import XCTest
@testable import BlackoutCore

final class PhoneClassTests: XCTestCase {
    private let gib: Double = 1_073_741_824

    func testMemoryClasses() {
        // What iOS reports is a little under the marketing size.
        XCTAssertEqual(PhoneClass.memoryGB(bytes: UInt64(2.8 * gib)), 3)  // iPhone XR
        XCTAssertEqual(PhoneClass.memoryGB(bytes: UInt64(3.7 * gib)), 4)  // iPhone 12, 13, SE (3rd)
        XCTAssertEqual(PhoneClass.memoryGB(bytes: UInt64(5.6 * gib)), 6)  // iPhone 14, 15, 12/13 Pro
        XCTAssertEqual(PhoneClass.memoryGB(bytes: UInt64(7.5 * gib)), 8)  // iPhone 15 Pro, 16, 17
        XCTAssertEqual(PhoneClass.memoryGB(bytes: UInt64(11.6 * gib)), 12)
        XCTAssertEqual(PhoneClass.memoryGB(bytes: UInt64(6.0 * gib)), 6)  // exactly the marketing size
    }

    /// Every iPhone generation the app supports (iOS 16.4: iPhone XS/XR and later), by hardware identifier.
    func testSpeedForEveryIPhone() {
        let phones: [(String, Double)] = [
            ("iPhone11,8", 0.3),   // XR
            ("iPhone11,2", 0.3),   // XS
            ("iPhone12,1", 0.4),   // 11
            ("iPhone12,8", 0.4),   // SE (2nd)
            ("iPhone13,2", 0.55),  // 12
            ("iPhone13,1", 0.55),  // 12 mini
            ("iPhone14,5", 0.75),  // 13
            ("iPhone14,6", 0.75),  // SE (3rd)
            ("iPhone14,7", 0.75),  // 14 (A15)
            ("iPhone15,2", 1.0),   // 14 Pro (A16)
            ("iPhone15,4", 1.0),   // 15: the measured phone
            ("iPhone16,1", 1.25),  // 15 Pro
            ("iPhone17,3", 1.45),  // 16
            ("iPhone17,5", 1.45),  // 16e
            ("iPhone18,3", 1.7),   // 17
            ("iPhone19,2", 2.0),   // 18 Pro
            ("iPhone23,1", 2.0),   // a future iPhone: at least the newest known
        ]
        for (machine, factor) in phones { XCTAssertEqual(PhoneClass.speedFactor(machine: machine), factor, machine) }
        XCTAssertEqual(PhoneClass.speedFactor(machine: "arm64"), 1)          // Simulator
        XCTAssertEqual(PhoneClass.speedFactor(machine: "iPad14,1"), 1)
    }

    func testEstimates() {
        XCTAssertEqual(PhoneClass.estimate(onIPhone15: 4...19, factor: 1), 4...19)
        XCTAssertEqual(PhoneClass.estimate(onIPhone15: 4...19, factor: 0.55), 7...35) // iPhone 12: slower
        XCTAssertEqual(PhoneClass.estimate(onIPhone15: 4...19, factor: 2), 2...10)     // iPhone 18: faster
    }

    func testTypicalIsTheMedian() {
        XCTAssertNil(PhoneClass.typical([]))
        XCTAssertEqual(PhoneClass.typical([12]), 12)
        XCTAssertEqual(PhoneClass.typical([5, 60, 9]), 9)       // one long answer doesn't skew it
        XCTAssertEqual(PhoneClass.typical([4, 10, 8, 6]), 7)
    }
}
