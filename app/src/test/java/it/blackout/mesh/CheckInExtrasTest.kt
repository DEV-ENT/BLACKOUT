package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test

/** Needs, head counts, reports about others, "are you safe?" and invites. Same cases as the iPhone's CheckInExtrasTests. */
class CheckInExtrasTest {
    private fun m(sender: String, name: String, ts: Long, text: String, public: Boolean = false) = Message("$sender$ts", ts, sender, name, text, public)

    @Test fun oldAppsReadNewCheckIns() {
        // What an app without these extensions reads from them: the same status, battery and position.
        val t = CheckIn.HELP.text(9, Spot(45.4642, 9.19), setOf(Need.TRAPPED), 2)
        assertEquals("🆘 I need help: trapped · 👥 2 · 🔋 9% · 📍 45.46420,9.19000", t)
        assertEquals(CheckIn.HELP, CheckIn.of(t)); assertEquals(9, CheckIn.battery(t)); assertEquals(Spot(45.4642, 9.19), CheckIn.spot(t))
        // ...and new apps read old check-ins.
        assertTrue(CheckIn.needs("🆘 I need help · 🔋 9%").isEmpty()); assertNull(CheckIn.people("🆘 I need help · 🔋 9%"))
    }

    @Test fun needsAndPeopleParsing() {
        assertEquals(setOf(Need.WATER, Need.INJURED), CheckIn.needs("🆘 I need help: Water, rope,injured · 👥 3"))
        assertTrue(CheckIn.needs("🆘 trapped under the bridge").isEmpty())      // free text is not a list
        assertTrue(CheckIn.needs("✅ I'm safe: water").isEmpty())
        assertEquals("🆘 I need help: water", CheckIn.HELP.text(null, needs = setOf(Need.WATER), people = 0))
        assertEquals("✅ I'm safe", CheckIn.SAFE.text(null, needs = setOf(Need.WATER), people = 100)) // needs only for help
        assertNull(CheckIn.people("✅ I'm safe · 👥 0")); assertNull(CheckIn.people("✅ I'm safe · 👥 100"))
        assertNull(CheckIn.people("✅ I'm safe · 👥 3x")); assertNull(CheckIn.people("We are 👥 3")) // not a check-in
        assertEquals(5, CheckIn.people("✅ I'm safe · 👥 2 people · 👥 5"))
        assertEquals(listOf("Injured", "Trapped", "Need water", "Need food", "Need medicine", "Need shelter"), Need.entries.map { it.label })
    }

    @Test fun vouchesAreNeverOwnCheckIns() {
        assertEquals("👤 Someone is safe", Vouch(" ", CheckIn.SAFE).text)
        assertEquals("👤 Nonna Maria Rossi Bianch is safe", Vouch("Nonna\n Maria · Rossi Bianchi", CheckIn.SAFE).text) // one line, 24 chars
        assertEquals(Vouch("Bob is safe", CheckIn.SAFE), Vouch.of("👤 Bob is safe is safe"))
        assertEquals(Vouch("Ann", CheckIn.HELP, setOf(Need.FOOD)), Vouch.of("👤 Ann needs help: food, hugs"))
        assertNull(Vouch.of("👤 my new profile picture")); assertNull(Vouch.of("👤  is safe")); assertNull(Vouch.of("👤 Ann needs helpers"))
        assertNull(Vouch.of("Grandma is safe")); assertNull(Place.of(Vouch("Ann", CheckIn.SAFE).text))
        assertEquals("grandma rosa", Vouch.key("  Grandma\tROSA "))
    }

    @Test fun peopleListKeysReportsByName() {
        val people = Person.all(listOf(
            m("anna", "Anna", 100, Vouch("Grandma", CheckIn.HELP, setOf(Need.MEDICINE), spot = Spot(45.0, 9.0)).text),
            m("me", "Me", 200, Vouch("grandma ", CheckIn.SAFE).text),            // reports from this phone count too
            m("bob", "Bob", 150, Vouch("Marco", CheckIn.SAFE).text),
            m("marco", "Marco", 300, CheckIn.HELP.text(20, needs = setOf(Need.TRAPPED), people = 2)), // own, newer: hides Bob's report
            m("carl", "Carl", 120, "hi"),
            m("dina", "Dina", 400, Vouch("Elsa", CheckIn.SAFE).text, public = true), // Public: ignored
        ), "me")
        assertEquals(listOf("marco", "report:grandma", "bob", "carl", "anna"), people.map { it.id })
        val g = people[1]
        assertEquals("grandma", g.name); assertEquals(CheckIn.SAFE, g.checkIn); assertEquals(200L, g.checkInTs)
        assertEquals("Me", g.reportedBy); assertEquals("me", g.reporterId); assertTrue(g.isReport)
        assertTrue(g.needs.isEmpty()); assertEquals(Spot(45.0, 9.0), g.spot); assertEquals(100L, g.spotTs) // last known position stays
        val marco = people[0]
        assertFalse(marco.isReport); assertEquals(setOf(Need.TRAPPED), marco.needs); assertEquals(2, marco.people); assertEquals(20, marco.battery)
        // A report newer than the person's own check-in stays, as a separate entry marked as a report.
        val later = Person.all(listOf(m("marco", "Marco", 300, CheckIn.HELP.raw), m("me", "Me", 350, Vouch("MARCO", CheckIn.SAFE).text)), "me")
        assertEquals(listOf("marco", "report:marco"), later.map { it.id })
        assertEquals("Me", later[1].reportedBy); assertNull(later[0].reportedBy)
    }

    @Test fun areYouSafe() {
        assertEquals(AreYouSafe("Marco"), AreYouSafe.of(AreYouSafe(" Marco\n").text))
        assertEquals("❓ Is everyone safe?", AreYouSafe(" ").text)
        assertTrue(AreYouSafe(null).isFor("Anyone")); assertTrue(AreYouSafe("marco  rossi").isFor("Marco Rossi"))
        assertFalse(AreYouSafe("Marco").isFor("Anna"))
        assertNull(AreYouSafe.of("❓ , are you safe?")); assertNull(AreYouSafe.of("Is everyone safe?")); assertNull(AreYouSafe.of("❓ are you safe?"))
        assertNull(CheckIn.of(AreYouSafe("Marco").text))
    }

    @Test fun inviteCodes() {
        assertEquals("K7QF-2M9X-PA4T-W8RJ", Invite.normalizeCode(Invite.webUrl("Family", "K7QF-2M9X-PA4T-W8RJ")))
        assertEquals("Family" to "K7QF-2M9X-PA4T-W8RJ", Invite.parse("  " + Invite.webUrl("Family", "K7QF-2M9X-PA4T-W8RJ") + "\n"))
        assertFalse(Invite.isGeneratedCode("k7qf-2m9x-pa4t-w8rj")); assertFalse(Invite.isGeneratedCode("K7QF2M9XPA4TW8RJ"))
        repeat(50) { val c = Invite.newCode(); assertEquals(c, Invite.normalizeCode(c.lowercase().replace("-", " "))); assertTrue(Invite.isGeneratedCode(c)) }
        assertTrue(Invite.webUrl("G", "K7QF-2M9X-PA4T-W8RJ").startsWith(Invite.WEB_PREFIX))
    }
}
