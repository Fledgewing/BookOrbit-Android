package net.fledgewing.orbitcompanion

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/** The key map, kept by the companion (prefs JSON), cached for the service's key path. */
object ClickerStore {
    @Volatile
    private var cached: KeyMap? = null

    fun map(ctx: Context): KeyMap = cached ?: KeyMap.fromJson(Prefs(ctx).clickerMap).also { cached = it }

    fun save(ctx: Context, m: KeyMap) {
        Prefs(ctx).clickerMap = m.toJson().toString()
        cached = m
    }

    /** A Bluetooth/USB clicker, not the reader's own buttons or a virtual keyboard. */
    fun isClicker(d: InputDevice?): Boolean {
        if (d == null || d.isVirtual) return false
        return if (Build.VERSION.SDK_INT >= 29) d.isExternal else true
    }

    /** The reader's own (built-in) buttons can send this keycode too. */
    fun builtinHasKey(keycode: Int): Boolean = devices().any { d ->
        !d.isVirtual && !isClicker(d) && d.sources and InputDevice.SOURCE_KEYBOARD == InputDevice.SOURCE_KEYBOARD &&
            d.hasKeys(keycode).firstOrNull() == true
    }

    /** Connected external devices that point/tap but have no keys (ring remotes): can't be mapped. */
    private fun devices(): List<InputDevice> = InputDevice.getDeviceIds().toList().mapNotNull { id -> InputDevice.getDevice(id) }

    fun pointerOnlyClickers(): List<String> = devices().filter { d ->
        isClicker(d) && d.keyboardType == InputDevice.KEYBOARD_TYPE_NONE &&
            (d.supportsSource(InputDevice.SOURCE_TOUCHSCREEN) || d.supportsSource(InputDevice.SOURCE_MOUSE))
    }.map { it.name }.distinct()

    fun connectedNames(): Set<String> = devices().filter { isClicker(it) }.map { it.name }.toSet()

    fun accessibilitySetting(ctx: Context): String? =
        Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)

    fun enabled(ctx: Context): Boolean = ClickerRow.enabledIn(accessibilitySetting(ctx), ctx.packageName, ClickerService::class.java.name)

    fun state(ctx: Context): ClickerRowState = ClickerRow.state(map(ctx).mapped, enabled(ctx), ClickerService.connected)
}

/**
 * Clicker buttons in apps other than KOReader (docs/BTKEYS-DESIGN.md). Key filtering only; it
 * can't read window content (res/xml/clicker_service.xml). It acts only on mapped buttons from
 * captured clickers: every other key, the reader's own buttons and touch pass untouched. With
 * KOReader in front it passes everything (the patch maps keys itself). Nothing is stored or sent.
 */
class ClickerService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: ClickerService? = null
            private set

        val connected: Boolean get() = instance != null

        private val IGNORED_WINDOWS = setOf("com.android.systemui")
    }

    private val main = Handler(Looper.getMainLooper())
    private var foreground: String? = null
    /** A text field has focus in the app in front (from focus events' class name only). */
    private var editorFocused = false
    private val timers = HashMap<String, PressTimer>()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        OLog.i("clicker: accessibility service connected")
        ClickChannel.service(true)
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        OLog.i("clicker: accessibility service unbound")
        ClickChannel.service(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (instance != null) ClickChannel.service(false)
        instance = null
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_FOCUSED) {
            // Send-key actions skip while typing. Only the class name is used, never any text.
            val text = Keyboard.isTextField(event.className, event.isPassword)
            if (text != editorFocused) OLog.d("clicker: text field ${if (text) "focused" else "left"}")
            editorFocused = text
            return
        }
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg in IGNORED_WINDOWS) return
        if (pkg != foreground) OLog.d("clicker: in front: $pkg")
        foreground = pkg
        editorFocused = false
    }

    override fun onInterrupt() = Unit

    /** External devices whose keys passed untouched (not a captured clicker): logged once each. */
    private val unknownSeen = HashSet<String>()

    override fun onKeyEvent(event: KeyEvent): Boolean {
        val dev = event.device
        // Never the reader's own buttons or a virtual keyboard; keycodes are logged only for
        // captured clickers (never for a keyboard someone types on).
        if (!ClickerStore.isClicker(dev)) return false
        val fg = foreground
        val down = event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
        val acts = ClickerStore.map(this).lookup(dev.name, dev.vendorId, dev.productId, event.keyCode, fg)
        if (acts == null) {
            if (ClickerStore.map(this).clicker(Clicker.profileId(dev.name, dev.vendorId, dev.productId)) == null && unknownSeen.add(dev.name)) {
                OLog.i("clicker: keys from ${dev.name} (sources 0x${Integer.toHexString(dev.sources)}, not a captured clicker) pass through")
            } else if (down) {
                OLog.i("clicker: key ${event.keyCode} from ${dev.name} in ${fg ?: "?"} -> pass (not mapped here)")
            }
            return false
        }
        // One path (ClickRoute): KOReader gets the action from us when the patch listens.
        val route = ClickRoute.route(fg, packageName, ClickChannel.listening)
        if (down) OLog.i("clicker: key ${event.keyCode} from ${dev.name} in ${fg ?: "?"} -> ${when (route) {
            ClickRoute.Route.PASS -> if (fg == Koreader.PKG) "pass (patch not listening: its own key path)" else "pass"
            ClickRoute.Route.TO_PATCH -> "KOReader via the patch"
            ClickRoute.Route.ACT -> "act"
        }}")
        if (route == ClickRoute.Route.PASS) return false
        val key = "${dev.descriptor}:${event.keyCode}"
        val t = timers.getOrPut(key) { PressTimer() }
        val now = SystemClock.uptimeMillis()
        val fired = when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) t.down(now, acts.keys) else null
            KeyEvent.ACTION_UP -> t.up(now)
            else -> null
        }
        fired?.let { acts[it]?.let { a -> run(a, event.keyCode, fg) } }
        schedule(key, t, acts)
        return true
    }

    /** Hold and double windows run on a timer, never by blocking onKeyEvent. */
    private fun schedule(key: String, t: PressTimer, acts: Map<PressKind, ClickAction>) {
        main.removeCallbacksAndMessages(key)
        val due = t.nextDue() ?: return
        main.postAtTime({
            t.tick(SystemClock.uptimeMillis())?.let { k -> acts[k]?.let { a -> run(a, key.substringAfterLast(':').toIntOrNull() ?: 0, foreground) } }
            schedule(key, t, acts)
        }, key, due)
    }

    private fun run(a: ClickAction, keycode: Int, pkg: String?) {
        OLog.i("clicker: key $keycode -> ${a.label.lowercase()} in ${pkg ?: "?"}")
        if (pkg == Koreader.PKG) {
            // Exact in KOReader: the patch turns the page with KOReader's own event, never a tap.
            if (!ClickChannel.send(a)) OLog.w("clicker: KOReader's patch stopped listening; ${a.key} lost")
            return
        }
        when (a) {
            ClickAction.NEXT, ClickAction.PREV -> {
                val zone = ClickerStore.map(this).zoneFor(pkg, a, Vendor.profile(this).tapZones)
                val size = Point()
                @Suppress("DEPRECATION")
                (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealSize(size)
                val g = Zones.gesture(zone, size.x, size.y) ?: return
                val path = Path().apply { moveTo(g.x1, g.y1); lineTo(g.x2, g.y2) }
                dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, g.durationMs)).build(), null, null)
                if (ClickerStore.map(this).showTaps) showDot(g.x1, g.y1)
            }
            ClickAction.HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            ClickAction.BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            ClickAction.SLEEP -> {
                val ok = Build.VERSION.SDK_INT >= 28 && performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
                if (!ok && Net.adminActive(this)) (getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager).lockNow()
            }
            ClickAction.LIGHT -> OLog.i("clicker: frontlight works only in KOReader")
            ClickAction.NOTHING -> Unit
            else -> a.sendKeycode?.let { KeySender.press(this, it, editorFocused) }
        }
    }

    /** "Show taps": a brief dot where the tap went, for checking zones. */
    private fun showDot(x: Float, y: Float) {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val sizePx = Ui.dp(this, 28)
        val v = View(this).apply { background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.BLACK) } }
        val lp = WindowManager.LayoutParams(
            sizePx, sizePx, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = (x - sizePx / 2).toInt()
            this.y = (y - sizePx / 2).toInt()
        }
        try {
            wm.addView(v, lp)
            main.postDelayed({ runCatching { wm.removeView(v) } }, 500)
        } catch (e: Exception) {
            OLog.d("clicker: no tap dot: $e")
        }
    }
}
