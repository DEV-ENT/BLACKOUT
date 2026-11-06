package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Group codes, invites, fingerprints, Plus Codes, status text, check-in extensions, reports, "are you safe?" and place
 * freshness, checked against spec/test-vectors.txt. The iPhone's SharedVectorsTests checks the same vectors.
 */
class SharedVectorsTest {
    private fun unhex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val vectors: List<Map<String, String>> =
        File("../spec/test-vectors.txt").readText(Charsets.UTF_8).split(Regex("\n\\s*\n")).map { block ->
            block.lines().filter { it.isNotBlank() && !it.startsWith("#") }
                .associate { it.substringBefore(": ") to it.substringAfter(": ") }
        }.filter { it.isNotEmpty() }

    private fun of(kind: String) = vectors.filter { it["kind"] == kind }.also { assertTrue("no $kind vectors", it.isNotEmpty()) }
    private fun status(s: String) = when (s) { "safe" -> CheckIn.SAFE; "help" -> CheckIn.HELP; else -> error(s) }
    private fun needs(v: Map<String, String>) = v["needs"]?.split(",")?.map { w -> Need.entries.first { it.word == w } }?.toSet().orEmpty()
    private fun spot(v: Map<String, String>) = v["lat"]?.let { Spot(it.toDouble(), v["lon"]!!.toDouble(), v["accuracy"]?.toInt()) }

    @Test fun vectorCounts() {
        assertEquals(13, of("code-normalize").size)
        assertEquals(2, of("invite").size)
        assertEquals(10, of("invite-parse").size)
        assertEquals(3, of("fingerprint").size)
        assertEquals(4, of("pluscode").size)
        assertEquals(3, of("status-share").size)
        assertEquals(4, of("checkin").size)
        assertEquals(3, of("vouch").size)
        assertEquals(2, of("ask").size)
    }

    @Test fun codeNormalize() = of("code-normalize").forEach { v ->
        val input = v["input"] ?: String(unhex(v["input_hex"]!!), Charsets.UTF_8)
        val out = Invite.normalizeCode(input)
        assertEquals(v.toString(), v["output"], out)
        assertEquals(v.toString(), v["generated"].toBoolean(), Invite.isGeneratedCode(out))
    }

    @Test fun inviteLinks() = of("invite").forEach { v ->
        val name = v["name"]!!; val code = v["code"]!!
        assertEquals(v["url"], Invite.url(name, code))
        assertEquals(v["web"], Invite.webUrl(name, code))
        assertEquals(name to code, Invite.parse(v["url"]!!))
        assertEquals(name to code, Invite.parse(v["web"]!!))
    }

    @Test fun inviteParse() = of("invite-parse").forEach { v ->
        val expected = v["code"]?.let { v["name"]!! to it }
        assertEquals(v["link"], expected, Invite.parse(v["link"]!!))
    }

    @Test fun fingerprints() {
        of("fingerprint").forEach { v ->
            val idx = Fingerprint.forCode(v["code"]!!)
            assertEquals(v["indices"], idx.joinToString(" "))
            assertEquals(v["emoji"], Fingerprint.emojiText(idx))
            assertEquals(v["spoken"], Fingerprint.spoken(idx))
        }
        val list = of("fingerprint-list").single()
        assertEquals(list["emoji"]!!.split(" "), Fingerprint.EMOJI)
        assertEquals(list["names"]!!.split(","), Fingerprint.NAMES)
        assertEquals(64, Fingerprint.EMOJI.toSet().size)
    }

    @Test fun plusCodes() = of("pluscode").forEach { v ->
        val code = PlusCode.encode(v["lat"]!!.toDouble(), v["lon"]!!.toDouble())
        assertEquals(v["code"], code)
        val c = PlusCode.decode(code!!)!!.center
        assertEquals(v["center_lat"]!!.toDouble(), c.lat, 1e-9)
        assertEquals(v["center_lon"]!!.toDouble(), c.lon, 1e-9)
    }

    @Test fun statusShare() = of("status-share").forEach { v ->
        val t = StatusShare.text(status(v["status"]!!), v["name"]!!, v["battery"]?.toInt(), spot(v))
        assertEquals(v["text"], t)
        assertTrue(t.length <= 160)
    }

    @Test fun checkIns() = of("checkin").forEach { v ->
        val s = status(v["status"]!!); val text = v["text"]!!
        assertEquals(text, s.text(v["battery"]?.toInt(), spot(v), needs(v), v["people"]?.toInt()))
        assertEquals(s, CheckIn.of(text))
        assertEquals(needs(v), CheckIn.needs(text))
        assertEquals(v["people"]?.toInt(), CheckIn.people(text))
        assertEquals(v["battery"]?.toInt(), CheckIn.battery(text))
        assertEquals(spot(v), CheckIn.spot(text))
    }

    @Test fun vouches() = of("vouch").forEach { v ->
        val vouch = Vouch(v["subject"]!!, status(v["status"]!!), needs(v), v["people"]?.toInt(), spot(v))
        assertEquals(v["text"], vouch.text)
        assertEquals(vouch, Vouch.of(v["text"]!!))
        assertNull(CheckIn.of(vouch.text)) // never the sender's own check-in
    }

    @Test fun asks() = of("ask").forEach { v ->
        assertEquals(v["text"], AreYouSafe(v["to"]).text)
        assertEquals(AreYouSafe(v["to"]), AreYouSafe.of(v["text"]!!))
    }

    @Test fun placeFreshness() {
        val now = 1_793_807_238_631L
        for (case in of("place-freshness").single()["cases"]!!.split(" ")) {
            val (age, result) = case.split("=")
            assertEquals(case, Freshness.valueOf(result.uppercase()), Place.freshness(now - age.toLong(), now))
        }
    }
}
