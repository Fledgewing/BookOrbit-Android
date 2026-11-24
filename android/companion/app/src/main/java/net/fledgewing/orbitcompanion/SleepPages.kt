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
 * Settings › Sleep screen (docs/design/lock-screen.md S1, S2): the same settings as KOReader's
 * Orbit menu, shared with it (newest wins). Pick from, Leave out and the text are set in KOReader,
 * where the lists and the keyboard are; this page shows them. Behind the Settings PIN (K1).
 */
class SleepScreenActivity : EinkActivity() {
    override val pinGuarded = true

    override fun onResume() {
        super.onResume()
        render()
    }

    override fun refresh() = render()

    private fun set(s: SleepSettings) {
        SleepScreen.save(this, s, "companion page", shared = true)
        render()
    }

    private fun render() {
        val s = SleepScreen.settings(this)
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Sleep screen", "‹ Back") { finish() })
        segmented(root, "Sleep screen", SleepMode.entries.map { it to it.label }, s.mode) { set(s.copy(mode = it)) }
        if (s.mode == SleepMode.OFF) {
            root.addView(note("The reader shows its own sleep screen. Turn this on for a recommended BookOrbit cover or the current book."))
            return
        }
        // Onboarding's optional step, right after the sleep screen is chosen (until marked done).
        ScreenModeSetup.row(s.mode, ScreenModeSetup.way(this))?.takeIf { !it.done }?.let { r ->
            root.addView(Ui.row(this, "${r.label} (optional)", "${r.stateLine}\nWithout it: ${Checklist.LOSS.getValue(ScreenModeSetup.ID)}",
                Ui.value(this, "How ›"), onClick = { ScreenModeSetup.how(this) }))
        }
        if (s.mode == SleepMode.RECOMMENDED) {
            root.addView(Ui.row(this, "Pick from", "${s.fromLabel()} · set in KOReader › Tools › Android sync › Sleep screen"))
            root.addView(Ui.row(this, "Leave out", if (s.leaveOut.isEmpty()) "nothing" else "${s.leaveOut.size} rule(s) · set in KOReader"))
            segmented(root, "Change cover every", SleepSettings.HOURS.map { it to "$it h" }, s.hours) { set(s.copy(hours = it)) }
            sharpRow(root)
        }
        root.addView(Ui.row(this, "Text", if (s.text.isEmpty()) "none · set in KOReader" else "${s.text} · set in KOReader"))
        root.addView(Ui.row(this, "Show battery level", "the level when the reader went to sleep", Ui.toggle(this, s.battery), onClick = {
            set(s.copy(battery = !s.battery))
        }))
        root.addView(Ui.row(this, SleepFlash.LABEL, SleepFlash.ABOUT, Ui.toggle(this, s.flash), onClick = {
            set(s.copy(flash = !s.flash))
        }))
        segmented(root, "Style", SleepStyle.entries.map { it to it.label }, s.style) { set(s.copy(style = it)) }
        if (s.style == SleepStyle.OVERLAY) {
            segmented(root, "Text position", TextPosition.entries.map { it to it.label }, s.textPosition) { set(s.copy(textPosition = it)) }
            segmented(root, "Battery corner", Corner.entries.map { it to it.label }, s.batteryCorner) { set(s.copy(batteryCorner = it)) }
            val moved = SleepLayout.batteryCorner(s.batteryCorner, s.textPosition, s.text.isNotEmpty())
            if (moved != s.batteryCorner) root.addView(note("The battery moves to ${moved.label.lowercase()} beside the text."))
        }
        root.addView(Ui.gap(this, 8))
        root.addView(Ui.row(this, "Shown by", SleepScreen.shownBy(this), Ui.value(this, "›"), onClick = { setUp() }))
        root.addView(Ui.row(this, "Preview", "5 s, or until you tap", Ui.value(this, "›"), onClick = {
            startActivity(Intent(this, SleepPreviewActivity::class.java))
        }))
    }

    /** L7: Sharp covers. Signed in once, or the thumbnail fallback (a state, not a mode). */
    private fun sharpRow(root: LinearLayout) {
        val acct = SharpCovers.account()
        val state = SharpCovers.state(this)
        val ids = SleepScreen.pool().map { it.id }
        val (sub, value) = SharpCoversLogic.row(state, acct != null, SharpCovers.sharpCount(this, ids), ids.size, SharpCovers.lostWhy(this))
        root.addView(Ui.row(this, SharpCoversLogic.TITLE, sub, if (value.isEmpty()) null else Ui.value(this, value), onClick = when {
            acct == null -> null
            state == SharpCoversLogic.State.ON -> { -> signOutAsk() }
            else -> { -> signIn(acct) }
        }))
    }

    private fun signOutAsk() {
        android.app.AlertDialog.Builder(this)
            .setMessage("Sleep-screen covers come from BookOrbit's full-size cover. Sign out to use the small thumbnail again.")
            .setPositiveButton("Sign out") { _, _ -> SharpCovers.signOut(this, "companion page"); render() }
            .setNegativeButton("Keep", null).show()
    }

    /** The OPDS login, once: the password goes to one request and is cleared; only the cover link is kept. */
    private fun signIn(acct: SharpCovers.Account) {
        val pad = Ui.dp(this, 16)
        val user = android.widget.EditText(this).apply {
            hint = "OPDS username"
            setText(SharpCovers.user(this@SleepScreenActivity) ?: acct.user)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        }
        val pass = android.widget.EditText(this).apply {
            hint = "OPDS password"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
            addView(Ui.text(this@SleepScreenActivity, SharpCoversLogic.PROMPT, 16f, color = Ui.MID))
            addView(user)
            addView(pass)
        }
        android.app.AlertDialog.Builder(this).setTitle(SharpCoversLogic.TITLE).setView(box)
            .setPositiveButton("Sign in") { _, _ ->
                val name = user.text.toString().trim()
                val e = pass.text
                val pw = CharArray(e.length).also { e.getChars(0, e.length, it, 0) }
                e.clear()
                kotlin.concurrent.thread(name = "orbit-sharp-sign-in") {
                    val msg = SharpCovers.signIn(this, acct.server, name, pw)
                    if (msg == null) SharpCovers.sync(this, "signed in")
                    runOnUiThread {
                        if (isFinishing) return@runOnUiThread
                        render()
                        Ui.note(this, msg ?: "Signed in. Sharp covers download now while the reader is online.")
                    }
                }
            }
            .setNegativeButton("Cancel") { _, _ -> pass.text.clear() }
            .show()
    }

    /** P1-P3: choose Orbit's screen saver, or say how. */
    private fun setUp() {
        when (SleepScreen.sink(this)) {
            SleepSink.DREAM -> when {
                SleepScreen.oursChosen(this) -> Ui.note(this, "Orbit's screen saver shows the sleep screen.")
                SleepScreen.chooseOurs(this, "Set up") -> render()
                // The system Screen saver page, where the reader has one; else the USB command.
                !tryStart(Intent(Settings.ACTION_DREAM_SETTINGS), "screen saver settings") -> Ui.note(this,
                    "This reader hides its Screen saver settings. Connect it to a computer and run:\n\ntools/install-usb.sh --sleep-screen on\n\n" +
                        "or, once, tools/install-usb.sh --grant-screen-saver so Orbit can switch it itself.")
            }
            SleepSink.PICTURE -> Ui.note(this,
                "On the reader: Apps › Screensaver › Screensaver style, pick the picture Pictures/Orbit/sleep.png. Orbit keeps it up to date.")
        }
    }

    private fun note(text: String) = Ui.text(this, text, 16f, color = Ui.MID).apply {
        setPadding(0, Ui.dp(this@SleepScreenActivity, 6), 0, Ui.dp(this@SleepScreenActivity, 8))
    }

    private fun <T> segmented(root: LinearLayout, title: String, options: List<Pair<T, String>>, current: T, pick: (T) -> Unit) {
        root.addView(Ui.text(this, title, 21f).apply { setPadding(0, Ui.dp(this@SleepScreenActivity, 8), 0, Ui.dp(this@SleepScreenActivity, 8)) })
        // Two rows of two when there are four (the corners and positions), else one row.
        val rows = if (options.size == 4) options.chunked(2) else listOf(options)
        rows.forEach { row ->
            val seg = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                background = Ui.box(this@SleepScreenActivity, Ui.PAPER)
                val pad = Ui.dp(this@SleepScreenActivity, 2)
                setPadding(pad, pad, pad, pad)
            }
            row.forEach { (value, label) ->
                val sel = value == current
                val t = Ui.text(this, label, 17f, bold = sel, color = if (sel) Ui.PAPER else Ui.INK).apply {
                    gravity = Gravity.CENTER
                    minHeight = Ui.dp(this@SleepScreenActivity, 64)
                    setBackgroundColor(if (sel) Ui.INK else Ui.PAPER)
                }
                Ui.clickable(t, { if (!sel) pick(value) })
                seg.addView(t, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
            root.addView(seg)
        }
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
