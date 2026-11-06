package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest

/** BIP-340 test vector 0, plus a vector computed with @noble/curves 1.9.7, an independent implementation. */
class SchnorrTest {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun sha(s: String) = MessageDigest.getInstance("SHA-256").digest(s.toByteArray())

    @Test fun bip340Vector0() {
        val sk = unhex("0000000000000000000000000000000000000000000000000000000000000003")
        assertEquals("f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9", hex(Schnorr.publicKey(sk)))
        val sig = Schnorr.sign(sk, ByteArray(32), ByteArray(32))
        assertEquals("e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0", hex(sig))
        assertTrue(Schnorr.verify(Schnorr.publicKey(sk), ByteArray(32), sig))
    }

    @Test fun matchesNoble() {
        val sk = sha("darkproof-test-key"); val msg = sha("hello nostr")
        assertEquals("6dd447ac274cd77ed2bb1373b5571a181271583014de6a085437d709bc613bd5", hex(Schnorr.publicKey(sk)))
        assertEquals("625c3e45540c87f016e7cb88c28bb66d25b4d352e94a006af3f1489d5e9a0e896ee4890515b6c1e1e1026672d6a7ed6d3aa42de168101e8c036dd55222626e68",
            hex(Schnorr.sign(sk, msg, ByteArray(32) { 1 })))
    }

    @Test fun randomKeysSignAndVerify() {
        repeat(3) {
            val sk = Schnorr.newSecret(); val pub = Schnorr.publicKey(sk); val msg = sha("m$it")
            val sig = Schnorr.sign(sk, msg)
            assertTrue(Schnorr.verify(pub, msg, sig))
            assertFalse(Schnorr.verify(pub, sha("other"), sig))
            assertFalse(Schnorr.verify(pub, msg, sig.copyOf().also { s -> s[63] = (s[63] + 1).toByte() }))
        }
    }
}
