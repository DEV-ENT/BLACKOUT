import XCTest
import CryptoKit
@testable import BlackoutCore

/// Same examples as the Android app's WordFilterTest.
final class WordFilterTests: XCTestCase {
    func testListMatchesAndroid() {
        XCTAssertEqual(Hex.encode(Data(SHA256.hash(data: Data(WordFilter.list.utf8)))),
                       "502386ef2f3c02c84bfe8beb523b0c3642932eeefdc2fb6f2efad507087654ed")
    }

    func testMasksWordsKeepsTheRest() {
        let examples: [(String, String)] = [
            ("Fuck this", "•••• this"),
            ("fuuuuck you", "••••••• you"),
            ("Sh1t, the bridge is down", "••••, the bridge is down"),
            ("a$$hole", "•••••••"),
            ("Che cazzo succede?", "Che ••••• succede?"),
            ("VAFFANCULO!", "••••••••••!"),
            ("Stronzò", "•••••••"),
            ("🙂 fuck 🙂", "🙂 •••• 🙂"),
            ("Water at the fountain, 45.46420, 9.19000", "Water at the fountain, 45.46420, 9.19000"),
            ("Fire retardant on the road", "Fire retardant on the road"),
            ("Pasta alla puttanesca, scrabble, Scunthorpe", "Pasta alla puttanesca, scrabble, Scunthorpe"),
            ("Città vecchia", "Città vecchia"),
        ]
        for (input, expected) in examples { XCTAssertEqual(WordFilter.clean(input), expected, input) }
    }
}
