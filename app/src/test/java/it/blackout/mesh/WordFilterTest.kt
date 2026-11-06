package it.blackout.mesh

import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.MessageDigest

/** Same examples as the iPhone's WordFilterTests. */
class WordFilterTest {
    @Test fun listMatchesIphone() {
        val h = MessageDigest.getInstance("SHA-256").digest(WordFilter.LIST.toByteArray()).joinToString("") { "%02x".format(it) }
        assertEquals("502386ef2f3c02c84bfe8beb523b0c3642932eeefdc2fb6f2efad507087654ed", h)
    }

    @Test fun masksWordsKeepsTheRest() {
        for ((input, expected) in EXAMPLES) assertEquals(input, expected, WordFilter.clean(input))
    }

    companion object {
        val EXAMPLES = listOf(
            "Fuck this" to "•••• this",
            "fuuuuck you" to "••••••• you",
            "Sh1t, the bridge is down" to "••••, the bridge is down",
            "a\$\$hole" to "•••••••",
            "Che cazzo succede?" to "Che ••••• succede?",
            "VAFFANCULO!" to "••••••••••!",
            "Stronzò" to "•••••••",
            "🙂 fuck 🙂" to "🙂 •••• 🙂",
            "Water at the fountain, 45.46420, 9.19000" to "Water at the fountain, 45.46420, 9.19000",
            "Fire retardant on the road" to "Fire retardant on the road",
            "Pasta alla puttanesca, scrabble, Scunthorpe" to "Pasta alla puttanesca, scrabble, Scunthorpe",
            "Città vecchia" to "Città vecchia",
        )
    }
}
