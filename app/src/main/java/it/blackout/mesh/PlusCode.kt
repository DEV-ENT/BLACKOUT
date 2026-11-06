package it.blackout.mesh

import kotlin.math.floor

/**
 * Plus Codes (Open Location Code, github.com/google/open-location-code, Apache-2.0): a position as a short code like
 * "8FQFF57R+M2" that Google Maps, Apple Maps (search) and other map apps understand, and that is easy to read out.
 * Full codes only (no short codes relative to a town). Same results as the iPhone (PlusCode.swift) and the reference
 * implementation, checked against its test data.
 */
object PlusCode {
    const val ALPHABET = "23456789CFGHJMPQRVWX"
    /** 10 digits: about 14 × 14 m, as precise as a phone's GPS. */
    const val DEFAULT_LENGTH = 10
    private const val SEPARATOR = '+'
    private const val SEPARATOR_POSITION = 8
    private const val PADDING = '0'
    private const val MAX_DIGITS = 15
    private const val PAIR_LENGTH = 10
    private const val GRID_COLUMNS = 4
    private const val GRID_ROWS = 5
    private const val LAT_PRECISION = 25_000_000L // 8000 × 5^5: integer steps per degree at 15 digits
    private const val LNG_PRECISION = 8_192_000L  // 8000 × 4^5

    /** The area a code stands for, in degrees. */
    data class Area(val latLo: Double, val lonLo: Double, val latHi: Double, val lonHi: Double, val length: Int) {
        /** The middle of the area, as the reference computes it. */
        val center: Spot get() = Spot(minOf(latLo + (latHi - latLo) / 2, 90.0), minOf(lonLo + (lonHi - lonLo) / 2, 180.0))
    }

    /**
     * The full Plus Code of a position: [length] digits (2, 4, 6, 8, or 10 to 15). Latitudes are clipped to ±90 and
     * longitudes wrapped. Null for NaN, infinity, an absurd longitude or an unsupported length.
     */
    fun encode(lat: Double, lon: Double, length: Int = DEFAULT_LENGTH): String? {
        if (!lat.isFinite() || !lon.isFinite() || kotlin.math.abs(lon) > 1e9) return null
        if (length < 2 || (length < PAIR_LENGTH && length % 2 == 1)) return null
        val (la, ln) = toIntegers(lat, lon)
        return encodeIntegers(la, ln, length)
    }

    /** Degrees to the reference's integers (floor of degrees × precision, clipped and wrapped). */
    internal fun toIntegers(lat: Double, lon: Double): Pair<Long, Long> {
        var la = floor(lat.coerceIn(-90.0, 90.0) * LAT_PRECISION).toLong() + 90 * LAT_PRECISION
        if (la < 0) la = 0 else if (la >= 180 * LAT_PRECISION) la = 180 * LAT_PRECISION - 1
        var ln = floor(lon * LNG_PRECISION).toLong() + 180 * LNG_PRECISION
        if (ln < 0) ln = ln % (360 * LNG_PRECISION) + 360 * LNG_PRECISION
        else if (ln >= 360 * LNG_PRECISION) ln %= 360 * LNG_PRECISION
        return la to ln
    }

    internal fun encodeIntegers(latInt: Long, lngInt: Long, codeLength: Int): String {
        val length = minOf(codeLength, MAX_DIGITS)
        var la = latInt; var ln = lngInt
        val rev = StringBuilder()
        if (length > PAIR_LENGTH) {
            repeat(MAX_DIGITS - PAIR_LENGTH) {
                rev.append(ALPHABET[((la % GRID_ROWS) * GRID_COLUMNS + ln % GRID_COLUMNS).toInt()])
                la /= GRID_ROWS; ln /= GRID_COLUMNS
            }
        } else {
            la /= 3125; ln /= 1024 // GRID_ROWS^5, GRID_COLUMNS^5
        }
        for (i in 0 until PAIR_LENGTH / 2) {
            rev.append(ALPHABET[(ln % 20).toInt()]).append(ALPHABET[(la % 20).toInt()])
            la /= 20; ln /= 20
            if (i == 0) rev.append(SEPARATOR)
        }
        var code = rev.reverse().toString()
        if (length < SEPARATOR_POSITION) code = code.take(length) + PADDING.toString().repeat(SEPARATOR_POSITION - length) + SEPARATOR
        return code.take(maxOf(SEPARATOR_POSITION + 1, length + 1))
    }

    /** The area of a full code (any case), or null if it is not a valid full code. Digits after the 15th are ignored. */
    fun decode(code: String): Area? {
        if (!isFull(code)) return null
        val digits = upper(code).filter { it != SEPARATOR && it != PADDING }.take(MAX_DIGITS).map { ALPHABET.indexOf(it).toLong() }
        var la = -90 * LAT_PRECISION; var ln = -180 * LNG_PRECISION
        var latPlace = LAT_PRECISION * 400; var lngPlace = LNG_PRECISION * 400
        var i = 0
        while (i < minOf(digits.size, PAIR_LENGTH)) {
            latPlace /= 20; lngPlace /= 20
            la += digits[i] * latPlace; ln += digits[i + 1] * lngPlace
            i += 2
        }
        while (i < digits.size) {
            latPlace /= GRID_ROWS; lngPlace /= GRID_COLUMNS
            la += digits[i] / GRID_COLUMNS * latPlace; ln += digits[i] % GRID_COLUMNS * lngPlace
            i++
        }
        return Area(la.toDouble() / LAT_PRECISION, ln.toDouble() / LNG_PRECISION,
            (la + latPlace).toDouble() / LAT_PRECISION, (ln + lngPlace).toDouble() / LNG_PRECISION, digits.size)
    }

    /** Whether [code] is a valid Plus Code (full or short), following the reference's rules. */
    fun isValid(code: String): Boolean {
        if (code.length < 2) return false
        val c = upper(code)
        val sep = c.indexOf(SEPARATOR)
        if (sep < 0 || sep != c.lastIndexOf(SEPARATOR) || sep % 2 != 0 || sep > SEPARATOR_POSITION) return false
        if (sep == SEPARATOR_POSITION && (ALPHABET.indexOf(c[0]) > 8 || ALPHABET.indexOf(c[1]) > 17)) return false
        var padding = false
        for (i in 0 until sep) {
            val ch = c[i]
            if (ALPHABET.indexOf(ch) < 0 && ch != PADDING) return false
            if (padding) { if (ch != PADDING) return false }
            else if (ch == PADDING) {
                padding = true
                if (sep < SEPARATOR_POSITION || (i != 2 && i != 4 && i != 6)) return false
            }
        }
        if (c.length > sep + 1) {
            if (padding || c.length == sep + 2) return false
            for (i in sep + 1 until c.length) if (ALPHABET.indexOf(c[i]) < 0) return false
        }
        return true
    }

    /** Whether [code] is a valid full code (8 digits before the "+"), which decode() accepts. */
    fun isFull(code: String) = isValid(code) && code.indexOf(SEPARATOR) == SEPARATOR_POSITION

    private fun upper(s: String) = String(CharArray(s.length) { s[it].let { c -> if (c in 'a'..'z') c - 32 else c } })
}
