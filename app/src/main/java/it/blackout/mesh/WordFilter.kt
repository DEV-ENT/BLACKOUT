package it.blackout.mesh

import java.text.Normalizer

/**
 * Masks offensive words in other people's Everyone messages and places with bullets (spec/FORMAT.md, "Everyone
 * filter"). Words are masked, not whole messages hidden, so an emergency message with a swear word still gets through.
 * Same list and rules as the iPhone's WordFilter.swift; the tests check both against the same examples.
 */
object WordFilter {
    /** Space-separated; a trailing * matches any word starting with it. Same text on both apps (SHA-256 in the tests). */
    const val LIST = "fuck* motherfuck* shit* bitch* bastard* asshole* cunt* dickhead* wanker* twat* whore* slut* porn* blowjob* dildo* cumshot* nigger* nigga* faggot* kike* spic spics wetback* tranny trannies gook gooks retard retards retarded paki pakis cazz* minchi* vaffanculo* fanculo* stronz* coglion* puttana puttane puttaniere troia troie frocio froci ricchion* culatton* porcodio dioporco porcamadonna"

    private val words = LIST.split(' ')
    private val exact = words.filter { !it.endsWith('*') }.toSet()
    private val prefixes = words.filter { it.endsWith('*') }.map { it.dropLast(1) }
    private val leet = mapOf('0' to 'o', '1' to 'i', '3' to 'e', '4' to 'a', '5' to 's', '7' to 't', '@' to 'a', '$' to 's')

    private fun inToken(c: Char) = c.isLetterOrDigit() || c == '@' || c == '$' || Character.getType(c) == Character.NON_SPACING_MARK.toInt()
    private fun fold(s: String) = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "")
    private fun listed(k: String) = k in exact || prefixes.any { k.startsWith(it) }

    /** True if this word is on the list, also when written in capitals, with accents, l33t or stretched ("fuuuck"). */
    fun offensive(token: String): Boolean {
        val key = fold(token).lowercase().map { leet[it] ?: it }.filter { it in 'a'..'z' }.joinToString("")
        if (key.isEmpty()) return false
        if (listed(key)) return true
        if (!Regex("(.)\\1\\1").containsMatchIn(key)) return false // stretched: runs of 3+ letters
        return listed(key.replace(Regex("(.)\\1{2,}"), "$1$1")) || listed(key.replace(Regex("(.)\\1{2,}"), "$1"))
    }

    /** [text] with each offensive word replaced by as many bullets as it has letters. */
    fun clean(text: String): String {
        val out = StringBuilder(); var i = 0
        while (i < text.length) {
            if (!inToken(text[i])) { out.append(text[i]); i++; continue }
            var j = i
            while (j < text.length && inToken(text[j])) j++
            val token = text.substring(i, j)
            out.append(if (token.any { it.isLetter() } && offensive(token)) "•".repeat(fold(token).length) else token)
            i = j
        }
        return out.toString()
    }
}
