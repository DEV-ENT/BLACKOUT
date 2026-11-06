import Foundation
import CryptoKit

/// BIP-340 Schnorr signatures over secp256k1, as Nostr requires for every event (NIP-01). Plain Swift, no library;
/// same results as the Android app's Schnorr.kt. Only signs relay events with a throwaway key: messages are protected
/// by DarkProof's own encryption, so this signature proves nothing about who wrote a message. Not constant-time.
public enum Schnorr {
    /// 256-bit numbers as 4 little-endian 64-bit limbs.
    typealias U = [UInt64]

    /// A modulus m = 2^256 - c, so reducing folds the high half back in as high * c.
    struct Mod { let m: U; let c: [UInt64] }
    static let p = Mod(m: [0xFFFFFFFEFFFFFC2F, .max, .max, .max], c: [0x1000003D1])
    static let n = Mod(m: [0xBFD25E8CD0364141, 0xBAAEDCE6AF48A03B, 0xFFFFFFFFFFFFFFFE, .max],
                       c: [0x402DA1732FC9BEBF, 0x4551231950B75FC4, 0x1])
    static let g = (x: u("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"),
                    y: u("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"))

    // MARK: - Numbers

    static func u(_ hex: String) -> U { u(Hex.decode(hex)) }
    static func u(_ d: Data) -> U { // 32 big-endian bytes
        let b = [UInt8](d)
        return (0..<4).map { i in (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[(3 - i) * 8 + $1]) } }
    }
    static func bytes(_ a: U) -> Data {
        Data((0..<32).map { i in UInt8(truncatingIfNeeded: a[3 - i / 8] >> (56 - 8 * UInt64(i % 8))) })
    }
    static func isZero(_ a: U) -> Bool { a.allSatisfy { $0 == 0 } }
    static func less(_ a: U, _ b: U) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }
    static func bit(_ a: U, _ i: Int) -> Bool { a[i / 64] >> UInt64(i % 64) & 1 == 1 }

    /// a - b over 4 limbs, wrapping; also says whether it borrowed.
    static func sub(_ a: U, _ b: U) -> (U, Bool) {
        var r = U(repeating: 0, count: 4); var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            r[i] = d2; borrow = (o1 || o2) ? 1 : 0
        }
        return (r, borrow == 1)
    }

    /// a + b for any lengths.
    static func addWide(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var r = [UInt64](repeating: 0, count: max(a.count, b.count) + 1); var carry: UInt64 = 0
        for i in 0..<(r.count - 1) {
            let (s1, o1) = (i < a.count ? a[i] : 0).addingReportingOverflow(i < b.count ? b[i] : 0)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2; carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        r[r.count - 1] = carry
        return r
    }

    /// a * b for any lengths.
    static func mulWide(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var r = [UInt64](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count where a[i] != 0 {
            var carry: UInt64 = 0
            for j in 0..<b.count {
                let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
                let (s1, o1) = lo.addingReportingOverflow(r[i + j])
                let (s2, o2) = s1.addingReportingOverflow(carry)
                r[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0) // can't overflow: hi <= 2^64 - 2
            }
            r[i + b.count] = carry
        }
        return r
    }

    /// x mod m, for x of any length.
    static func reduce(_ x: [UInt64], _ m: Mod) -> U {
        var x = x
        while x.count > 4 && x[4...].contains(where: { $0 != 0 }) {
            x = addWide(Array(x[0..<4]), mulWide(Array(x[4...]), m.c)) // x = lo + hi * 2^256 = lo + hi * c (mod m)
        }
        var r = Array(x.prefix(4)) + [UInt64](repeating: 0, count: max(0, 4 - x.count))
        while !less(r, m.m) { r = sub(r, m.m).0 }
        return r
    }

    static func add(_ a: U, _ b: U, _ m: Mod) -> U { reduce(addWide(a, b), m) }
    static func sub(_ a: U, _ b: U, _ m: Mod) -> U {
        let (d, borrowed) = sub(a, b)
        return borrowed ? Array(addWide(d, m.m).prefix(4)) : d // wraps back into 0..<m
    }
    static func mul(_ a: U, _ b: U, _ m: Mod) -> U { reduce(mulWide(a, b), m) }
    static func pow(_ a: U, _ e: U, _ m: Mod) -> U {
        var r: U = [1, 0, 0, 0]
        for i in stride(from: 255, through: 0, by: -1) {
            r = mul(r, r, m)
            if bit(e, i) { r = mul(r, a, m) }
        }
        return r
    }
    static func inv(_ a: U, _ m: Mod) -> U { pow(a, sub(m.m, [2, 0, 0, 0]).0, m) }
    static func neg(_ a: U, _ m: Mod) -> U { isZero(a) ? a : sub(m.m, a).0 }

    // MARK: - Points (Jacobian coordinates; z = 0 is the point at infinity)

    struct Point { var x: U; var y: U; var z: U }
    static let infinity = Point(x: [1, 0, 0, 0], y: [1, 0, 0, 0], z: [0, 0, 0, 0])

    static func double(_ a: Point) -> Point {
        if isZero(a.z) || isZero(a.y) { return infinity }
        let y2 = mul(a.y, a.y, p)
        let s = mul([4, 0, 0, 0], mul(a.x, y2, p), p)
        let m = mul([3, 0, 0, 0], mul(a.x, a.x, p), p)
        let x = sub(mul(m, m, p), add(s, s, p), p)
        let y = sub(mul(m, sub(s, x, p), p), mul([8, 0, 0, 0], mul(y2, y2, p), p), p)
        return Point(x: x, y: y, z: mul([2, 0, 0, 0], mul(a.y, a.z, p), p))
    }

    static func add(_ a: Point, _ b: Point) -> Point {
        if isZero(a.z) { return b }
        if isZero(b.z) { return a }
        let z1z1 = mul(a.z, a.z, p), z2z2 = mul(b.z, b.z, p)
        let u1 = mul(a.x, z2z2, p), u2 = mul(b.x, z1z1, p)
        let s1 = mul(a.y, mul(b.z, z2z2, p), p), s2 = mul(b.y, mul(a.z, z1z1, p), p)
        if u1 == u2 { return s1 == s2 ? double(a) : infinity }
        let h = sub(u2, u1, p), r = sub(s2, s1, p)
        let h2 = mul(h, h, p), h3 = mul(h, h2, p), u1h2 = mul(u1, h2, p)
        let x = sub(sub(mul(r, r, p), h3, p), add(u1h2, u1h2, p), p)
        let y = sub(mul(r, sub(u1h2, x, p), p), mul(s1, h3, p), p)
        return Point(x: x, y: y, z: mul(h, mul(a.z, b.z, p), p))
    }

    static func mul(_ a: Point, _ k: U) -> Point {
        var r = infinity
        for i in stride(from: 255, through: 0, by: -1) {
            r = double(r)
            if bit(k, i) { r = add(r, a) }
        }
        return r
    }

    /// Affine (x, y), or nil for the point at infinity.
    static func affine(_ a: Point) -> (x: U, y: U)? {
        if isZero(a.z) { return nil }
        let zi = inv(a.z, p), zi2 = mul(zi, zi, p)
        return (mul(a.x, zi2, p), mul(a.y, mul(zi2, zi, p), p))
    }

    static func timesG(_ k: U) -> (x: U, y: U)? { affine(mul(Point(x: g.x, y: g.y, z: [1, 0, 0, 0]), k)) }

    static func tagged(_ tag: String, _ parts: Data...) -> Data {
        let t = Data(SHA256.hash(data: Data(tag.utf8)))
        return Data(SHA256.hash(data: parts.reduce(t + t, +)))
    }

    // MARK: - BIP-340

    /// A new random secret key (1 … n-1).
    public static func newSecret() -> Data {
        var rng = SystemRandomNumberGenerator() // cryptographically secure on Apple platforms
        while true {
            let k = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let v = u(k)
            if !isZero(v) && less(v, n.m) { return k }
        }
    }

    /// The 32-byte x-only public key of `secret`.
    public static func publicKey(_ secret: Data) -> Data { bytes(timesG(u(secret))!.x) }

    /// BIP-340 signature of the 32-byte `message`; `aux` is fresh randomness (fixed only in test vectors).
    public static func sign(secret: Data, message: Data, aux: Data? = nil) -> Data {
        let aux = aux ?? newSecret()
        precondition(secret.count == 32 && message.count == 32 && aux.count == 32)
        let d0 = u(secret)
        precondition(!isZero(d0) && less(d0, n.m))
        let pub = timesG(d0)!
        let d = bit(pub.y, 0) ? neg(d0, n) : d0
        let t = Data(zip(bytes(d), tagged("BIP0340/aux", aux)).map { $0 ^ $1 })
        let k0 = reduce(u(tagged("BIP0340/nonce", t, bytes(pub.x), message)), n)
        precondition(!isZero(k0))
        let r = timesG(k0)!
        let k = bit(r.y, 0) ? neg(k0, n) : k0
        let e = reduce(u(tagged("BIP0340/challenge", bytes(r.x), bytes(pub.x), message)), n)
        return bytes(r.x) + bytes(add(k, mul(e, d, n), n))
    }

    /// BIP-340 verification, for tests.
    public static func verify(pubkey: Data, message: Data, signature sig: Data) -> Bool {
        guard pubkey.count == 32, message.count == 32, sig.count == 64 else { return false }
        let px = u(pubkey)
        guard less(px, p.m) else { return false }
        let c = add(mul(px, mul(px, px, p), p), [7, 0, 0, 0], p)
        var y = pow(c, Array(addWide(p.m, [1]).prefix(4)).shiftedRight2, p) // (p + 1) / 4
        guard mul(y, y, p) == c else { return false }
        if bit(y, 0) { y = neg(y, p) }
        let r = u(sig.prefix(32)), s = u(sig.suffix(32))
        guard less(r, p.m), less(s, n.m) else { return false }
        let e = reduce(u(tagged("BIP0340/challenge", sig.prefix(32), pubkey, message)), n)
        let sum = add(mul(Point(x: g.x, y: g.y, z: [1, 0, 0, 0]), s), mul(Point(x: px, y: y, z: [1, 0, 0, 0]), neg(e, n)))
        guard let rr = affine(sum) else { return false }
        return !bit(rr.y, 0) && rr.x == r
    }
}

private extension Array where Element == UInt64 {
    /// This 4-limb number shifted right by 2 bits.
    var shiftedRight2: [UInt64] { (0..<4).map { i in self[i] >> 2 | (i < 3 ? self[i + 1] << 62 : 0) } }
}

/// A throwaway Nostr key, made new at every start so relays can't link one session to the next.
public struct NostrKey: Sendable {
    private let secret: Data
    public let pubkey: String // x-only public key, 64 hex chars

    public init(secret: Data = Schnorr.newSecret()) {
        self.secret = secret
        pubkey = Hex.encode(Schnorr.publicKey(secret))
    }

    /// The 64-byte signature of a 32-byte event id.
    public func sign(_ id: Data) -> Data { Schnorr.sign(secret: secret, message: id) }
}
