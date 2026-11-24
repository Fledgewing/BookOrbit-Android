package net.fledgewing.orbitcompanion

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout

/**
 * Settings › Sleep screen (docs/design/lock-screen.md S1, S2; companion-settings §6): the section
 * page for the shared sleep-screen keys, also opened by KOReader's menu (SHOW_SLEEP). Read-only
 * behind the Settings PIN (K1).
 */
class SleepScreenActivity : SettingsSectionActivity() {
    override val fixedSection: String = "sleep"
}

/**
 * L7: Sharp covers, the Sleep screen section's row (docs/design/sharp-sleep-covers, through
 * SettingsSlots): signed in once, or the thumbnail fallback (a state, not a mode). Shown for
 * Recommended cover, after Change cover every.
 */
/**
 * Onboarding's optional screen-mode step (ScreenModeSetup), right after the sleep screen is
 * chosen, until marked done: the Sleep screen section's slot after its first row.
 */
object ScreenModeRow : SettingsSlots.Slot {
    override fun draw(a: SettingsPage, root: LinearLayout, locked: Boolean) {
        val mode = SleepScreen.settings(a).mode
        ScreenModeSetup.row(mode, ScreenModeSetup.way(a))?.takeIf { !it.done }?.let { r ->
            root.addView(Ui.row(a, "${r.label} (optional)", "${r.stateLine}\nWithout it: ${Checklist.LOSS.getValue(ScreenModeSetup.ID)}",
                Ui.value(a, "How ›"), onClick = if (locked) null else ({ ScreenModeSetup.how(a) })).apply { tag = "slot:screen_mode" })
        }
    }
}

object SharpCoversRow : SettingsSlots.Slot {
    override fun draw(a: SettingsPage, root: LinearLayout, locked: Boolean) {
        if (SettingsStore.get(a, "sleep_mode") != "recommended") return
        val acct = SharpCovers.account()
        val state = SharpCovers.state(a)
        val ids = SleepScreen.pool().map { it.id }
        val (sub, value) = SharpCoversLogic.row(state, acct != null, SharpCovers.sharpCount(a, ids), ids.size, SharpCovers.lostWhy(a))
        root.addView(Ui.row(a, SharpCoversLogic.TITLE, sub, if (value.isEmpty()) null else Ui.value(a, value), onClick = when {
            acct == null || locked -> null
            state == SharpCoversLogic.State.ON -> { -> signOutAsk(a) }
            else -> { -> signIn(a, acct) }
        }).apply { tag = "slot:sharp_covers" })
    }

    private fun signOutAsk(a: SettingsPage) {
        android.app.AlertDialog.Builder(a)
            .setMessage("Sleep-screen covers come from BookOrbit's full-size cover. Sign out to use the small thumbnail again.")
            .setPositiveButton("Sign out") { _, _ -> SharpCovers.signOut(a, "companion page"); a.render() }
            .setNegativeButton("Keep", null).show()
    }

    /** The OPDS login, once: the password goes to one request and is cleared; only the cover link is kept. */
    private fun signIn(a: SettingsPage, acct: SharpCovers.Account) {
        val pad = Ui.dp(a, 16)
        val user = android.widget.EditText(a).apply {
            hint = "OPDS username"
            setText(SharpCovers.user(a) ?: acct.user)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        }
        val pass = android.widget.EditText(a).apply {
            hint = "OPDS password"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
            addView(Ui.text(a, SharpCoversLogic.PROMPT, 16f, color = Ui.MID))
            addView(user)
            addView(pass)
        }
        android.app.AlertDialog.Builder(a).setTitle(SharpCoversLogic.TITLE).setView(box)
            .setPositiveButton("Sign in") { _, _ ->
                val name = user.text.toString().trim()
                val e = pass.text
                val pw = CharArray(e.length).also { e.getChars(0, e.length, it, 0) }
                e.clear()
                kotlin.concurrent.thread(name = "orbit-sharp-sign-in") {
                    val msg = SharpCovers.signIn(a, acct.server, name, pw)
                    if (msg == null) SharpCovers.sync(a, "signed in")
                    a.runOnUiThread {
                        if (a.isFinishing) return@runOnUiThread
                        a.render()
                        Ui.note(a, msg ?: "Signed in. Sharp covers download now while the reader is online.")
                    }
                }
            }
            .setNegativeButton("Cancel") { _, _ -> pass.text.clear() }
            .show()
    }
}

/**
 * The preview (S2): the sleep screen as it would show now, for 5 s or until a tap. Opened from
 * KOReader's menu (SLEEP_PREVIEW) or the page above: a user action, so the reading gate allows it.
 * It never moves the rotation on.
 */
class SleepPreviewActivity : EinkActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val (w, h, dpi) = SleepScreen.panel(this)
        val bmp = SleepScreen.render(this, w, h, dpi, advance = false, why = "preview")
        val view = ImageView(this).apply {
            setBackgroundColor(android.graphics.Color.WHITE)
            scaleType = ImageView.ScaleType.FIT_CENTER
            setImageBitmap(bmp)
            setOnClickListener { finish() }
        }
        setContentView(view)
        main.postDelayed({ if (!isFinishing) finish() }, 5_000)
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}

/**
 * Setup's one optional row for the sleep screen (docs/design/lock-screen.md P3), in the Add-on
 * design's style: shown only while Sleep screen is on and the reader uses the screen saver.
 */
object SleepSetup {
    /** The checklist's id for it (Checklist.GROUP_OF, its "On:" / "Without it:" lines). */
    const val ID = "screen_saver"
    const val TITLE = "Switch the screen saver from Orbit"
    const val COMMAND = "Connect the reader to a computer and run, once:\n\ntools/install-usb.sh --grant-screen-saver\n\n" +
        "Without it: tools/install-usb.sh --sleep-screen on (or off) does the switch itself."

    fun shown(mode: SleepMode, sink: SleepSink): Boolean = mode != SleepMode.OFF && sink == SleepSink.DREAM

    fun check(ctx: android.content.Context): Check? {
        if (!shown(SleepScreen.settings(ctx).mode, SleepScreen.sink(ctx))) return null
        val granted = SleepScreen.canSwitch(ctx)
        val line = if (granted) Checklist.optionalLine(ID, true).orEmpty() else ""
        return Check(TITLE, granted, line, action = if (granted) null else "Show how", optional = true, id = ID) { a ->
            OLog.i("setup: sleep screen optional row: Show how")
            Ui.note(a, COMMAND)
        }
    }
}

/**
 * Setup's "Screen mode for Orbit" (docs/design/companion-checklist.md §3.3, lock-screen.md L10):
 * e-ink readers keep a per-app display mode, and a fast one leaves the last page ghosting through
 * the sleep screen. No Android API reads or sets it, so it is purely Optional (never counted,
 * walked or prompted) and finishes one of two ways: the user sets the mode and says so
 * ("I've set it"), or turns on the clearing flash instead (SleepFlash). Generic: no vendor names.
 * Shown while Sleep screen is on.
 */
object ScreenModeSetup {
    const val ID = "screen_mode"
    const val TITLE = "Screen mode for Orbit"
    const val HINT = "Set Orbit Companion to the reader's clearest screen mode (often called HD, Clear or Quality) " +
        "in its per-app display settings, so the sleep screen draws without ghosting."
    const val HOW = "Most e-ink readers let you pick a screen mode per app: a fast one for scrolling, a clear one for pictures.\n\n" +
        "Open the reader's per-app display or refresh settings (often from a floating button, the top menu, or Settings › Display), " +
        "choose Orbit Companion, and set it to the clearest mode (often called HD, Clear or Quality). Orbit can't see this " +
        "setting, so tap I've set it once it's done.\n\n" + SleepFlash.ABOUT
    const val SET = "I've set it"
    const val USE_FLASH = "Use a clearing flash instead"
    const val FLASH_ON = "On: the clearing flash runs before the cover."

    /** How the step was finished, if it was. */
    enum class Way { NONE, SET, FLASH }

    fun way(setDone: Boolean, flash: Boolean): Way = when {
        setDone -> Way.SET
        flash -> Way.FLASH
        else -> Way.NONE
    }

    /** Shown while the sleep screen is Orbit's (any mode but the reader's own). */
    fun shown(mode: SleepMode): Boolean = mode != SleepMode.OFF

    /** The row, or null when hidden. Always optional: left alone it only says "Without it: …". */
    fun row(mode: SleepMode, way: Way): Checklist.Row? = if (!shown(mode)) null else Checklist.Row(
        id = ID, label = TITLE, done = way != Way.NONE,
        stateLine = when (way) {
            Way.SET -> Checklist.optionalLine(ID, true).orEmpty()
            Way.FLASH -> FLASH_ON
            Way.NONE -> HINT
        },
        optional = true, verb = if (way == Way.NONE) "How" else null,
    )

    fun way(ctx: android.content.Context): Way = way(Prefs(ctx).screenModeDone, SleepScreen.settings(ctx).flash)

    fun check(ctx: android.content.Context): Check? {
        val r = row(SleepScreen.settings(ctx).mode, way(ctx)) ?: return null
        return Check(r.label, r.done, r.stateLine, action = r.verb, optional = true, id = ID) { a -> how(a) }
    }

    /** "I've set it": stored, since nothing can read the reader's mode. */
    fun markSet(ctx: android.content.Context) {
        Prefs(ctx).screenModeDone = true
        OLog.i("setup: screen mode: set by the user")
    }

    /** "Use a clearing flash instead": turns the flash on, which finishes the step too. */
    fun useFlash(ctx: android.content.Context) {
        val s = SleepScreen.settings(ctx)
        if (!s.flash) SleepScreen.save(ctx, s.copy(flash = true), "screen mode step", shared = true)
        OLog.i("setup: screen mode: clearing flash instead")
    }

    /** "How": the steps, then one of the two ways, or Skip. */
    fun how(a: EinkActivity) {
        OLog.i("setup: screen mode: How")
        android.app.AlertDialog.Builder(a).setTitle(TITLE).setMessage(HOW)
            .setPositiveButton(SET) { _, _ -> markSet(a); a.refresh() }
            .setNeutralButton(USE_FLASH) { _, _ -> useFlash(a); a.refresh() }
            .setNegativeButton("Skip", null).show()
    }
}
