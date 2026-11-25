package net.fledgewing.orbitcompanion

import java.math.BigInteger
import java.security.MessageDigest

/**
 * Ed25519 signature verification (RFC 8032 §5.1.7), in plain BigInteger arithmetic: the
 * platform's Ed25519 needs API 33 and the companion runs from API 26. Verification only, and
 * never on secret data, so constant time doesn't matter. Rejects a non-canonical S (S >= L)
 * and point encodings that don't decode; the check is the cofactorless [S]B == R + [k]A.
 */
object Ed25519 {
    private val P: BigInteger = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19))
    private val L: BigInteger = BigInteger.ONE.shiftLeft(252).add(BigInteger("27742317777372353535851937790883648493"))
    private val D: BigInteger = BigInteger.valueOf(-121665).multiply(BigInteger.valueOf(121666).modInverse(P)).mod(P)
    private val SQRT_M1: BigInteger = BigInteger.valueOf(2).modPow(P.subtract(BigInteger.ONE).shiftRight(2), P)
    private val TWO = BigInteger.valueOf(2)

    /** A point in extended coordinates (X:Y:Z:T), x = X/Z, y = Y/Z, xy = T/Z. */
    private class Pt(val x: BigInteger, val y: BigInteger, val z: BigInteger, val t: BigInteger)

    private val IDENTITY = Pt(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
    private val B: Pt = run {
        val y = BigInteger.valueOf(4).multiply(BigInteger.valueOf(5).modInverse(P)).mod(P)
        val x = recoverX(y, 0) ?: error("base point")
        Pt(x, y, BigInteger.ONE, x.multiply(y).mod(P))
    }

    private fun add(a: Pt, b: Pt): Pt {
        val aa = a.y.subtract(a.x).multiply(b.y.subtract(b.x)).mod(P)
        val bb = a.y.add(a.x).multiply(b.y.add(b.x)).mod(P)
        val c = TWO.multiply(a.t).multiply(b.t).multiply(D).mod(P)
        val dd = TWO.multiply(a.z).multiply(b.z).mod(P)
        val e = bb.subtract(aa)
        val f = dd.subtract(c)
        val g = dd.add(c)
        val h = bb.add(aa)
        return Pt(e.multiply(f).mod(P), g.multiply(h).mod(P), f.multiply(g).mod(P), e.multiply(h).mod(P))
    }

    private fun mul(s: BigInteger, p: Pt): Pt {
        var q = IDENTITY
        for (i in s.bitLength() - 1 downTo 0) {
            q = add(q, q)
            if (s.testBit(i)) q = add(q, p)
        }
        return q
    }

    private fun equal(a: Pt, b: Pt): Boolean =
        a.x.multiply(b.z).subtract(b.x.multiply(a.z)).mod(P).signum() == 0 &&
            a.y.multiply(b.z).subtract(b.y.multiply(a.z)).mod(P).signum() == 0

    private fun recoverX(y: BigInteger, sign: Int): BigInteger? {
        if (y >= P) return null
        val y2 = y.multiply(y)
        val x2 = y2.subtract(BigInteger.ONE).multiply(D.multiply(y2).add(BigInteger.ONE).modInverse(P)).mod(P)
        if (x2.signum() == 0) return if (sign == 1) null else BigInteger.ZERO
        var x = x2.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P)
        if (x.multiply(x).subtract(x2).mod(P).signum() != 0) x = x.multiply(SQRT_M1).mod(P)
        if (x.multiply(x).subtract(x2).mod(P).signum() != 0) return null
        if (x.testBit(0) != (sign == 1)) x = P.subtract(x)
        return x
    }

    private fun littleEndian(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

    private fun decode(s: ByteArray): Pt? {
        if (s.size != 32) return null
        val sign = (s[31].toInt() shr 7) and 1
        val yb = s.copyOf()
        yb[31] = (yb[31].toInt() and 0x7f).toByte()
        val y = littleEndian(yb)
        val x = recoverX(y, sign) ?: return null
        return Pt(x, y, BigInteger.ONE, x.multiply(y).mod(P))
    }

    fun verify(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
        if (publicKey.size != 32 || signature.size != 64) return false
        val a = decode(publicKey) ?: return false
        val rBytes = signature.copyOfRange(0, 32)
        val r = decode(rBytes) ?: return false
        val s = littleEndian(signature.copyOfRange(32, 64))
        if (s >= L) return false
        val md = MessageDigest.getInstance("SHA-512")
        md.update(rBytes)
        md.update(publicKey)
        md.update(message)
        val k = littleEndian(md.digest()).mod(L)
        return equal(mul(s, B), add(r, mul(k, a)))
    }
}

/**
 * Release signatures (docs/design/release-signing.md): the release's SIGNATURES file holds a
 * release-key certificate from the offline root key, and the release key's signature over each
 * asset's tag, name and SHA-256. The companion checks the plugin zip with it.
 */
object ReleaseSignature {
    const val ASSET = "SIGNATURES"
    private const val CERT_DOMAIN = "orbify-release-key-v1\n"
    private const val ARTIFACT_DOMAIN = "orbify-artifact-v1\n"
    private val CERT_LINE = Regex("""^release-key ([0-9a-f]{200})$""")
    private val SIG_LINE = Regex("""^([0-9a-f]{128}) {2}(\S+)$""")

    sealed class Result {
        object Ok : Result()
        data class Unsigned(val why: String) : Result()
        data class Invalid(val why: String) : Result()
    }

    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    /**
     * Checks [asset] (whose SHA-256 is [sha256], lowercase hex) released under [tag] against the
     * release's [signatures] text (null: the release has none) and [rootKey] (64 hex; empty: this
     * build has no root key yet).
     */
    fun check(rootKey: String, minSerial: Long, signatures: String?, tag: String, asset: String, sha256: String): Result {
        if (rootKey.isEmpty()) return Result.Unsigned("no root key in this build")
        if (signatures == null) return Result.Unsigned("the release has no $ASSET")
        val lines = signatures.lineSequence().map { it.trimEnd('\r') }.filter { it.isNotBlank() }.toList()
        val cert = lines.firstNotNullOfOrNull { CERT_LINE.matchEntire(it)?.groupValues?.get(1) }
            ?: return Result.Invalid("$ASSET has no release-key certificate")
        val sig = lines.firstNotNullOfOrNull { l -> SIG_LINE.matchEntire(l)?.takeIf { it.groupValues[2] == asset }?.groupValues?.get(1) }
            ?: return Result.Unsigned("$ASSET has no line for $asset")
        val certBytes = hex(cert)
        val serialAndKey = certBytes.copyOfRange(0, 36)
        val serial = BigInteger(1, certBytes.copyOfRange(0, 4)).toLong()
        val releaseKey = certBytes.copyOfRange(4, 36)
        if (!Ed25519.verify(hex(rootKey), CERT_DOMAIN.toByteArray() + serialAndKey, certBytes.copyOfRange(36, 100))) {
            return Result.Invalid("the release key is not certified by this build's root key")
        }
        if (serial < minSerial) return Result.Invalid("release key $serial is revoked (minimum $minSerial)")
        val message = "$ARTIFACT_DOMAIN$tag\n$asset\n${sha256.lowercase()}\n".toByteArray()
        if (!Ed25519.verify(releaseKey, message, hex(sig))) return Result.Invalid("bad signature on $asset for $tag")
        return Result.Ok
    }

    /**
     * What the installer does with [result]: null to go ahead (logging an unsigned or invalid
     * zip while signatures are not enforced), or the reason the zip is refused.
     */
    fun refusal(result: Result, enforce: Boolean, log: (String) -> Unit): String? = when (result) {
        Result.Ok -> { log("plugin zip signature verified"); null }
        is Result.Unsigned -> if (enforce) "the plugin zip is unsigned (${result.why}); not installed"
            else { log("plugin zip unsigned (${result.why})"); null }
        is Result.Invalid -> if (enforce) "the plugin zip's signature is invalid (${result.why}); not installed"
            else { log("plugin zip signature invalid: ${result.why}"); null }
    }
}
