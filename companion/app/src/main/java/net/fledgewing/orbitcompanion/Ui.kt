package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Bundle
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Date
import java.util.Locale

/**
 * E-ink pages: black on white, no animations (theme + flags + overridePendingTransition),
 * no ripples (plain state-list backgrounds), big tap targets.
 */
abstract class EinkActivity : Activity() {
    companion object {
        @Volatile
        private var resumed = 0

        @Volatile
        private var lastPausedAt = 0L

        /** One of our pages is in front, or was until a moment ago (Home pauses it first). */
        fun companionPageInFront(): Boolean =
            resumed > 0 || android.os.SystemClock.elapsedRealtime() - lastPausedAt < 2_000
    }

    override fun onResume() {
        super.onResume()
        resumed++
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setWindowAnimations(0)
        noTransition()
    }

    override fun startActivity(intent: Intent, options: Bundle?) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        super.startActivity(intent, options)
        noTransition()
    }

    override fun finish() {
        super.finish()
        noTransition()
    }

    override fun onPause() {
        super.onPause()
        resumed = maxOf(0, resumed - 1)
        lastPausedAt = android.os.SystemClock.elapsedRealtime()
        noTransition()
    }

    @Suppress("DEPRECATION")
    private fun noTransition() = overridePendingTransition(0, 0)

    /** Starts a system page; false (and logged) if this device has no such page. */
    fun tryStart(intent: Intent, what: String): Boolean = try {
        startActivity(intent)
        OLog.i("opened $what")
        true
    } catch (e: Exception) {
        OLog.w("could not open $what", e)
        false
    }

    /** [scroll]: long pages (settings, setup) scroll; the rest are fixed, one e-ink redraw. */
    fun page(scroll: Boolean = false): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(Ui.PAPER)
        val p = Ui.dp(this@EinkActivity, 20)
        setPadding(p, p, p, p)
        if (scroll) {
            setContentView(android.widget.ScrollView(this@EinkActivity).also {
                it.setBackgroundColor(Ui.PAPER)
                it.isVerticalScrollBarEnabled = true
                it.addView(this)
            })
        } else {
            setContentView(this)
        }
    }
}

object Ui {
    const val INK = Color.BLACK
    const val PAPER = Color.WHITE
    val MID = Color.rgb(0x55, 0x55, 0x55)
    val LIGHT = Color.rgb(0xBB, 0xBB, 0xBB)
    val PRESSED = Color.rgb(0xDD, 0xDD, 0xDD)

    const val ROW_DP = 76
    const val BUTTON_DP = 88

    fun dp(ctx: Context, v: Int): Int = (v * ctx.resources.displayMetrics.density + 0.5f).toInt()

    fun box(ctx: Context, fill: Int, stroke: Int = INK, strokeDp: Int = 2, radiusDp: Int = 8, oval: Boolean = false): GradientDrawable =
        GradientDrawable().apply {
            if (oval) shape = GradientDrawable.OVAL else cornerRadius = dp(ctx, radiusDp).toFloat()
            setColor(fill)
            if (strokeDp > 0) setStroke(dp(ctx, strokeDp), stroke)
        }

    /** Instant state change, no ripple, no fade. */
    fun pressable(normal: Drawable, pressed: Drawable): StateListDrawable = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), pressed)
        addState(intArrayOf(), normal)
        setEnterFadeDuration(0)
        setExitFadeDuration(0)
    }

    fun text(ctx: Context, s: CharSequence, sp: Float = 20f, bold: Boolean = false, color: Int = INK): TextView =
        TextView(ctx).apply {
            text = s
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = true
        }

    fun clickable(v: View, onClick: (() -> Unit)?, onLong: (() -> Unit)? = null) {
        v.isSoundEffectsEnabled = false
        v.isHapticFeedbackEnabled = false
        if (onClick != null) v.setOnClickListener { onClick() }
        if (onLong != null) v.setOnLongClickListener { onLong(); true }
    }

    fun button(ctx: Context, label: CharSequence, solid: Boolean = false, heightDp: Int = BUTTON_DP, sp: Float = 22f, onClick: () -> Unit): TextView =
        text(ctx, label, sp, bold = true, color = if (solid) PAPER else INK).apply {
            gravity = Gravity.CENTER
            minHeight = dp(ctx, heightDp)
            val p = dp(ctx, 12)
            setPadding(p, p / 2, p, p / 2)
            background = if (solid) {
                pressable(box(ctx, INK), box(ctx, MID))
            } else {
                pressable(box(ctx, PAPER), box(ctx, PRESSED))
            }
            clickable(this, onClick)
        }

    /** Header: title on the left, an optional small button on the right. */
    fun header(ctx: Context, title: String, action: String? = null, onAction: (() -> Unit)? = null): LinearLayout =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text(ctx, title, 30f, bold = true), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            if (action != null && onAction != null) {
                addView(
                    button(ctx, action, heightDp = 64, sp = 20f, onClick = onAction),
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT),
                )
            }
            setPadding(0, 0, 0, dp(ctx, 12))
        }

    /** A list row: label (+ small line) on the left, a value or control on the right, a thin rule below. */
    fun row(
        ctx: Context,
        label: CharSequence,
        sub: CharSequence? = null,
        right: View? = null,
        onClick: (() -> Unit)? = null,
        onLong: (() -> Unit)? = null,
        left: View? = null,
    ): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(ctx, ROW_DP)
        val p = dp(ctx, 6)
        setPadding(p, p, p, p)
        val rule = GradientDrawable().apply { setColor(PAPER) }
        val normal = android.graphics.drawable.LayerDrawable(arrayOf(box(ctx, LIGHT, strokeDp = 0, radiusDp = 0), rule)).apply {
            setLayerInset(1, 0, 0, 0, dp(ctx, 1))
        }
        val pressed = android.graphics.drawable.LayerDrawable(arrayOf(box(ctx, LIGHT, strokeDp = 0, radiusDp = 0), GradientDrawable().apply { setColor(PRESSED) })).apply {
            setLayerInset(1, 0, 0, 0, dp(ctx, 1))
        }
        background = if (onClick != null || onLong != null) pressable(normal, pressed) else normal
        if (left != null) addView(left)
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(text(ctx, label, 21f))
            if (!sub.isNullOrEmpty()) addView(text(ctx, sub, 16f, color = MID))
        }
        addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (right != null) addView(right)
        clickable(this, onClick, onLong)
    }

    fun value(ctx: Context, s: CharSequence, bold: Boolean = true): TextView =
        text(ctx, s, 20f, bold = bold).apply { gravity = Gravity.END }

    /** On/Off control drawn as a box: filled when on. Changes instantly. */
    fun toggle(ctx: Context, on: Boolean): TextView = text(ctx, if (on) "On" else "Off", 18f, bold = true, color = if (on) PAPER else INK).apply {
        gravity = Gravity.CENTER
        minWidth = dp(ctx, 76)
        minHeight = dp(ctx, 44)
        background = box(ctx, if (on) INK else PAPER)
    }

    /** Checklist box: filled with a tick when done. */
    fun check(ctx: Context, done: Boolean): TextView = text(ctx, if (done) "✓" else "", 20f, bold = true, color = PAPER).apply {
        gravity = Gravity.CENTER
        val s = dp(ctx, 34)
        layoutParams = LinearLayout.LayoutParams(s, s).apply { marginEnd = dp(ctx, 14) }
        background = box(ctx, if (done) INK else PAPER, radiusDp = 2)
    }

    /** Letter in a circle, the mockup's app "icon". */
    fun letter(ctx: Context, label: String, sizeDp: Int = 44): TextView =
        text(ctx, label.firstOrNull { it.isLetterOrDigit() }?.uppercase(Locale.getDefault()) ?: "?", 20f, bold = true).apply {
            gravity = Gravity.CENTER
            val s = dp(ctx, sizeDp)
            layoutParams = LinearLayout.LayoutParams(s, s).apply { marginEnd = dp(ctx, 14) }
            background = box(ctx, PAPER, oval = true)
        }

    fun card(ctx: Context): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        background = box(ctx, PAPER)
        val p = dp(ctx, 12)
        setPadding(p, p / 2, p, p / 2)
    }

    fun gap(ctx: Context, dpH: Int): View = View(ctx).apply {
        layoutParams = LinearLayout.LayoutParams(1, dp(ctx, dpH))
    }

    fun weightRow(ctx: Context, vararg views: View, gapDp: Int = 12): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        views.forEachIndexed { i, v ->
            addView(v, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                if (i > 0) marginStart = dp(ctx, gapDp)
            })
        }
    }

    fun clock(ctx: Context, wallMs: Long): String = DateFormat.getTimeFormat(ctx).format(Date(wallMs))

    fun secs(ms: Long): String = String.format(Locale.US, "%.1f s", ms / 1000.0)
}
