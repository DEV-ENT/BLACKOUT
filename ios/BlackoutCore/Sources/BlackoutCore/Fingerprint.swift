import Foundation
import CryptoKit

/// A group's fingerprint: five emoji two people read out to each other to check that their phones are in the same
/// group. A fake invite QR, or a code typed with a mistake, gives different emoji. Derived from the group key
/// (spec/FORMAT.md, "Group fingerprint"); same results as Android (Fingerprint.kt).
///
/// The 64 emoji and their English names are Matrix's SAS emoji list, in its order (github.com/matrix-org/matrix-spec,
/// data-definitions/sas-emoji.json, Apache License 2.0), chosen to be easy to tell apart and to name.
public enum Fingerprint {
    public static let length = 5
    private static let info = "darkproof-fingerprint-v1"

    public static let emoji: [String] = [
        "🐶", "🐱", "🦁", "🐎", "🦄", "🐷", "🐘", "🐰", "🐼", "🐓", "🐧", "🐢", "🐟", "🐙", "🦋", "🌷",
        "🌳", "🌵", "🍄", "🌏", "🌙", "☁️", "🔥", "🍌", "🍎", "🍓", "🌽", "🍕", "🎂", "❤️", "😀", "🤖",
        "🎩", "👓", "🔧", "🎅", "👍", "☂️", "⌛", "⏰", "🎁", "💡", "📕", "✏️", "📎", "✂️", "🔒", "🔑",
        "🔨", "☎️", "🏁", "🚂", "🚲", "✈️", "🚀", "🏆", "⚽", "🎸", "🎺", "🔔", "⚓", "🎧", "📁", "📌",
    ]
    public static let names: [String] = [
        "Dog", "Cat", "Lion", "Horse", "Unicorn", "Pig", "Elephant", "Rabbit", "Panda", "Rooster", "Penguin", "Turtle",
        "Fish", "Octopus", "Butterfly", "Flower", "Tree", "Cactus", "Mushroom", "Globe", "Moon", "Cloud", "Fire", "Banana",
        "Apple", "Strawberry", "Corn", "Pizza", "Cake", "Heart", "Smiley", "Robot", "Hat", "Glasses", "Spanner", "Santa",
        "Thumbs Up", "Umbrella", "Hourglass", "Clock", "Gift", "Light Bulb", "Book", "Pencil", "Paperclip", "Scissors",
        "Lock", "Key", "Hammer", "Telephone", "Flag", "Train", "Bicycle", "Aeroplane", "Rocket", "Trophy", "Ball",
        "Guitar", "Trumpet", "Bell", "Anchor", "Headphones", "Folder", "Pin",
    ]

    /// Five indices (0–63) into `emoji` and `names`: the first 30 bits of HMAC-SHA256(group key, info), 6 bits each.
    public static func forKey(_ groupKey: Data) -> [Int] {
        let mac = Array(HMAC<SHA256>.authenticationCode(for: Data(info.utf8), using: SymmetricKey(data: groupKey)))
        let v = mac[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (0..<length).map { Int((v >> (26 - 6 * UInt32($0))) & 63) }
    }

    /// The fingerprint of a group code. Slow (it derives the key, a fraction of a second): call it off the main thread
    /// and keep it.
    public static func forCode(_ code: String) -> [Int] { forKey(GroupCrypto.deriveKey(code)) }

    /// "🐶 😀 🐼 🔨 🐧"
    public static func emojiText(_ indices: [Int]) -> String { indices.map { emoji[$0] }.joined(separator: " ") }

    /// "Dog, Smiley, Panda, Hammer, Penguin": what people say out loud.
    public static func spoken(_ indices: [Int]) -> String { indices.map { names[$0] }.joined(separator: ", ") }
}
