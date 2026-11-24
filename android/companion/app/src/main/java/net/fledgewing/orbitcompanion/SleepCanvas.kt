package net.fledgewing.orbitcompanion

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface

/**
 * The one renderer both sinks use (docs/design/lock-screen.md "Building blocks"): the screen saver
 * draws it when the reader goes to sleep, the picture sink writes it to Pictures/Orbit/sleep.png.
 * Black and white only around the cover, so the text stays on a colour panel's sharp layer (L6).
 */
object SleepCanvas {
    /** What to draw. cover: the decoded image, or null for the drawn cover (F3) or the default page (F5). */
    data class Input(
        val w: Int,
        val h: Int,
        val fontPx: Int,
        val settings: SleepSettings,
        val cover: Bitmap?,
        /** "pool", "current" or "default". */
        val kind: String,
        val title: String = "",
        val authors: String = "",
        /** 0-100, or null (not shown). */
        val battery: Int?,
    )

    /** What was laid out, for the tests and the log. */
    data class Drawn(val cover: Box?, val band: Box?, val text: Box?, val battery: Box?, val lines: List<String>, val corner: Corner?)

    fun render(i: Input): Pair<Bitmap, Drawn> {
        val bmp = Bitmap.createBitmap(i.w, i.h, Bitmap.Config.ARGB_8888)
        return bmp to draw(Canvas(bmp), i)
    }

    private fun paint(px: Int, bold: Boolean = false) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = px.toFloat()
        typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
    }

    private fun stroke(px: Int) = Paint().apply {
        color = Color.BLACK
        style = Paint.Style.STROKE
        strokeWidth = px.toFloat()
    }

    private val white = Paint().apply { color = Color.WHITE }

    fun draw(c: Canvas, i: Input): Drawn {
        val s = i.settings
        c.drawColor(Color.WHITE)
        val text = paint(i.fontPx)
        val pad = i.fontPx / 2
        val battery = i.battery?.takeIf { s.battery }
        val batteryW = if (battery != null) batteryWidth(text, battery) else 0
        val hasText = s.text.isNotEmpty()
        val bar = s.style == SleepStyle.BAR && (hasText || battery != null)
        val maxW = SleepLayout.maxTextWidth(i.w, i.h, s.style, s.textPosition, pad, batteryW)
        val maxLines = if (s.style == SleepStyle.OVERLAY && s.textPosition.vertical) 1 else 2
        val lines = if (hasText) SleepLayout.wrap(s.text, maxW, maxLines) { text.measureText(it) } else emptyList()
        val bandH = if (bar) SleepLayout.bandHeight(i.h, lines.size) else 0
        // The cover, the drawn cover or the default page, above the band.
        val area = Box(0, 0, i.w, i.h - bandH)
        val coverBox = when {
            i.cover != null -> SleepLayout.cover(i.w, i.h, bandH, i.cover.width, i.cover.height).also {
                c.drawBitmap(i.cover, null, Rect(it.left, it.top, it.right, it.bottom), Paint(Paint.FILTER_BITMAP_FLAG))
            }
            i.kind == "current" -> drawnCover(c, area, i).let { null }
            else -> defaultPage(c, area, i.fontPx).let { null }
        }
        if (bar) {
            val band = Box(0, i.h - bandH, i.w, i.h)
            c.drawRect(band.left.toFloat(), band.top.toFloat(), band.right.toFloat(), band.bottom.toFloat(), white)
            c.drawRect(0f, band.top.toFloat(), i.w.toFloat(), band.top + 2f, Paint().apply { color = Color.BLACK })
            val inset = SleepLayout.inset(i.w, i.h)
            val lineH = text.fontSpacing
            val top = band.top + (bandH - lineH * lines.size) / 2f
            lines.forEachIndexed { n, l -> c.drawText(l, inset.toFloat(), top + n * lineH - text.ascent(), text) }
            var batBox: Box? = null
            if (battery != null) {
                val bh = (lineH).toInt()
                val l = i.w - inset - batteryW
                val t = band.top + (bandH - bh) / 2
                batBox = Box(l, t, l + batteryW, t + bh)
                drawBattery(c, text, batBox, battery)
            }
            return Drawn(coverBox, band, null, batBox, lines, null)
        }
        // Overlay: white plates with a black outline (L3d).
        var textBox: Box? = null
        if (lines.isNotEmpty()) {
            val lineH = text.fontSpacing
            val textW = lines.maxOf { text.measureText(it) }.toInt()
            val plate = SleepLayout.textPlate(i.w, i.h, s.textPosition, textW, (lineH * lines.size).toInt(), pad)
            plateAt(c, plate)
            if (s.textPosition.vertical) {
                c.save()
                // Right: top to bottom (turn the reader anticlockwise); Left: bottom to top.
                val cx = (plate.left + plate.right) / 2f
                val cy = (plate.top + plate.bottom) / 2f
                c.rotate(if (s.textPosition == TextPosition.RIGHT) 90f else -90f, cx, cy)
                val w = text.measureText(lines[0])
                c.drawText(lines[0], cx - w / 2f, cy - (text.ascent() + text.descent()) / 2f, text)
                c.restore()
            } else {
                val top = plate.top + pad
                lines.forEachIndexed { n, l ->
                    val w = text.measureText(l)
                    c.drawText(l, (i.w - w) / 2f, top + n * lineH - text.ascent(), text)
                }
            }
            textBox = plate
        }
        var batBox: Box? = null
        var corner: Corner? = null
        if (battery != null) {
            corner = SleepLayout.batteryCorner(s.batteryCorner, s.textPosition, lines.isNotEmpty())
            val plate = SleepLayout.batteryPlate(i.w, i.h, corner, batteryW, text.fontSpacing.toInt(), pad)
            plateAt(c, plate)
            batBox = Box(plate.left + pad, plate.top + pad, plate.right - pad, plate.bottom - pad)
            drawBattery(c, text, batBox, battery)
        }
        return Drawn(coverBox, null, textBox, batBox, lines, corner)
    }

    private fun plateAt(c: Canvas, b: Box) {
        val r = RectF(b.left.toFloat(), b.top.toFloat(), b.right.toFloat(), b.bottom.toFloat())
        c.drawRect(r, white)
        c.drawRect(r, stroke(2))
    }

    /** The battery: an outline icon, then the percent (L4). */
    private fun batteryWidth(p: Paint, level: Int): Int = (p.textSize * 1.6f + p.measureText(" $level%")).toInt()

    private fun drawBattery(c: Canvas, p: Paint, b: Box, level: Int) {
        val iconW = p.textSize * 1.4f
        val iconH = p.textSize * 0.7f
        val top = b.top + (b.height - iconH) / 2f
        val body = RectF(b.left.toFloat(), top, b.left + iconW, top + iconH)
        c.drawRect(body, stroke(2))
        val nub = iconH / 3f
        c.drawRect(body.right, top + nub, body.right + p.textSize * 0.15f, top + 2 * nub, Paint().apply { color = Color.BLACK })
        val inner = RectF(body.left + 4f, body.top + 4f, body.left + 4f + (body.width() - 8f) * level.coerceIn(0, 100) / 100f, body.bottom - 4f)
        c.drawRect(inner, Paint().apply { color = Color.BLACK })
        val tx = b.left + p.textSize * 1.6f
        c.drawText("$level%", tx, b.top + (b.height - (p.descent() - p.ascent())) / 2f - p.ascent(), p)
    }

    /** F3: the book has no cover: its title and author on a plain frame. */
    private fun drawnCover(c: Canvas, a: Box, i: Input) {
        val margin = a.width / 8f
        val frame = RectF(a.left + margin, a.top + margin, a.right - margin, a.bottom - margin)
        c.drawRect(frame, stroke(6))
        val title = paint(i.fontPx * 2, bold = true)
        val maxW = (frame.width() - 2 * margin / 2).toInt()
        val lines = SleepLayout.wrap(i.title.ifEmpty { "Untitled" }, maxW, 4) { title.measureText(it) }
        var y = frame.top + frame.height() / 3f
        for (l in lines) {
            c.drawText(l, frame.centerX() - title.measureText(l) / 2f, y, title)
            y += title.fontSpacing
        }
        if (i.authors.isNotEmpty()) {
            val by = paint(i.fontPx)
            val a2 = if (by.measureText(i.authors) <= maxW) i.authors else SleepLayout.cut(i.authors, maxW, by::measureText)
            c.drawText(a2, frame.centerX() - by.measureText(a2) / 2f, y + by.fontSpacing, by)
        }
    }

    /** F5: a plain page with a book outline and "Sleeping". */
    private fun defaultPage(c: Canvas, a: Box, fontPx: Int) {
        val bw = a.width / 4f
        val bh = bw * 1.4f
        val cx = a.width / 2f
        val cy = a.top + a.height / 2f - bh / 2f
        c.drawRect(RectF(cx - bw / 2f, cy - bh / 2f, cx + bw / 2f, cy + bh / 2f), stroke(4))
        c.drawLine(cx - bw / 2f + bw / 8f, cy - bh / 2f, cx - bw / 2f + bw / 8f, cy + bh / 2f, stroke(4))
        val p = paint(fontPx * 3 / 2)
        val t = "Sleeping"
        c.drawText(t, cx - p.measureText(t) / 2f, cy + bh / 2f + p.fontSpacing * 1.5f, p)
    }
}
