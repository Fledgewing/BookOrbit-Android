package net.fledgewing.orbitcompanion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager

/**
 * "Orbit clicker keys": a keyboard with no keys on screen. It only sends the key a clicker
 * button is mapped to (Send Volume up/down, Send key…) into the app in front, through its
 * InputConnection. It never shows an input view and never reads, logs or stores text: the only
 * thing it looks at is whether the focused editor takes text (EditorInfo.inputType's class).
 * android/docs/BTKEYS-DESIGN.md "Send key".
 */
class OrbitKeysIme : InputMethodService() {
    companion object {
        @Volatile
        var instance: OrbitKeysIme? = null
            private set
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        instance = this
        OLog.i("keys: Orbit keyboard started")
        KeySender.keyboardNotification(this, true)
    }

    override fun onDestroy() {
        instance = null
        main.removeCallbacksAndMessages(null)
        KeySender.keyboardNotification(this, false)
        OLog.i("keys: Orbit keyboard stopped")
        super.onDestroy()
    }

    /** No keys on screen, ever. */
    override fun onEvaluateInputViewShown(): Boolean {
        super.onEvaluateInputViewShown() // its required bookkeeping; the answer is always no
        return false
    }
    override fun onEvaluateFullscreenMode(): Boolean = false
    override fun onShowInputRequested(flags: Int, configChange: Boolean): Boolean = false

    override fun onBindInput() {
        super.onBindInput()
        // No editor focused: onStartInput may not come; the bound connection still reaches the
        // focused window, so count a bind as ready shortly after.
        main.postDelayed({ if (currentInputConnection != null) KeySender.bound(this, textEditor = false, via = "bind") }, 60)
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        val text = Keyboard.takesText(attribute?.inputType ?: InputType.TYPE_NULL)
        KeySender.bound(this, textEditor = text, via = "start")
        if (text && Prefs(this).keepOrbitKeyboard) KeySender.keyboardNotification(this, true, typing = true)
    }

    /** Down and up for each key, in order. */
    fun send(keys: List<Int>): Boolean {
        if (currentInputConnection == null) return false
        keys.forEach { sendDownUpKeyEvents(it) }
        return true
    }

    /** Back to the keyboard used before (the notification's "Switch keyboard"). */
    fun toPrevious(): Boolean {
        val ok = Build.VERSION.SDK_INT >= 28 && switchToPreviousInputMethod()
        if (!ok) (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
        return ok
    }
}

/** Pure bits for the keyboard (tested). */
object Keyboard {
    /** The focused editor takes text (a text field), not TYPE_NULL (no editor, e.g. a page view). */
    fun takesText(inputType: Int): Boolean = inputType and InputType.TYPE_MASK_CLASS != InputType.TYPE_NULL

    /** An accessibility focus event's class name means a text field (never its text). */
    fun isTextField(className: CharSequence?, isPassword: Boolean): Boolean {
        if (isPassword) return true
        val c = className?.toString() ?: return false
        return c.endsWith("EditText") || c.endsWith("AutoCompleteTextView") || c.endsWith("SearchAutoComplete")
    }
}

/**
 * Drives [ImeSwitch] on the main thread: the accessibility service switches keyboards
 * (AccessibilityService.SoftKeyboardController.switchToInputMethod, API 30:
 * https://developer.android.com/reference/android/accessibilityservice/AccessibilityService.SoftKeyboardController#switchToInputMethod(java.lang.String)),
 * the Orbit keyboard sends, and the previous keyboard comes back the same way.
 */
object KeySender {
    private const val CHANNEL = "keyboard"
    private const val NOTE_ID = 5
    const val ACTION_SWITCH = "${Contract.PACKAGE}.action.SWITCH_KEYBOARD"
    private const val RESTORE_DELAY_MS = 40L

    private val main = Handler(Looper.getMainLooper())
    private val sw = ImeSwitch()
    private val token = Any()

    private val cls = OrbitKeysIme::class.java.name

    fun orbitId(ctx: Context): String = ComponentName(ctx, OrbitKeysIme::class.java).flattenToShortString()

    fun enabled(ctx: Context): Boolean =
        ImeIds.enabledIn(Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_INPUT_METHODS), ctx.packageName, cls)

    private fun current(ctx: Context): String? = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)

    fun isCurrent(ctx: Context): Boolean = ImeIds.isCurrent(current(ctx), ctx.packageName, cls)

    /** Just-in-time switching needs Android 11 (API 30); before that only "keep active" works. */
    val canSwitch: Boolean get() = Build.VERSION.SDK_INT >= 30

    fun press(ctx: Context, keycode: Int, editorFocused: Boolean) {
        val p = Prefs(ctx)
        val cur = current(ctx)
        val orbitCurrent = OrbitKeysIme.instance != null && ImeIds.isCurrent(cur, ctx.packageName, cls)
        if (!orbitCurrent && !enabled(ctx)) {
            OLog.w("keys: key $keycode not sent: the Orbit keyboard is off (Setup › Orbit keyboard)")
            return
        }
        if (!orbitCurrent && !canSwitch) {
            OLog.w("keys: key $keycode not sent: this Android can't switch keyboards for a key press; turn on Keep Orbit keyboard active")
            return
        }
        apply(ctx, sw.press(SystemClock.uptimeMillis(), keycode, cur, orbitCurrent, p.keepOrbitKeyboard, editorFocused))
    }

    fun bound(ctx: Context, textEditor: Boolean, via: String) {
        if (sw.phase != ImeSwitch.Phase.SWITCHING) return
        OLog.d("keys: Orbit keyboard bound ($via)")
        apply(ctx, sw.bound(SystemClock.uptimeMillis(), textEditor))
    }

    private fun apply(ctx: Context, o: ImeSwitch.Out) {
        o.log?.let { OLog.i("keys: $it") }
        if (o.send.isNotEmpty()) {
            val ok = OrbitKeysIme.instance?.send(o.send) ?: false
            if (!ok) OLog.w("keys: Orbit keyboard not bound; ${o.send.size} key(s) not sent")
        }
        if (o.failed) {
            val p = Prefs(ctx)
            p.imeSwitchFailures = p.imeSwitchFailures + 1
            OLog.w("keys: switching keyboards failed on this reader (${p.imeSwitchFailures}x); Settings › Clicker buttons › Keep Orbit keyboard active is the fallback")
        }
        if (o.switchToOrbit) switchTo(ctx, orbitId(ctx), "to Orbit")
        o.restore?.let { prev -> main.postDelayed({ restore(ctx, prev) }, RESTORE_DELAY_MS) }
        schedule(ctx)
    }

    private fun restore(ctx: Context, prev: String) {
        val t0 = SystemClock.uptimeMillis()
        val ok = when {
            ImeIds.isCurrent(prev, ctx.packageName, cls) -> true // kept active: nothing to restore
            switchTo(ctx, prev, "back") -> true
            else -> OrbitKeysIme.instance?.toPrevious() ?: false
        }
        OLog.d("keys: restore call ${if (ok) "ok" else "FAILED"} in ${SystemClock.uptimeMillis() - t0} ms")
        apply(ctx, sw.restored(SystemClock.uptimeMillis(), current(ctx)))
    }

    private fun switchTo(ctx: Context, id: String, what: String): Boolean {
        val svc = ClickerService.instance
        if (Build.VERSION.SDK_INT < 30 || svc == null) {
            OLog.w("keys: can't switch $what (${if (svc == null) "accessibility service off" else "Android < 11"})")
            return false
        }
        val t0 = SystemClock.uptimeMillis()
        val ok = svc.softKeyboardController.switchToInputMethod(id)
        OLog.d("keys: switch $what ${if (ok) "requested" else "REFUSED"} in ${SystemClock.uptimeMillis() - t0} ms")
        return ok
    }

    private fun schedule(ctx: Context) {
        main.removeCallbacksAndMessages(token)
        val due = sw.nextDue() ?: return
        main.postAtTime({ apply(ctx, sw.tick(SystemClock.uptimeMillis())) }, token, due)
    }

    /**
     * "Keep Orbit keyboard active": while it is the current keyboard, a notification offers the
     * way back to the normal keyboard for typing ([typing]: a text field was just focused).
     */
    fun keyboardNotification(ctx: Context, show: Boolean, typing: Boolean = false) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!show || !Prefs(ctx).keepOrbitKeyboard) {
            Reading.drop(Reading.KEY_KEYBOARD)
            nm.cancel(NOTE_ID)
            return
        }
        // [typing]: the user just focused a text field, so it shows now. Otherwise never while
        // reading (Reading), and only while the Orbit keyboard is still the current one.
        if (typing) return postKeyboard(ctx, nm, true)
        val app = ctx.applicationContext
        Reading.show(app, Reading.KEY_KEYBOARD, "keyboard notification") {
            if (OrbitKeysIme.instance != null && Prefs(app).keepOrbitKeyboard) postKeyboard(app, nm, false)
        }
    }

    private fun postKeyboard(ctx: Context, nm: NotificationManager, typing: Boolean) {
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Orbit keyboard", NotificationManager.IMPORTANCE_DEFAULT).apply {
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        })
        val sw = PendingIntent.getBroadcast(ctx, 5, Intent(ctx, KeyboardReceiver::class.java).setAction(ACTION_SWITCH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val text = if (typing) "To type, switch to your keyboard" else "Orbit keyboard is active (it has no keys). To type, switch keyboards."
        nm.notify(NOTE_ID, Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setContentIntent(sw)
            .addAction(Notification.Action.Builder(null, "Switch keyboard", sw).build())
            .build())
        OLog.i("keys: keyboard notification posted (enabled ${nm.areNotificationsEnabled()})")
    }
}

/** The notification's "Switch keyboard". */
class KeyboardReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != KeySender.ACTION_SWITCH) return
        val ime = OrbitKeysIme.instance
        OLog.i("keys: switch keyboard from the notification${if (ime == null) " (Orbit keyboard not running)" else ""}")
        if (ime != null) ime.toPrevious()
        else ctx.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
