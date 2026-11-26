// @fixture release-signing/cases.json
// @fixture release-signing/SIGNATURES-firmware
// @fixture release-signing/SIGNATURES-plugin
// @fixture release-signing/SIGNATURES-plugin-other-root
// @fixture release-signing/SIGNATURES-plugin-rotated
package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature

/** The plugin zip's release signature (docs/design/release-signing.md). */
class ReleaseSignatureTest {
    private val fx = File("../../../shared/fixtures/release-signing")

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun sha(b: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(b))

    /** shared/fixtures/release-signing/cases.json: the cases the firmware's host tests check too. */
    @Test
    fun sharedFixtureCases() {
        val doc = JSONObject(File(fx, "cases.json").readText())
        val root = doc.getString("root_public_key")
        val cases = doc.getJSONArray("cases")
        assertTrue(cases.length() >= 9)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val r = ReleaseSignature.check(
                root, c.getLong("min_serial"), File(fx, c.getString("signatures")).readText(),
                c.getString("tag"), c.getString("asset"), c.getString("sha256"),
            )
            assertEquals(c.getString("name") + ": $r", c.getBoolean("ok"), r == ReleaseSignature.Result.Ok)
        }
        // The same valid case under a root that signed nothing.
        val c = cases.getJSONObject(0)
        val r = ReleaseSignature.check(
            doc.getString("other_root_public_key"), 1, File(fx, c.getString("signatures")).readText(),
            c.getString("tag"), c.getString("asset"), c.getString("sha256"),
        )
        assertTrue(r.toString(), r is ReleaseSignature.Result.Invalid)
    }

    /** RFC 8032 §7.1 tests 1–3, and one flipped bit of each. */
    @Test
    fun rfc8032Vectors() {
        val vectors = listOf(
            Triple(
                "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
            ),
            Triple(
                "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
                "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
            ),
            Triple(
                "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
                "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
            ),
        )
        for ((pk, msg, sig) in vectors) {
            val p = ReleaseSignature.hex(pk)
            val m = ReleaseSignature.hex(msg)
            val s = ReleaseSignature.hex(sig)
            assertTrue(pk, Ed25519.verify(p, m, s))
            val bad = s.copyOf().also { it[5] = (it[5].toInt() xor 1).toByte() }
            assertFalse(pk, Ed25519.verify(p, m, bad))
            assertFalse(pk, Ed25519.verify(p, m + 0, s))
        }
    }

    /** S >= L (S + L of a valid signature) is refused, as are keys that don't decode. */
    @Test
    fun malleableAndMalformedRefused() {
        val p = ReleaseSignature.hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        val s = ReleaseSignature.hex(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        )
        val l = java.math.BigInteger.ONE.shiftLeft(252).add(java.math.BigInteger("27742317777372353535851937790883648493"))
        val sPlusL = java.math.BigInteger(1, s.copyOfRange(32, 64).reversedArray()).add(l)
        val le = sPlusL.toByteArray().reversedArray().copyOf(32)
        assertFalse(Ed25519.verify(p, ByteArray(0), s.copyOfRange(0, 32) + le))
        assertFalse(Ed25519.verify(ByteArray(32) { 0xff.toByte() }, ByteArray(0), s))
        assertFalse(Ed25519.verify(p.copyOf(31), ByteArray(0), s))
    }

    // --- Keys made here with the JDK's Ed25519 (test JVM only), signed as tools/feed-keys does.

    private fun keyPair(): KeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
    private fun raw(kp: KeyPair) = kp.public.encoded.takeLast(32).toByteArray()
    private fun sign(kp: KeyPair, msg: ByteArray): ByteArray =
        Signature.getInstance("Ed25519").run { initSign(kp.private); update(msg); sign() }

    private fun signatures(root: KeyPair, release: KeyPair, serial: Long, tag: String, asset: String, sha256: String): String {
        val head = byteArrayOf((serial shr 24).toByte(), (serial shr 16).toByte(), (serial shr 8).toByte(), serial.toByte()) + raw(release)
        val cert = head + sign(root, "orbify-release-key-v1\n".toByteArray() + head)
        val sig = sign(release, "orbify-artifact-v1\n$tag\n$asset\n$sha256\n".toByteArray())
        return "release-key ${hex(cert)}\n${hex(sig)}  $asset\n"
    }

    @Test
    fun androidFeedAuthenticatesWithdrawalsAndReleaseSelectionTogether() {
        val root = keyPair()
        val rootHex = hex(raw(root))
        val payload = """{"withdrawn":["v0.11.3-rc.11"],"releases":[{"tag_name":"v0.11.3-rc.11","prerelease":true},{"tag_name":"v0.11.3-rc.9","prerelease":true}]}"""
        val sigs = signatures(root, keyPair(), 1, AndroidReleaseFeed.TAG, AndroidReleaseFeed.ASSET, sha(payload.toByteArray()))
        fun envelope(body: String = payload, sig: String = sigs) = JSONObject()
            .put("payload", body).put("signatures", sig).toString()
        val feed = AndroidReleaseFeed.parse(envelope(), rootHex, 1)
        assertEquals("v0.11.3-rc.9", UpdatePolicy.pick(feed.releases, UpdateChannel.PREVIEW, feed.withdrawn)?.tag)
        for ((body, signature, key, serial) in listOf(
            listOf(payload.replace("v0.11.3-rc.11", "v0.11.3-rc.10"), sigs, rootHex, "1"),
            listOf(payload.replace("rc.9", "rc.12"), sigs, rootHex, "1"),
            listOf(payload, "", rootHex, "1"),
            listOf(payload, sigs, hex(raw(keyPair())), "1"),
            listOf(payload, sigs, rootHex, "2"),
        )) {
            try {
                AndroidReleaseFeed.parse(envelope(body, signature), key, serial.toLong())
                throw AssertionError("untrusted feed accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }

    @Test
    fun repositoryRenameDoesNotRewriteAnAlreadySignedAndroidPayload() {
        val root = keyPair()
        val rootHex = hex(raw(root))
        val release = keyPair()
        val name = "orbit-companion-1.0.0.apk"
        val oldUrl = "https://github.com/${Updater.LEGACY_REPO}/releases/download/v1.0.0/$name"
        val payload = JSONObject().put("withdrawn", org.json.JSONArray()).put("releases",
            org.json.JSONArray().put(JSONObject().put("tag_name", "v1.0.0").put("assets",
                org.json.JSONArray().put(JSONObject().put("name", name).put("browser_download_url", oldUrl))))).toString()
        fun envelope(body: String, resign: Boolean = false): String {
            val signedBody = if (resign) body else payload
            return JSONObject().put("payload", body).put("signatures",
                signatures(root, release, 1, AndroidReleaseFeed.TAG, AndroidReleaseFeed.ASSET,
                    sha(signedBody.toByteArray()))).toString()
        }
        // Moving the envelope's fetch location leaves these exact payload bytes valid.
        assertEquals(oldUrl, AndroidReleaseFeed.parse(envelope(payload), rootHex, 1).releases.single().assets[name])
        val renamed = payload.replace(Updater.LEGACY_REPO, Updater.REPO)
        assertNotEquals(payload, renamed)
        try {
            AndroidReleaseFeed.parse(envelope(renamed), rootHex, 1)
            throw AssertionError("rewritten payload accepted without a new signature")
        } catch (_: IllegalArgumentException) { }
        assertEquals(oldUrl.replace(Updater.LEGACY_REPO, Updater.REPO),
            AndroidReleaseFeed.parse(envelope(renamed, resign = true), rootHex, 1).releases.single().assets[name])
    }

    @Test
    fun pluginZipChecks() {
        val root = keyPair()
        val rootHex = hex(raw(root))
        val zip = "plugin zip bytes".toByteArray()
        val sha = sha(zip)
        val ci1 = keyPair()
        val sigs = signatures(root, ci1, 1, "v0.9.0", PatchFile.ZIP, sha)
        fun check(s: String?, min: Long = 1, root: String = rootHex, digest: String = sha, tag: String = "v0.9.0") =
            ReleaseSignature.check(root, min, s, tag, PatchFile.ZIP, digest)

        assertEquals(ReleaseSignature.Result.Ok, check(sigs))
        // Wrong root.
        assertTrue(check(sigs, root = hex(raw(keyPair()))) is ReleaseSignature.Result.Invalid)
        // Tampered zip.
        assertTrue(check(sigs, digest = sha("plugin zip bytes!".toByteArray())) is ReleaseSignature.Result.Invalid)
        // Another version's tag.
        assertTrue(check(sigs, tag = "v0.9.1") is ReleaseSignature.Result.Invalid)
        // Rotated CI key: serial 2 from the same root, and serial 1 revoked.
        val sigs2 = signatures(root, keyPair(), 2, "v0.9.0", PatchFile.ZIP, sha)
        assertEquals(ReleaseSignature.Result.Ok, check(sigs2, min = 2))
        assertTrue(check(sigs, min = 2) is ReleaseSignature.Result.Invalid)
        // A release key the root never certified.
        val forged = sigs.replaceFirst(Regex("release-key [0-9a-f]{8}([0-9a-f]{64})"), "release-key 00000001" + hex(raw(keyPair())))
        assertTrue(check(forged) is ReleaseSignature.Result.Invalid)
        // Unsigned: no root key in this build, no SIGNATURES, no line for the zip.
        assertTrue(check(sigs, root = "") is ReleaseSignature.Result.Unsigned)
        assertTrue(check(null) is ReleaseSignature.Result.Unsigned)
        assertTrue(
            ReleaseSignature.check(rootHex, 1, sigs, "v0.9.0", "other.zip", sha) is ReleaseSignature.Result.Unsigned,
        )
    }

    /** Not enforced: unsigned and invalid zips install with a log line. Enforced: refused. */
    @Test
    fun enforceDecidesTheInstall() {
        val logs = mutableListOf<String>()
        val unsigned = ReleaseSignature.Result.Unsigned("the release has no SIGNATURES")
        val invalid = ReleaseSignature.Result.Invalid("bad signature")
        assertNull(ReleaseSignature.refusal(unsigned, false) { logs += it })
        assertNull(ReleaseSignature.refusal(invalid, false) { logs += it })
        assertTrue(logs.toString(), logs[0].startsWith("plugin zip unsigned"))
        assertTrue(logs.toString(), logs[1].startsWith("plugin zip signature invalid"))
        assertTrue(ReleaseSignature.refusal(unsigned, true) {}!!.contains("not installed"))
        assertTrue(ReleaseSignature.refusal(invalid, true) {}!!.contains("not installed"))
        assertNull(ReleaseSignature.refusal(ReleaseSignature.Result.Ok, true) {})
    }

    /** This build follows shared/release-signing.json. */
    @Test
    fun buildConfigFollowsSharedConfig() {
        val cfg = JSONObject(File("../../../shared/release-signing.json").readText())
        assertEquals(cfg.getString("root_public_key"), BuildConfig.RELEASE_ROOT_KEY)
        assertEquals(cfg.getLong("min_release_key_serial"), BuildConfig.RELEASE_MIN_SERIAL)
        assertEquals(cfg.getBoolean("enforce"), BuildConfig.RELEASE_SIG_ENFORCE)
    }
}
