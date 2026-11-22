package net.fledgewing.orbitcompanion

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout

/**
 * "Setup needs you" (SetupAttention): evaluated when the service starts, after an update and
 * when the status page or launcher page opens. Delivered as a prompt page (AttentionActivity),
 * a quiet notification, a one-line launcher banner, and setup_needed in /status for the patch.
 */
object Attention {
    // "setup" was IMPORTANCE_LOW: hidden from the status bar and easy to miss on e-ink. A
    // channel's importance can't be raised once created, so it is replaced.
    private const val OLD_CHANNEL = "setup"
    private const val CHANNEL = "setup_steps"
    private const val ID = 4

    private fun state(p: Prefs) = SetupAttention.State(p.setupIgnored, p.setupSnoozeCode, p.setupSnoozeNotDone, p.setupLastDone)
    private fun save(p: Prefs, st: SetupAttention.State) {
        p.setupIgnored = st.ignored
        p.setupSnoozeCode = st.snoozeCode
        p.setupSnoozeNotDone = st.snoozeNotDone
        p.setupLastDone = st.lastDone
    }

    /** After an update, remember where "What's new" starts. A fresh install shows none. */
    fun onStart(ctx: Context) {
        val p = Prefs(ctx)
        val now = BuildConfig.VERSION_CODE
        val last = p.lastSeenVersionCode
        if (last in 1 until now) {
            p.whatsNewFromCode = last
            OLog.i("setup: updated from code $last to $now; what's new pending")
        }
        if (last != now) p.lastSeenVersionCode = now
    }

    class Eval(val result: SetupAttention.Result, val checks: Map<String, Check>)

    fun evaluate(ctx: Context, why: String, notify: Boolean = true): Eval {
        val p = Prefs(ctx)
        val checks = Setup.checks(ctx).associateBy { SetupAttention.idOf(it.label) }
        val pending = checks.filterValues { it.pending }.keys
        val r = SetupAttention.evaluate(checks.map { (id, c) -> id to c.done }, state(p), BuildConfig.VERSION_CODE, pending)
        save(p, r.next)
        p.setupNeeded = r.needed.size
        p.setupPromptKey = SetupAttention.promptKey(r)
        p.setupPromptRows = if (r.show) r.needed.mapNotNull { checks[it]?.label }.joinToString("\n") else ""
        if (r.needed.isNotEmpty() || r.regressed.isNotEmpty()) {
            OLog.i("setup: $why: needs ${r.needed}${if (r.regressed.isNotEmpty()) " (regressed ${r.regressed})" else ""}, prompt ${r.show}")
        }
        if (notify) notification(ctx, r, whatsNew(ctx).isNotEmpty())
        return Eval(r, checks)
    }

    /** The rows that need the user now (for "before" in [afterChange]). */
    fun neededNow(ctx: Context): List<String> = evaluate(ctx, "before a change", notify = false).result.needed

    /**
     * "Prompt at the moment of cause": a change made in the companion (e.g. the first mapped
     * clicker button, a Send-key action) made new rows needed: open the prompt at once.
     */
    fun afterChange(a: Activity, before: List<String>, why: String): Boolean {
        val e = evaluate(a, why)
        val caused = SetupAttention.caused(before, e.result)
        if (caused.isEmpty()) return false
        OLog.i("setup: $why made $caused needed: prompting now")
        a.startActivity(Intent(a, AttentionActivity::class.java).putExtra(AttentionActivity.EXTRA_FIRST, caused.toTypedArray()))
        return true
    }

    /** Home press: the prompt once before KOReader when an unsnoozed row is new (SetupAttention.homePrompt). */
    fun promptOnHome(a: Activity): Boolean {
        val p = Prefs(a)
        val e = evaluate(a, "home press")
        if (!SetupAttention.homePrompt(e.result, p.setupHomePrompted)) return false
        p.setupHomePrompted = e.result.needed.toSet()
        OLog.i("setup: home press: prompting once for ${e.result.needed} before ${HomeTarget.name(a)}")
        a.startActivity(Intent(a, AttentionActivity::class.java))
        return true
    }

    /** KOReader's setup box "Later" (SETUP_LATER): the same snooze as the prompt's Later. */
    fun laterFromKoreader(ctx: Context) {
        val e = evaluate(ctx, "koreader later", notify = false)
        if (e.result.needed.isNotEmpty()) later(ctx, e) else OLog.i("setup: Later from KOReader; nothing needed")
    }

    fun whatsNew(ctx: Context): List<Pair<String, List<String>>> {
        val from = Prefs(ctx).whatsNewFromCode
        return if (from > 0) WhatsNew.since(from, BuildConfig.VERSION_CODE) else emptyList()
    }

    fun shouldPrompt(e: Eval, ctx: Context) = e.result.show || whatsNew(ctx).isNotEmpty()

    fun later(ctx: Context, e: Eval) {
        val p = Prefs(ctx)
        save(p, SetupAttention.snooze(state(p), e.result.needed, BuildConfig.VERSION_CODE))
        p.whatsNewFromCode = 0
        p.setupPromptKey = ""
        p.setupPromptRows = ""
        OLog.i("setup: Later (snoozed ${e.result.needed} until an update or a regression)")
        cancel(ctx)
    }

    fun ignore(ctx: Context, id: String) {
        val p = Prefs(ctx)
        save(p, SetupAttention.ignore(state(p), id))
        OLog.i("setup: don't ask about $id")
    }

    fun unignoreAll(ctx: Context) {
        val p = Prefs(ctx)
        save(p, SetupAttention.unignoreAll(state(p)))
        OLog.i("setup: asking about every row again")
    }

    fun seenWhatsNew(ctx: Context) {
        Prefs(ctx).whatsNewFromCode = 0
    }

    /** One line for the launcher page, or null. */
    fun bannerText(ctx: Context): String? {
        val n = Prefs(ctx).setupNeeded
        val news = whatsNew(ctx).isNotEmpty()
        return when {
            n > 0 -> "$n setup step${if (n == 1) "" else "s"} need${if (n == 1) "s" else ""} you ›"
            news -> "Updated to ${BuildConfig.VERSION_NAME}: what's new ›"
            else -> null
        }
    }

    private fun nm(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun cancel(ctx: Context) = nm(ctx).cancel(ID)

    private var lastNoteLog: String? = null

    private fun notification(ctx: Context, r: SetupAttention.Result, news: Boolean) {
        if (!r.show && !news) return cancel(ctx)
        val nm = nm(ctx)
        if (nm.getNotificationChannel(OLD_CHANNEL) != null) nm.deleteNotificationChannel(OLD_CHANNEL)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Setup steps", NotificationManager.IMPORTANCE_DEFAULT).apply {
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        })
        val n = r.needed.size
        val text = when {
            r.show && n > 0 -> "Orbit Companion: $n setup step${if (n == 1) "" else "s"} need${if (n == 1) "s" else ""} you"
            else -> "Orbit Companion ${BuildConfig.VERSION_NAME}: what's new"
        }
        val open = Intent(ctx, AttentionActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        nm.notify(ID, Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(PendingIntent.getActivity(ctx, 4, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .build())
        // Vendor ROMs may block or demote it: log what Android says, once per change.
        val importance = nm.getNotificationChannel(CHANNEL)?.importance
        val line = "setup: notification posted ($text); notifications ${if (nm.areNotificationsEnabled()) "allowed" else "BLOCKED"}, channel importance $importance"
        if (line != lastNoteLog) OLog.i(line)
        lastNoteLog = line
    }
}

/** The prompt: what's new after an update, then only the rows that need the user. */
class AttentionActivity : EinkActivity() {
    companion object {
        /** Rows a change just made needed: listed first. */
        const val EXTRA_FIRST = "first"
    }

    private var eval: Attention.Eval? = null
    /** Something was fixed from inside this page: when nothing is left, say "All set" before closing. */
    private var fixedHere = false

    override fun onResume() {
        super.onResume()
        render()
    }

    /** An in-app fix finished (e.g. the patch install): look again. */
    override fun refresh() {
        if (!isFinishing) render()
    }

    private fun render() {
        val e = Attention.evaluate(this, "prompt page")
        eval = e
        val news = Attention.whatsNew(this)
        val needed = e.result.needed
        val pending = e.result.pending
        if (news.isEmpty() && (needed.isEmpty() && (pending.isEmpty() || !fixedHere))) {
            if (fixedHere) {
                val root = page()
                root.addView(Ui.header(this, "All set"))
                root.addView(Ui.text(this, "Every setup step is done.", 20f))
                root.postDelayed({ finish() }, 1_500)
            } else {
                finish()
            }
            return
        }
        val root = page(scroll = true)
        val title = if (needed.isNotEmpty() || pending.isNotEmpty()) "Setup needs you" else "What's new"
        root.addView(Ui.header(this, title, "Close") { closeOut() })
        news.forEach { (v, lines) ->
            root.addView(Ui.text(this, "New in $v", 20f, bold = true).apply { setPadding(0, Ui.dp(this@AttentionActivity, 8), 0, Ui.dp(this@AttentionActivity, 4)) })
            lines.forEach { root.addView(Ui.text(this, "• $it", 18f)) }
        }
        if (needed.isNotEmpty() || pending.isNotEmpty()) {
            root.addView(Ui.gap(this, 12))
            val first = intent.getStringArrayExtra(EXTRA_FIRST).orEmpty().toList()
            (first.filter { it in needed } + needed.filter { it !in first } + pending).forEach { id ->
                val c = e.checks[id] ?: return@forEach
                val card = Ui.card(this)
                val label = c.label + if (id in e.result.regressed) " (changed since last time)" else ""
                card.addView(Ui.text(this, label, 19f, bold = true))
                card.addView(Ui.text(this, c.detail, 16f, color = Ui.MID))
                card.addView(Ui.gap(this, 6))
                val buttons = mutableListOf<android.view.View>()
                c.action?.let { label ->
                    // "Installing…" while the patch install runs: no second install.
                    val busy = PatchInstaller.busy && id == "patch"
                    buttons += Ui.button(this, label, solid = !busy, heightDp = 56, sp = 19f) {
                        if (busy) return@button
                        fixedHere = true
                        c.open(this)
                        render()
                    }
                }
                if (id in needed) {
                    buttons += Ui.button(this, "Don't ask about this", heightDp = 56, sp = 16f) {
                        Attention.ignore(this, id)
                        render()
                    }
                }
                if (buttons.isNotEmpty()) card.addView(Ui.weightRow(this, *buttons.toTypedArray()))
                root.addView(card)
                root.addView(Ui.gap(this, 8))
            }
            if (needed.isNotEmpty()) {
                root.addView(Ui.button(this, "Later") {
                    Attention.later(this, e)
                    finish()
                })
                root.addView(Ui.text(this, "Later: not again until the next update or until a step stops working. Skipped steps can be asked again in Settings.", 15f, color = Ui.MID))
            } else {
                root.addView(Ui.button(this, "OK") { closeOut() })
            }
        } else {
            root.addView(Ui.gap(this, 12))
            root.addView(Ui.button(this, "OK") { closeOut() })
        }
    }

    private fun closeOut() {
        Attention.seenWhatsNew(this)
        eval?.let { if (it.result.needed.isNotEmpty()) Attention.later(this, it) }
        finish()
    }
}
