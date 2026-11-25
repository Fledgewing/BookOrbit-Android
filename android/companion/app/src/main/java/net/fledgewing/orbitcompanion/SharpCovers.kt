package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.CharBuffer
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import net.fledgewing.orbitcompanion.SharpCoversLogic.Outcome
import net.fledgewing.orbitcompanion.SharpCoversLogic.State

/**
 * Sharp sleep-screen covers on the device (docs/design/lock-screen.md L7, R3; rules in
 * SharpCoversLogic). Sign-in once: the OPDS login fetches one feed, the cover token is taken from
 * an image link and kept sealed with a Keystore key; the password is never stored or logged and is
 * zeroed after use. The fetch runs off the main thread when the plugin's pool changes (SLEEP_POOL,
 * sent after a refresh while the network is up), never at sleep: each pool cover is fetched with
 * its ETag, fitted once to the panel and stored in app storage (bounded, LRU). The sleep screen
 * uses a sharp cover when it has one, else the plugin's thumbnail.
 *
 * The fetch lives here until the companion's worker (docs/design/companion-worker.md) lands; it is
 * one entry point, [sync], for that worker to call.
 */
object SharpCovers {
    private const val PREFS = "orbit_sharp"
    const val SETUP_ID = "sharp_covers"

    /** One GET. [headers] never logged: they may hold the login. */
    fun interface Http {
        fun get(url: String, headers: Map<String, String>): Resp
    }

    class Resp(val code: Int, val etag: String?, val body: ByteArray?)

    /** Seals the token at rest. */
    interface Vault {
        fun seal(plain: String): String
        fun open(sealed: String): String?
    }

    @Volatile var http: Http = UrlHttp
    @Volatile var vault: Vault = KeystoreVault
    /** Image bytes -> the cover fitted to the panel (JPEG), or null when it isn't an image. */
    @Volatile var scaler: (ByteArray, Int, Int) -> ByteArray? = ::fitJpeg

    private val worker = BulkWork.executor
    private val busy = AtomicBoolean(false)

    private fun sp(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun dir(ctx: Context): File = File(ctx.applicationContext.filesDir, "sharp-covers")

    fun state(ctx: Context): State = State.of(sp(ctx).getString("state", null))
    fun lostWhy(ctx: Context): String? = sp(ctx).getString("lost_why", null)
    fun user(ctx: Context): String? = sp(ctx).getString("user", null)

    private fun token(ctx: Context): String? = sp(ctx).getString("token", null)?.let { runCatching { vault.open(it) }.getOrNull() }

    /** The server and the KOReader username, as the plugin wrote them into pool.json. */
    data class Account(val server: String, val user: String, val storageLimitMb: Int)

    fun account(dir: File = SleepScreen.dir()): Account? = try {
        val o = JSONObject(File(dir, "pool.json").readText())
        val server = o.optString("server")
        if (SharpCoversLogic.apiBase(server) == null) null else Account(server, o.optString("user"), o.optInt("storage_limit_mb", 250))
    } catch (e: Exception) {
        null
    }

    /** The sharp cover for [id] when there is one (the sleep screen prefers it to the thumbnail). */
    fun fileFor(ctx: Context, id: Long): File? {
        if (state(ctx) != State.ON) return null
        val f = File(dir(ctx), "$id.jpg")
        if (!f.isFile) return null
        f.setLastModified(System.currentTimeMillis()) // LRU: last used
        return f
    }

    fun sharpCount(ctx: Context, ids: List<Long>): Int = ids.count { File(dir(ctx), "$it.jpg").isFile }

    // ---------------------------------------------------------------- sign-in

    /**
     * One feed with Basic auth; on success only the token is kept. [password] is zeroed before
     * this returns, whatever happens. -> null when signed in, else the words to show.
     */
    fun signIn(ctx: Context, server: String, user: String, password: CharArray): String? {
        val base = SharpCoversLogic.apiBase(server)
        var auth: ByteArray? = null
        try {
            if (base == null) return SharpCoversLogic.OFFLINE
            auth = utf8(user.toCharArray() + ':' + password)
            val header = "Basic " + Base64.encodeToString(auth, Base64.NO_WRAP)
            val r = try {
                http.get(SharpCoversLogic.feedUrl(base), mapOf("Authorization" to header, "Accept" to "application/atom+xml"))
            } catch (e: Exception) {
                OLog.w("sharp covers: sign-in feed failed (${e.javaClass.simpleName})")
                return SharpCoversLogic.OFFLINE
            }
            val outcome = SharpCoversLogic.outcome(r.code)
            val tok = if (outcome == Outcome.OK) r.body?.let { SharpCoversLogic.tokenFromFeed(String(it, Charsets.UTF_8)) } else null
            OLog.i("sharp covers: sign-in ${r.code} ${if (tok != null) "token kept" else "no token"}")
            val msg = SharpCoversLogic.signInMessage(outcome, tok != null)
            if (msg == null && tok != null) {
                sp(ctx).edit().putString("token", vault.seal(tok)).putString("state", State.ON.key)
                    .putString("user", user).remove("lost_why").apply()
                onMain { Attention.evaluate(ctx.applicationContext, "sharp covers signed in", notify = false) }
            }
            return msg
        } finally {
            password.fill('\u0000')
            auth?.fill(0)
        }
    }

    fun signOut(ctx: Context, why: String) {
        sp(ctx).edit().remove("token").putString("state", State.NONE.key).remove("lost_why").apply()
        dir(ctx).listFiles()?.filter { it.name != ".nomedia" }?.forEach { it.delete() }
        OLog.i("sharp covers: signed out ($why)")
        SleepScreen.redrawPicture(ctx, "sharp covers off")
    }

    private fun lost(ctx: Context, outcome: Outcome) {
        sp(ctx).edit().remove("token").putString("state", State.LOST.key).putString("lost_why", SharpCoversLogic.lostWhy(outcome)).apply()
        OLog.i("sharp covers: sign-in lost (${outcome.name.lowercase()}); thumbnails until signed in again")
        onMain { Attention.evaluate(ctx.applicationContext, "sharp covers lost") }
    }

    private fun onMain(f: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post { runCatching(f).onFailure { OLog.w("sharp covers: attention failed", it) } }
    }

    private fun utf8(chars: CharArray): ByteArray {
        val bb = Charsets.UTF_8.encode(CharBuffer.wrap(chars))
        val out = ByteArray(bb.remaining()).also { bb.get(it) }
        if (bb.hasArray()) bb.array().fill(0)
        chars.fill('\u0000')
        return out
    }

    // ---------------------------------------------------------------- the fetch

    /** Queues a fetch of the pool's covers (no-op unless signed in and Recommended is on). */
    private val queued = java.util.concurrent.atomic.AtomicBoolean()

    fun sync(ctx: Context, why: String) {
        val app = ctx.applicationContext
        if (state(app) != State.ON || SleepScreen.settings(app).mode != SleepMode.RECOMMENDED) return
        if (!queued.compareAndSet(false, true)) return
        BulkWork.attach(app)
        worker.execute {
            try { runCatching { BulkWork.checkpoint(); syncNow(app, why) }.onFailure { OLog.w("sharp covers: fetch failed ($why)", it) } }
            finally { queued.set(false) }
        }
    }

    /** The fetch itself, on the caller's thread. -> how many covers changed. */
    fun syncNow(ctx: Context, why: String): Int {
        if (!busy.compareAndSet(false, true)) return 0
        try {
            if (state(ctx) != State.ON) return 0
            val tok = token(ctx) ?: return 0.also { lost(ctx, Outcome.AUTH_LOST) }
            val acct = account() ?: return 0
            val base = SharpCoversLogic.apiBase(acct.server) ?: return 0
            val (pw, ph, _) = SleepScreen.panel(ctx)
            val ids = SleepScreen.pool().map { it.id }
            val d = NoMedia.directory(dir(ctx))
            var fetched = 0
            var same = 0
            var stop: String? = null
            for (id in ids) {
                BulkWork.checkpoint()
                val f = File(d, "$id.jpg")
                val tag = File(d, "$id.etag")
                val etag = if (f.isFile && tag.isFile) tag.readText().trim().ifEmpty { null } else null
                val r = try {
                    http.get(SharpCoversLogic.coverUrl(base, id, tok), etag?.let { mapOf("If-None-Match" to it) } ?: emptyMap())
                } catch (e: Exception) {
                    stop = "offline (${e.javaClass.simpleName})"
                    break
                }
                when (val o = SharpCoversLogic.outcome(r.code)) {
                    Outcome.OK -> {
                        val out = r.body?.let { scaler(it, pw, ph) }
                        if (out == null) continue
                        val tmp = File(d, "$id.jpg.orbit-new")
                        tmp.writeBytes(out)
                        if (tmp.renameTo(f)) {
                            if (r.etag != null) tag.writeText(r.etag) else tag.delete()
                            fetched++
                        } else {
                            tmp.delete()
                        }
                    }
                    Outcome.NOT_MODIFIED -> same++
                    Outcome.AUTH_LOST, Outcome.OPDS_OFF -> {
                        lost(ctx, o)
                        return fetched
                    }
                    Outcome.NO_COVER -> Unit
                    Outcome.LATER -> {
                        stop = "HTTP ${r.code}"
                        break
                    }
                }
            }
            val stored = d.listFiles { x -> x.name.endsWith(".jpg") }.orEmpty().mapNotNull { x ->
                x.name.removeSuffix(".jpg").toLongOrNull()?.let { SharpCoversLogic.Stored(it, x.length(), x.lastModified()) }
            }
            val gone = SharpCoversLogic.prune(stored, ids.toSet(), SharpCoversLogic.maxBytes(acct.storageLimitMb))
            gone.forEach { File(d, "$it.jpg").delete(); File(d, "$it.etag").delete() }
            OLog.i("sharp covers: $fetched fetched, $same unchanged, ${gone.size} removed of ${ids.size}${stop?.let { "; stopped: $it" } ?: ""} ($why)")
            if (fetched > 0 || gone.isNotEmpty()) SleepScreen.redrawPicture(ctx, "sharp covers")
            return fetched
        } finally {
            busy.set(false)
        }
    }

    /** Decodes once with a sample, fits the panel, re-encodes: the original is never kept. */
    private fun fitJpeg(bytes: ByteArray, panelW: Int, panelH: Int): ByteArray? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        val (w, h) = SharpCoversLogic.fit(o.outWidth, o.outHeight, panelW, panelH)
        if (w == 0) return null
        val src = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = SharpCoversLogic.sample(o.outWidth, o.outHeight, w, h) }) ?: return null
        val out = if (src.width == w && src.height == h) src else Bitmap.createScaledBitmap(src, w, h, true).also { if (it !== src) src.recycle() }
        return ByteArrayOutputStream().use { s ->
            out.compress(Bitmap.CompressFormat.JPEG, 92, s)
            out.recycle()
            s.toByteArray()
        }
    }

    // ---------------------------------------------------------------- Setup

    /**
     * Setup's row, under Needs you, only after a sign-in was lost (401/403) while Recommended is on:
     * "Until then: …" says what is lost. Never shown before the first sign-in: the fallback is a
     * state of the Sleep screen page's row, not a step.
     */
    fun check(ctx: Context): Check? {
        if (state(ctx) != State.LOST || SleepScreen.settings(ctx).mode != SleepMode.RECOMMENDED) return null
        return Check("Sharp sleep-screen covers", false, lostWhy(ctx) ?: "BookOrbit stopped accepting the sign-in",
            action = "Sign in again", id = SETUP_ID) { a ->
            OLog.i("setup: sharp covers: Sign in again")
            a.startActivity(Intent(a, SleepScreenActivity::class.java))
        }
    }

    // ---------------------------------------------------------------- defaults

    private object UrlHttp : Http {
        private const val MAX = 16 * 1024 * 1024

        override fun get(url: String, headers: Map<String, String>): Resp {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 15_000
                c.readTimeout = 30_000
                c.useCaches = false
                headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
                val code = c.responseCode
                val body = if (code == 200) c.inputStream.use { ins ->
                    val out = ByteArrayOutputStream()
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = ins.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        if (out.size() > MAX) error("response too large")
                    }
                    out.toByteArray()
                } else null
                return Resp(code, c.getHeaderField("ETag"), body)
            } finally {
                c.disconnect()
            }
        }
    }

    /** AES-GCM with a key that never leaves the Android Keystore. */
    private object KeystoreVault : Vault {
        private const val ALIAS = "orbit_sharp_covers"

        private fun key(): SecretKey {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            g.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            return g.generateKey()
        }

        override fun seal(plain: String): String {
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
            val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
            return Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)
        }

        override fun open(sealed: String): String? {
            val (iv, ct) = sealed.split(':').takeIf { it.size == 2 } ?: return null
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            return String(c.doFinal(Base64.decode(ct, Base64.NO_WRAP)), Charsets.UTF_8)
        }
    }
}
