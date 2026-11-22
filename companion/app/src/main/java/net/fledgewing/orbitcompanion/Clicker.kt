package net.fledgewing.orbitcompanion

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.widget.LinearLayout

/*
 * Settings › Clicker buttons (docs/BTKEYS-DESIGN.md, mockups docs/btkeys-mockups.html):
 * 1 the button map per clicker, 2 capture, 3 action + per-app page taps.
 */

private fun keyLabel(keycode: Int): String = when (keycode) {
    KeyEvent.KEYCODE_VOLUME_DOWN -> "Vol −"
    KeyEvent.KEYCODE_VOLUME_UP -> "Vol +"
    KeyEvent.KEYCODE_PAGE_DOWN -> "Page down"
    KeyEvent.KEYCODE_PAGE_UP -> "Page up"
    KeyEvent.KEYCODE_MEDIA_NEXT -> "Media next"
    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "Media previous"
    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> "Play/pause"
    KeyEvent.KEYCODE_ENTER -> "Enter"
    KeyEvent.KEYCODE_SPACE -> "Space"
    else -> KeyEvent.keyCodeToString(keycode).removePrefix("KEYCODE_").lowercase().replace('_', ' ').replaceFirstChar { it.uppercase() }
}

/** Screen 1: clickers and their buttons. */
class ClickersActivity : EinkActivity() {
    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Clicker buttons", "‹ Back") { finish() })
        val map = ClickerStore.map(this)
        val connected = ClickerStore.connectedNames()
        val state = ClickerStore.state(this)
        if (state == ClickerRowState.OFF || state == ClickerRowState.NOT_CONNECTED) {
            root.addView(Ui.text(this, "Works in KOReader now. For other apps, switch on Settings › Accessibility › Orbit clicker buttons.", 17f, bold = true))
            root.addView(Ui.button(this, "Open Accessibility settings", heightDp = 64, sp = 18f) {
                tryStart(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), "accessibility settings")
            })
            root.addView(Ui.gap(this, 8))
        }
        map.clickers.forEach { c ->
            val card = Ui.card(this)
            card.addView(Ui.weightRow(this,
                Ui.text(this, "${c.name}\n${c.ids} · ${if (c.name in connected) "connected" else "not connected"}", 18f, bold = true),
                Ui.button(this, "Forget", heightDp = 52, sp = 16f) {
                    ClickerStore.save(this, ClickerStore.map(this).forget(c.id))
                    OLog.i("clicker: forgot ${c.ids}")
                    render()
                }))
            c.buttons.forEach { b ->
                PressKind.entries.filter { it in b.actions }.forEach { kind ->
                    val a = b.actions.getValue(kind)
                    card.addView(Ui.row(this, "${b.label}  ${kind.label}", a.note ?: if (b.builtinToo) "also a built-in button: KOReader keeps its own meaning" else null,
                        Ui.value(this, a.label), onClick = {
                            startActivity(ClickActionActivity.intent(this, c.id, b.keycode, kind))
                        }))
                }
            }
            card.addView(Ui.button(this, "+ Add a button", heightDp = 56, sp = 17f) {
                startActivity(Intent(this, CaptureActivity::class.java))
            })
            root.addView(card)
            root.addView(Ui.gap(this, 8))
        }
        val pointers = ClickerStore.pointerOnlyClickers()
        if (pointers.isNotEmpty()) {
            root.addView(Ui.text(this, "OTHER CLICKERS", 15f, bold = true, color = Ui.MID))
            pointers.forEach { root.addView(Ui.row(this, it, "sends taps, not buttons: can't be mapped", Ui.value(this, "—"))) }
        }
        val others = ClickerRow.others(ClickerStore.accessibilitySetting(this), packageName)
        if (others.isNotEmpty()) {
            val km = "io.github.sds100.keymapper" in others
            root.addView(Ui.text(this, "${if (km) "Key Mapper" else HomeTarget.label(this, others.first())} also remaps keys. Turn it off once these buttons work; you can then uninstall it.", 16f, color = Ui.MID).apply {
                setPadding(0, Ui.dp(this@ClickersActivity, 8), 0, Ui.dp(this@ClickersActivity, 8))
            })
        }
        root.addView(Ui.weightRow(this,
            Ui.button(this, "+ Add a clicker", solid = map.clickers.isEmpty(), heightDp = 64, sp = 18f) { startActivity(Intent(this, CaptureActivity::class.java)) },
        ))
        root.addView(Ui.gap(this, 8))
        root.addView(Ui.row(this, "Show taps", "a brief dot where a page tap goes, for checking zones", Ui.toggle(this, map.showTaps), onClick = {
            ClickerStore.save(this, ClickerStore.map(this).copy(showTaps = !ClickerStore.map(this).showTaps))
            render()
        }))
        root.addView(Ui.text(this, "In KOReader the patch turns pages exactly, no permission needed. Other apps get page taps (right/left third by default; change them on a page action). Orbit never stores or sends your key presses.", 15f, color = Ui.MID).apply {
            setPadding(0, Ui.dp(this@ClickersActivity, 8), 0, 0)
        })
    }
}

/** Screen 2: press a clicker button; records keycode, scancode and the InputDevice. */
class CaptureActivity : EinkActivity() {
    private data class Heard(val keycode: Int, val scancode: Int, val name: String, val vendor: Int, val product: Int, val builtinToo: Boolean)

    private var heard: Heard? = null
    private var hold = false
    private var double = false
    private var ignored: String? = null

    override fun onResume() {
        super.onResume()
        render()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val d = event.device
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount > 0) return ClickerStore.isClicker(d) || super.dispatchKeyEvent(event)
        if (!ClickerStore.isClicker(d)) {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
            ignored = "That was the reader's own button; only Bluetooth clickers count here."
            render()
            return true
        }
        // Only the codes of this one press, kept while this screen is open.
        heard = Heard(event.keyCode, event.scanCode, d.name, d.vendorId, d.productId, ClickerStore.builtinHasKey(event.keyCode))
        ignored = null
        OLog.i("clicker: captured key ${event.keyCode} from ${String.format("%04x:%04x", d.vendorId, d.productId)}")
        render()
        return true
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, "Add a button", "Cancel") { finish() })
        val h = heard
        if (h == null) {
            root.addView(Ui.text(this, "Press a button on your clicker", 26f, bold = true).apply { gravity = Gravity.CENTER; setPadding(0, Ui.dp(this@CaptureActivity, 40), 0, Ui.dp(this@CaptureActivity, 12)) })
            root.addView(Ui.text(this, "Waiting… Bluetooth clickers only; the reader's own buttons are ignored here.", 18f, color = Ui.MID).apply { gravity = Gravity.CENTER })
            ignored?.let { root.addView(Ui.text(this, it, 17f, bold = true).apply { setPadding(0, Ui.dp(this@CaptureActivity, 16), 0, 0) }) }
            val pointers = ClickerStore.pointerOnlyClickers()
            if (pointers.isNotEmpty()) {
                root.addView(Ui.text(this, "${pointers.joinToString()} sends taps, not buttons: it can't be mapped.", 17f, color = Ui.MID).apply { setPadding(0, Ui.dp(this@CaptureActivity, 16), 0, 0) })
            }
            return
        }
        val card = Ui.card(this)
        card.addView(Ui.row(this, "Heard", "key ${h.keycode} · scan ${h.scancode}", Ui.value(this, keyLabel(h.keycode))))
        card.addView(Ui.row(this, "From", String.format("%04x:%04x", h.vendor, h.product), Ui.value(this, h.name)))
        val koreaderKnows = h.keycode in setOf(21, 22, 24, 25, 92, 93)
        card.addView(Ui.row(this, "KOReader alone", if (h.builtinToo) "also a built-in button: KOReader keeps its own meaning" else null,
            Ui.value(this, if (koreaderKnows) "turns pages" else "ignores it · Orbit adds it")))
        root.addView(card)
        root.addView(Ui.gap(this, 8))
        root.addView(Ui.text(this, "This button, when", 17f, color = Ui.MID))
        root.addView(Ui.row(this, "pressed", null, Ui.check(this, true)))
        root.addView(Ui.row(this, "held (0.6 s)", null, Ui.check(this, hold), onClick = { hold = !hold; render() }))
        root.addView(Ui.row(this, "pressed twice", "adds a short wait to single presses", Ui.check(this, double), onClick = { double = !double; render() }))
        root.addView(View(this), LinearLayout.LayoutParams(1, 0, 1f))
        root.addView(Ui.weightRow(this,
            Ui.button(this, "Press again", heightDp = 64, sp = 18f) { heard = null; render() },
            Ui.button(this, "Next: pick action", solid = true, heightDp = 64, sp = 18f) { save(h) }))
    }

    private fun save(h: Heard) {
        val map = ClickerStore.map(this)
        val id = Clicker.profileId(h.name, h.vendor, h.product)
        val c = map.clicker(id) ?: Clicker(h.name, h.vendor, h.product, emptyList())
        val old = c.button(h.keycode)?.actions.orEmpty()
        val acts = linkedMapOf(PressKind.PRESS to (old[PressKind.PRESS] ?: ClickAction.NOTHING))
        if (hold) acts[PressKind.HOLD] = old[PressKind.HOLD] ?: ClickAction.NOTHING
        if (double) acts[PressKind.DOUBLE] = old[PressKind.DOUBLE] ?: ClickAction.NOTHING
        val b = ClickerButton(h.keycode, h.scancode, keyLabel(h.keycode), acts, h.builtinToo)
        ClickerStore.save(this, map.upsert(c.copy(buttons = c.buttons.filter { it.keycode != h.keycode } + b)))
        startActivity(ClickActionActivity.intent(this, id, h.keycode, PressKind.PRESS))
        finish()
    }
}

/** Screen 3: one button's action, and where page actions tap in other apps. */
class ClickActionActivity : EinkActivity() {
    companion object {
        fun intent(ctx: android.content.Context, clicker: String, keycode: Int, kind: PressKind): Intent =
            Intent(ctx, ClickActionActivity::class.java).putExtra("clicker", clicker).putExtra("keycode", keycode).putExtra("kind", kind.key)
    }

    private var clickerId = ""
    private var keycode = 0
    private var kind = PressKind.PRESS
    private var pickingFor: String? = null // package whose zone is being chosen
    private var pickingApp = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        clickerId = intent.getStringExtra("clicker").orEmpty()
        keycode = intent.getIntExtra("keycode", 0)
        kind = PressKind.fromKey(intent.getStringExtra("kind")) ?: PressKind.PRESS
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun appLabel(pkg: String) = HomeTarget.label(this, pkg)

    private fun render() {
        val map = ClickerStore.map(this)
        val b = map.clicker(clickerId)?.button(keycode) ?: return finish()
        val action = b.actions[kind] ?: ClickAction.NOTHING
        pickingFor?.let { return zonePage(it, action) }
        if (pickingApp) return appPage(action)
        val root = page(scroll = true)
        root.addView(Ui.header(this, "${b.label} ${kind.label}", "‹ Back") { finish() })
        root.addView(Ui.text(this, "ACTION", 15f, bold = true, color = Ui.MID))
        ClickAction.entries.forEach { a ->
            root.addView(Ui.row(this, a.label, a.note, Ui.check(this, a == action), onClick = {
                ClickerStore.save(this, ClickerStore.map(this).setAction(clickerId, keycode, kind, a))
                OLog.i("clicker: ${b.label} ${kind.key} -> ${a.key}")
                render()
            }))
        }
        if (action == ClickAction.NEXT || action == ClickAction.PREV) {
            root.addView(Ui.text(this, "${action.label.uppercase()} IN", 15f, bold = true, color = Ui.MID).apply { setPadding(0, Ui.dp(this@ClickActionActivity, 12), 0, 0) })
            root.addView(Ui.row(this, "KOReader", null, Ui.value(this, "exact page turn")))
            val vendor = Vendor.profile(this).tapZones
            (map.zones.keys + vendor.keys).distinct().sortedBy { appLabel(it).lowercase() }.forEach { pkg ->
                val z = map.zoneFor(pkg, action, vendor)
                root.addView(Ui.row(this, appLabel(pkg), if (map.zones[pkg]?.containsKey(action) == true) "your choice" else "default", Ui.value(this, z.label), onClick = {
                    pickingFor = pkg
                    render()
                }))
            }
            root.addView(Ui.row(this, "Every other app", null, Ui.value(this, Zone.defaultFor(action).label)))
            root.addView(Ui.row(this, "+ Override for another app", null, Ui.value(this, "›"), onClick = { pickingApp = true; render() }))
        }
        if (kind != PressKind.PRESS) {
            root.addView(Ui.gap(this, 12))
            root.addView(Ui.button(this, "Stop using ${kind.label}", heightDp = 56, sp = 17f) {
                ClickerStore.save(this, ClickerStore.map(this).setAction(clickerId, keycode, kind, null))
                finish()
            })
        } else {
            root.addView(Ui.gap(this, 12))
            root.addView(Ui.button(this, "Remove this button", heightDp = 56, sp = 17f) {
                ClickerStore.save(this, ClickerStore.map(this).removeButton(clickerId, keycode))
                finish()
            })
        }
    }

    private fun zonePage(pkg: String, action: ClickAction) {
        val root = page()
        root.addView(Ui.header(this, appLabel(pkg), "‹ Back") { pickingFor = null; render() })
        root.addView(Ui.text(this, "${action.label}: where to tap", 17f, color = Ui.MID))
        val current = ClickerStore.map(this).zoneFor(pkg, action, Vendor.profile(this).tapZones)
        Zone.entries.forEach { z ->
            root.addView(Ui.row(this, z.label, null, Ui.check(this, z == current), onClick = {
                ClickerStore.save(this, ClickerStore.map(this).setZone(pkg, action, z))
                pickingFor = null
                render()
            }))
        }
    }

    private fun appPage(action: ClickAction) {
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Override for…", "‹ Back") { pickingApp = false; render() })
        val pm = packageManager
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .filter { it.first != packageName && it.first != Koreader.PKG }
        HomeApp.order(apps, KnownApps.readers(Vendor.profile(this))).forEach { (pkg, label) ->
            root.addView(Ui.row(this, label, null, Ui.value(this, "›"), onClick = {
                pickingApp = false
                pickingFor = pkg
                render()
            }))
        }
    }
}
