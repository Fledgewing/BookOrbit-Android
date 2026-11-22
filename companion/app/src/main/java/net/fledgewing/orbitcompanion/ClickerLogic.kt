package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject

/*
 * Clicker buttons, pure part (docs/BTKEYS-DESIGN.md): the key map, press/hold/double timing,
 * zone -> tap conversion, the Setup row's state, and what the patch gets in /status.
 * No Android here, so it is unit-tested.
 */

enum class PressKind(val key: String, val label: String) {
    PRESS("press", "press"), HOLD("hold", "hold"), DOUBLE("double", "double");

    companion object {
        fun fromKey(k: String?): PressKind? = entries.firstOrNull { it.key == k }
    }
}

/**
 * The small action list (BTKEYS-DESIGN.md "Actions"). Send-key actions (v0.4.1) deliver a real
 * key to the app in front through the Orbit keyboard ([sendKeycode], Android keycodes).
 */
enum class ClickAction(val key: String, val label: String, val note: String?, val sendKeycode: Int? = null) {
    NEXT("next", "Next page", null),
    PREV("prev", "Previous page", null),
    HOME("home", "Home", null),
    BACK("back", "Back", null),
    LIGHT("light", "Frontlight on/off", "KOReader only"),
    SLEEP("sync_sleep", "Sync and sleep", "other apps: Sleep"),
    SEND_VOL_UP("send_vol_up", "Send Volume up", "a real key, through the Orbit keyboard", 24),
    SEND_VOL_DOWN("send_vol_down", "Send Volume down", "a real key, through the Orbit keyboard", 25),
    SEND_PAGE_UP("send_page_up", "Send Page up", null, 92),
    SEND_PAGE_DOWN("send_page_down", "Send Page down", null, 93),
    SEND_LEFT("send_left", "Send Left arrow", null, 21),
    SEND_RIGHT("send_right", "Send Right arrow", null, 22),
    SEND_UP("send_up", "Send Up arrow", null, 19),
    SEND_DOWN("send_down", "Send Down arrow", null, 20),
    SEND_SPACE("send_space", "Send Space", null, 62),
    NOTHING("nothing", "Nothing (the app gets the key)", null);

    val sendsKey: Boolean get() = sendKeycode != null

    /**
     * In KOReader the patch acts, not the keyboard: a sent key becomes the page turn KOReader
     * gives that key on Android (event_map: Vol up/PgUp/Left = back, Vol down/PgDn/Right = forward).
     */
    val inKoreader: ClickAction get() = when (this) {
        SEND_VOL_UP, SEND_PAGE_UP, SEND_LEFT, SEND_UP -> PREV
        SEND_VOL_DOWN, SEND_PAGE_DOWN, SEND_RIGHT, SEND_DOWN, SEND_SPACE -> NEXT
        else -> this
    }

    companion object {
        fun fromKey(k: String?): ClickAction? = entries.firstOrNull { it.key == k }

        /** The picker's main list; the other send keys sit under "Send key…". */
        val MAIN = listOf(NEXT, PREV, HOME, BACK, LIGHT, SLEEP, SEND_VOL_UP, SEND_VOL_DOWN, NOTHING)
        val MORE_KEYS = listOf(SEND_PAGE_UP, SEND_PAGE_DOWN, SEND_LEFT, SEND_RIGHT, SEND_UP, SEND_DOWN, SEND_SPACE)
    }
}

/** Where a page action taps in another app. */
enum class Zone(val key: String, val label: String) {
    RIGHT_THIRD("right_third", "tap right third"),
    LEFT_THIRD("left_third", "tap left third"),
    BOTTOM_HALF("bottom_half", "tap bottom half"),
    TOP_HALF("top_half", "tap top half"),
    SWIPE_LEFT("swipe_left", "swipe left"),
    SWIPE_RIGHT("swipe_right", "swipe right"),
    NONE("none", "send nothing");

    companion object {
        fun fromKey(k: String?): Zone? = entries.firstOrNull { it.key == k }
        fun defaultFor(a: ClickAction): Zone = if (a == ClickAction.PREV) LEFT_THIRD else RIGHT_THIRD
    }
}

/** A tap (x1==x2, y1==y2) or a swipe, in screen pixels. */
data class Gesture(val x1: Float, val y1: Float, val x2: Float, val y2: Float, val durationMs: Long) {
    val isTap: Boolean get() = x1 == x2 && y1 == y2
}

object Zones {
    const val TAP_MS = 60L
    const val SWIPE_MS = 250L

    /** The middle of the zone, mid-height for thirds; swipes run across the middle 60%. Null: send nothing. */
    fun gesture(zone: Zone, w: Int, h: Int): Gesture? {
        val fw = w.toFloat()
        val fh = h.toFloat()
        return when (zone) {
            Zone.RIGHT_THIRD -> Gesture(fw * 5 / 6, fh / 2, fw * 5 / 6, fh / 2, TAP_MS)
            Zone.LEFT_THIRD -> Gesture(fw / 6, fh / 2, fw / 6, fh / 2, TAP_MS)
            Zone.BOTTOM_HALF -> Gesture(fw / 2, fh * 3 / 4, fw / 2, fh * 3 / 4, TAP_MS)
            Zone.TOP_HALF -> Gesture(fw / 2, fh / 4, fw / 2, fh / 4, TAP_MS)
            Zone.SWIPE_LEFT -> Gesture(fw * 0.8f, fh / 2, fw * 0.2f, fh / 2, SWIPE_MS)
            Zone.SWIPE_RIGHT -> Gesture(fw * 0.2f, fh / 2, fw * 0.8f, fh / 2, SWIPE_MS)
            Zone.NONE -> null
        }
    }
}

data class ClickerButton(
    val keycode: Int,
    val scancode: Int,
    val label: String,
    /** The default action per press kind. */
    val actions: Map<PressKind, ClickAction>,
    /** The reader's own buttons also send this keycode: in KOReader it keeps KOReader's meaning. */
    val builtinToo: Boolean = false,
    /** Per-app overrides of the action itself: package -> kind -> action (v0.4.1). */
    val appActions: Map<String, Map<PressKind, ClickAction>> = emptyMap(),
) {
    /** The actions in [pkg]: its override per kind, else the default. Kinds come from the default. */
    fun resolve(pkg: String?): Map<PressKind, ClickAction> {
        val o = pkg?.let { appActions[it] }.orEmpty()
        return actions.mapValues { (k, a) -> o[k] ?: a }
    }
}

/** One clicker profile: InputDevice name + vendor/product ids. */
data class Clicker(val name: String, val vendor: Int, val product: Int, val buttons: List<ClickerButton>) {
    val id: String get() = profileId(name, vendor, product)
    val ids: String get() = String.format("%04x:%04x", vendor, product)

    fun button(keycode: Int) = buttons.firstOrNull { it.keycode == keycode }

    companion object {
        fun profileId(name: String, vendor: Int, product: Int) = String.format("%04x:%04x:%s", vendor, product, name)
    }
}

data class KeyMap(
    val clickers: List<Clicker> = emptyList(),
    /** package -> action (next/prev) -> zone; overrides the vendor defaults and the thirds. */
    val zones: Map<String, Map<ClickAction, Zone>> = emptyMap(),
    val showTaps: Boolean = false,
) {
    val mapped: Boolean get() = clickers.any { c -> c.buttons.any { b -> b.actions.values.any { it != ClickAction.NOTHING } } }

    /** Any default or per-app action sends a key (the Orbit keyboard is needed). */
    val sendsKeys: Boolean get() = clickers.any { c ->
        c.buttons.any { b -> b.actions.values.any { it.sendsKey } || b.appActions.values.any { m -> m.values.any { it.sendsKey } } }
    }

    fun setAppAction(clickerId: String, keycode: Int, pkg: String, kind: PressKind, action: ClickAction?): KeyMap {
        val c = clicker(clickerId) ?: return this
        val b = c.button(keycode) ?: return this
        val cur = b.appActions[pkg].orEmpty()
        val next = if (action == null) cur - kind else cur + (kind to action)
        val nb = b.copy(appActions = if (next.isEmpty()) b.appActions - pkg else b.appActions + (pkg to next))
        return upsert(c.copy(buttons = c.buttons.map { if (it.keycode == keycode) nb else it }))
    }

    fun clicker(id: String) = clickers.firstOrNull { it.id == id }

    fun upsert(c: Clicker): KeyMap = copy(clickers = clickers.filter { it.id != c.id } + c)

    fun forget(id: String): KeyMap = copy(clickers = clickers.filter { it.id != id })

    fun setAction(clickerId: String, keycode: Int, kind: PressKind, action: ClickAction?): KeyMap {
        val c = clicker(clickerId) ?: return this
        val b = c.button(keycode) ?: return this
        val acts = if (action == null) b.actions - kind else b.actions + (kind to action)
        // "Stop using hold/double" drops that kind's per-app overrides too.
        val apps = if (action == null) b.appActions.mapValues { it.value - kind }.filterValues { it.isNotEmpty() } else b.appActions
        val nb = b.copy(actions = acts, appActions = apps)
        return upsert(c.copy(buttons = c.buttons.map { if (it.keycode == keycode) nb else it }))
    }

    fun removeButton(clickerId: String, keycode: Int): KeyMap {
        val c = clicker(clickerId) ?: return this
        return upsert(c.copy(buttons = c.buttons.filter { it.keycode != keycode }))
    }

    /** The mapped actions for a key from this device in app [pkg], or null (not ours: let it through). */
    fun lookup(name: String, vendor: Int, product: Int, keycode: Int, pkg: String? = null): Map<PressKind, ClickAction>? {
        val b = clicker(Clicker.profileId(name, vendor, product))?.button(keycode) ?: return null
        val acts = b.resolve(pkg).filterValues { it != ClickAction.NOTHING }
        return acts.ifEmpty { null }
    }

    /** The zone for a page action in an app: the user's override, else the vendor default, else the thirds. */
    fun zoneFor(pkg: String?, action: ClickAction, vendorDefaults: Map<String, Map<ClickAction, Zone>>): Zone =
        pkg?.let { zones[it]?.get(action) ?: vendorDefaults[it]?.get(action) } ?: Zone.defaultFor(action)

    fun setZone(pkg: String, action: ClickAction, zone: Zone?): KeyMap {
        val cur = zones[pkg].orEmpty()
        val next = if (zone == null) cur - action else cur + (action to zone)
        return copy(zones = if (next.isEmpty()) zones - pkg else zones + (pkg to next))
    }

    /**
     * What the patch gets in /status ("keymap"): keycode -> {press,hold,double: action}. Keys the
     * reader's own buttons also send are left out (KOReader keeps its meaning for them), and so
     * are "nothing" actions. Two clickers with the same keycode: the later profile wins.
     */
    fun forPatch(): JSONObject {
        val out = JSONObject()
        for (c in clickers) for (b in c.buttons) {
            if (b.builtinToo) continue
            val acts = b.resolve(HomeApp.KOREADER_PKG).filterValues { it != ClickAction.NOTHING }
            if (acts.isEmpty()) continue
            val o = JSONObject()
            acts.forEach { (k, a) -> o.put(k.key, a.inKoreader.key) }
            out.put(b.keycode.toString(), o)
        }
        return out
    }

    fun toJson(): JSONObject {
        val cs = JSONArray()
        clickers.forEach { c ->
            val bs = JSONArray()
            c.buttons.forEach { b ->
                val acts = JSONObject()
                b.actions.forEach { (k, a) -> acts.put(k.key, a.key) }
                val apps = JSONObject()
                b.appActions.forEach { (pkg, m) ->
                    val o = JSONObject()
                    m.forEach { (k, a) -> o.put(k.key, a.key) }
                    apps.put(pkg, o)
                }
                bs.put(JSONObject().put("keycode", b.keycode).put("scancode", b.scancode).put("label", b.label)
                    .put("builtin_too", b.builtinToo).put("actions", acts).put("app_actions", apps))
            }
            cs.put(JSONObject().put("name", c.name).put("vendor", c.vendor).put("product", c.product).put("buttons", bs))
        }
        val zs = JSONObject()
        zones.forEach { (pkg, m) ->
            val o = JSONObject()
            m.forEach { (a, z) -> o.put(a.key, z.key) }
            zs.put(pkg, o)
        }
        return JSONObject().put("clickers", cs).put("zones", zs).put("show_taps", showTaps)
    }

    companion object {
        fun fromJson(text: String?): KeyMap {
            if (text.isNullOrBlank()) return KeyMap()
            return try {
                val o = JSONObject(text)
                val clickers = mutableListOf<Clicker>()
                o.optJSONArray("clickers")?.let { cs ->
                    for (i in 0 until cs.length()) {
                        val c = cs.getJSONObject(i)
                        val buttons = mutableListOf<ClickerButton>()
                        c.optJSONArray("buttons")?.let { bs ->
                            for (j in 0 until bs.length()) {
                                val b = bs.getJSONObject(j)
                                fun kinds(a: JSONObject?): Map<PressKind, ClickAction> {
                                    val m = mutableMapOf<PressKind, ClickAction>()
                                    a?.keys()?.forEach { k ->
                                        val kind = PressKind.fromKey(k)
                                        val act = ClickAction.fromKey(a.optString(k))
                                        if (kind != null && act != null) m[kind] = act
                                    }
                                    return m
                                }
                                val apps = mutableMapOf<String, Map<PressKind, ClickAction>>()
                                b.optJSONObject("app_actions")?.let { a -> a.keys().forEach { pkg -> kinds(a.optJSONObject(pkg)).takeIf { it.isNotEmpty() }?.let { apps[pkg] = it } } }
                                buttons += ClickerButton(b.getInt("keycode"), b.optInt("scancode"), b.optString("label"), kinds(b.optJSONObject("actions")), b.optBoolean("builtin_too"), apps)
                            }
                        }
                        clickers += Clicker(c.getString("name"), c.optInt("vendor"), c.optInt("product"), buttons)
                    }
                }
                val zones = mutableMapOf<String, Map<ClickAction, Zone>>()
                o.optJSONObject("zones")?.let { zs ->
                    zs.keys().forEach { pkg ->
                        val m = mutableMapOf<ClickAction, Zone>()
                        zs.optJSONObject(pkg)?.let { z ->
                            z.keys().forEach { k ->
                                val a = ClickAction.fromKey(k)
                                val zone = Zone.fromKey(z.optString(k))
                                if (a != null && zone != null) m[a] = zone
                            }
                        }
                        if (m.isNotEmpty()) zones[pkg] = m
                    }
                }
                KeyMap(clickers, zones, o.optBoolean("show_taps"))
            } catch (e: Exception) {
                KeyMap()
            }
        }
    }
}

/**
 * Press, hold (≥ 0.6 s) and double (2nd press ≤ 0.35 s) for one key, decided without blocking:
 * the caller feeds key down/up and calls [tick] at [nextDue]. Long/double are timed only when the
 * key has one, so a plain press fires on key down with no delay.
 */
class PressTimer(private val holdMs: Long = HOLD_MS, private val doubleMs: Long = DOUBLE_MS) {
    companion object {
        const val HOLD_MS = 600L
        const val DOUBLE_MS = 350L
    }

    private var downAt: Long? = null
    private var holdFired = false
    private var singleDueAt: Long? = null
    private var kinds: Set<PressKind> = emptySet()

    /** Key down (repeats ignored). Returns a kind to fire now, or null. */
    fun down(now: Long, kinds: Set<PressKind>): PressKind? {
        if (downAt != null) return null
        this.kinds = kinds
        downAt = now
        holdFired = false
        val pending = singleDueAt
        var late = false
        if (pending != null) {
            singleDueAt = null
            if (PressKind.DOUBLE in kinds && now <= pending) {
                holdFired = true // the second press is used up: its up fires nothing
                return PressKind.DOUBLE
            }
            late = PressKind.PRESS in kinds // the tick never came: the first press still counts
        }
        val simple = PressKind.HOLD !in kinds && PressKind.DOUBLE !in kinds
        if (simple) {
            holdFired = true
            return if (PressKind.PRESS in kinds) PressKind.PRESS else null
        }
        return if (late) PressKind.PRESS else null
    }

    /** Key up. Returns a kind to fire now, or null (maybe waiting for a second press: see [nextDue]). */
    fun up(now: Long): PressKind? {
        val d = downAt ?: return null
        downAt = null
        if (holdFired) return null
        if (PressKind.HOLD in kinds && now - d >= holdMs) return PressKind.HOLD
        if (PressKind.DOUBLE in kinds) {
            singleDueAt = now + doubleMs
            return null
        }
        return if (PressKind.PRESS in kinds) PressKind.PRESS else null
    }

    /** When [tick] must run next, or null. */
    fun nextDue(): Long? {
        val d = downAt
        if (d != null && !holdFired && PressKind.HOLD in kinds) return d + holdMs
        return singleDueAt
    }

    /** Timers: a hold reached while still down, or a single press whose double window ran out. */
    fun tick(now: Long): PressKind? {
        val d = downAt
        if (d != null && !holdFired && PressKind.HOLD in kinds && now - d >= holdMs) {
            holdFired = true
            return PressKind.HOLD
        }
        val s = singleDueAt
        if (s != null && now >= s) {
            singleDueAt = null
            return if (PressKind.PRESS in kinds) PressKind.PRESS else null
        }
        return null
    }
}

/** The Setup row "Clicker buttons (accessibility)" (BTKEYS-DESIGN.md "Staying on"). */
enum class ClickerRowState { HIDDEN, DONE, OFF, NOT_CONNECTED }

object ClickerRow {
    fun state(mapped: Boolean, enabledInSettings: Boolean, connected: Boolean): ClickerRowState = when {
        !mapped -> ClickerRowState.HIDDEN
        !enabledInSettings -> ClickerRowState.OFF
        !connected -> ClickerRowState.NOT_CONNECTED
        else -> ClickerRowState.DONE
    }

    /** Settings.Secure enabled_accessibility_services ("pkg/cls:pkg/cls") lists this component. */
    fun enabledIn(setting: String?, pkg: String, cls: String): Boolean {
        val full = "$pkg/$cls"
        val short = "$pkg/${cls.removePrefix(pkg)}"
        return setting.orEmpty().split(':').any { it.equals(full, true) || it.equals(short, true) }
    }

    /** Other enabled services in that setting (e.g. Key Mapper), by package. */
    fun others(setting: String?, pkg: String): List<String> =
        setting.orEmpty().split(':').filter { it.isNotBlank() }.map { it.substringBefore('/') }.filter { it != pkg }.distinct()
}
