package it.blackout.mesh

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * A group's fingerprint: five emoji two people read out to each other to check that their phones are in the same group.
 * A fake invite QR, or a code typed with a mistake, gives different emoji. Derived from the group key
 * (spec/FORMAT.md, "Group fingerprint"); same results as the iPhone (Fingerprint.swift).
 *
 * The 64 emoji and their English names are Matrix's SAS emoji list, in its order (github.com/matrix-org/matrix-spec,
 * data-definitions/sas-emoji.json, Apache License 2.0), chosen to be easy to tell apart and to name.
 */
object Fingerprint {
    const val LENGTH = 5
    private const val INFO = "darkproof-fingerprint-v1"

    val EMOJI: List<String> = listOf(
        "🐶", "🐱", "🦁", "🐎", "🦄", "🐷", "🐘", "🐰", "🐼", "🐓", "🐧", "🐢", "🐟", "🐙", "🦋", "🌷",
        "🌳", "🌵", "🍄", "🌏", "🌙", "☁️", "🔥", "🍌", "🍎", "🍓", "🌽", "🍕", "🎂", "❤️", "😀", "🤖",
        "🎩", "👓", "🔧", "🎅", "👍", "☂️", "⌛", "⏰", "🎁", "💡", "📕", "✏️", "📎", "✂️", "🔒", "🔑",
        "🔨", "☎️", "🏁", "🚂", "🚲", "✈️", "🚀", "🏆", "⚽", "🎸", "🎺", "🔔", "⚓", "🎧", "📁", "📌",
    )
    val NAMES: List<String> = listOf(
        "Dog", "Cat", "Lion", "Horse", "Unicorn", "Pig", "Elephant", "Rabbit", "Panda", "Rooster", "Penguin", "Turtle",
        "Fish", "Octopus", "Butterfly", "Flower", "Tree", "Cactus", "Mushroom", "Globe", "Moon", "Cloud", "Fire", "Banana",
        "Apple", "Strawberry", "Corn", "Pizza", "Cake", "Heart", "Smiley", "Robot", "Hat", "Glasses", "Spanner", "Santa",
        "Thumbs Up", "Umbrella", "Hourglass", "Clock", "Gift", "Light Bulb", "Book", "Pencil", "Paperclip", "Scissors",
        "Lock", "Key", "Hammer", "Telephone", "Flag", "Train", "Bicycle", "Aeroplane", "Rocket", "Trophy", "Ball",
        "Guitar", "Trumpet", "Bell", "Anchor", "Headphones", "Folder", "Pin",
    )

    /** Five indices (0–63) into EMOJI and NAMES: the first 30 bits of HMAC-SHA256(group key, INFO), 6 bits each. */
    fun forKey(groupKey: ByteArray): List<Int> {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(groupKey, "HmacSHA256")) }.doFinal(INFO.toByteArray(Charsets.US_ASCII))
        val v = (0 until 4).fold(0L) { acc, i -> (acc shl 8) or (mac[i].toLong() and 0xFF) }
        return (0 until LENGTH).map { ((v shr (26 - 6 * it)) and 63).toInt() }
    }

    /** The fingerprint of a group code. Slow (it derives the key, a fraction of a second): call it off the main thread and keep it. */
    fun forCode(code: String): List<Int> = forKey(GroupCrypto.deriveKey(code))

    /** "🐶 😀 🐼 🔨 🐧" */
    fun emojiText(indices: List<Int>) = indices.joinToString(" ") { EMOJI[it] }

    /** "Dog, Smiley, Panda, Hammer, Penguin": what people say out loud. */
    fun spoken(indices: List<Int>) = indices.joinToString(", ") { NAMES[it] }
}
