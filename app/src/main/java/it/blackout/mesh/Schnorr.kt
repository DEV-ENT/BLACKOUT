package it.blackout.mesh

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * BIP-340 Schnorr signatures over secp256k1, as Nostr requires for every event (NIP-01). Plain BigInteger arithmetic,
 * no native library. Only used to sign relay events with a throwaway key: messages themselves are protected by
 * DarkProof's own encryption, so this signature proves nothing about who wrote a message.
 */
object Schnorr {
    private val P = BigInteger("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", 16)
    private val N = BigInteger("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16)
    private val G = Point(BigInteger("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798", 16),
                          BigInteger("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8", 16))
    private val SEVEN = BigInteger.valueOf(7)

    private class Point(val x: BigInteger, val y: BigInteger)

    private fun add(a: Point?, b: Point?): Point? {
        if (a == null) return b
        if (b == null) return a
        if (a.x == b.x && a.y != b.y) return null
        val l = if (a.x == b.x) a.x.pow(2).multiply(BigInteger.valueOf(3)).multiply(a.y.shiftLeft(1).modInverse(P)).mod(P)
                else b.y.subtract(a.y).multiply(b.x.subtract(a.x).modInverse(P)).mod(P)
        val x = l.pow(2).subtract(a.x).subtract(b.x).mod(P)
        return Point(x, l.multiply(a.x.subtract(x)).subtract(a.y).mod(P))
    }

    private fun mul(p: Point, k: BigInteger): Point? {
        var r: Point? = null; var q: Point? = p
        for (i in 0 until k.bitLength()) { if (k.testBit(i)) r = add(r, q); q = add(q, q) }
        return r
    }

    private fun bytes32(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        return when { b.size == 32 -> b; b.size > 32 -> b.copyOfRange(b.size - 32, b.size); else -> ByteArray(32 - b.size) + b }
    }
    private fun int(b: ByteArray) = BigInteger(1, b)
    private fun sha(vararg parts: ByteArray) = MessageDigest.getInstance("SHA-256").run { parts.forEach(::update); digest() }
    private fun tagged(tag: String, vararg parts: ByteArray): ByteArray { val t = sha(tag.toByteArray()); return sha(t, t, *parts) }

    /** A new random secret key (1 … n-1). */
    fun newSecret(rnd: SecureRandom = SecureRandom()): ByteArray {
        while (true) { val k = ByteArray(32).also(rnd::nextBytes); val v = int(k); if (v.signum() > 0 && v < N) return k }
    }

    /** The 32-byte x-only public key of [secret]. */
    fun publicKey(secret: ByteArray): ByteArray = bytes32(mul(G, int(secret))!!.x)

    /** BIP-340 signature of the 32-byte [msg]; [aux] is fresh randomness (all zeros only in test vectors). */
    fun sign(secret: ByteArray, msg: ByteArray, aux: ByteArray = ByteArray(32).also(SecureRandom()::nextBytes)): ByteArray {
        require(msg.size == 32 && aux.size == 32)
        val d0 = int(secret); require(d0.signum() > 0 && d0 < N)
        val pub = mul(G, d0)!!
        val d = if (pub.y.testBit(0)) N.subtract(d0) else d0
        val t = bytes32(d).zip(tagged("BIP0340/aux", aux)) { a, b -> (a.toInt() xor b.toInt()).toByte() }.toByteArray()
        val k0 = int(tagged("BIP0340/nonce", t, bytes32(pub.x), msg)).mod(N)
        require(k0.signum() != 0)
        val r = mul(G, k0)!!
        val k = if (r.y.testBit(0)) N.subtract(k0) else k0
        val e = int(tagged("BIP0340/challenge", bytes32(r.x), bytes32(pub.x), msg)).mod(N)
        return bytes32(r.x) + bytes32(k.add(e.multiply(d)).mod(N))
    }

    /** BIP-340 verification, for tests and for checking events from relays if ever needed. */
    fun verify(pub: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
        if (pub.size != 32 || msg.size != 32 || sig.size != 64) return false
        val px = int(pub); if (px >= P) return false
        val c = px.pow(3).add(SEVEN).mod(P)
        val y = c.modPow(P.add(BigInteger.ONE).shiftRight(2), P)
        if (y.modPow(BigInteger.valueOf(2), P) != c) return false // not BigInteger.TWO: that needs Android 13
        val point = Point(px, if (y.testBit(0)) P.subtract(y) else y)
        val r = int(sig.copyOfRange(0, 32)); val s = int(sig.copyOfRange(32, 64))
        if (r >= P || s >= N) return false
        val e = int(tagged("BIP0340/challenge", sig.copyOfRange(0, 32), pub, msg)).mod(N)
        val rr = add(mul(G, s), mul(point, N.subtract(e))) ?: return false
        return !rr.y.testBit(0) && rr.x == r
    }
}
