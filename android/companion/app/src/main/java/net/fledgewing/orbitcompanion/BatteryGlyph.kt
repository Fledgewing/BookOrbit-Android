package net.fledgewing.orbitcompanion

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import org.json.JSONObject

/** Interpreter for the same sleep battery drawing program used by the Lua reader. */
internal object BatteryGlyph {
    private val program by lazy {
        JSONObject(checkNotNull(javaClass.getResourceAsStream("/battery.json")).bufferedReader().use { it.readText() })
    }
    fun width(size: Float) = (program.getDouble("width") * size).toFloat()
    fun height(size: Float) = (program.getDouble("height") * size).toFloat()
    fun draw(c: Canvas, x: Float, y: Float, size: Float, level: Int) {
        val rectangles = program.getJSONArray("rectangles")
        val paint = Paint()
        for (n in 0 until rectangles.length()) {
            val r = rectangles.getJSONArray(n)
            val left = x + r.getDouble(0).toFloat() * size
            val top = y + r.getDouble(1).toFloat() * size
            val fraction = if (r.optBoolean(5)) level.coerceIn(0, 100) / 100f else 1f
            paint.color = if (r.getInt(4) == 1) Color.BLACK else Color.WHITE
            c.drawRect(left, top, left + r.getDouble(2).toFloat() * size * fraction,
                top + r.getDouble(3).toFloat() * size, paint)
        }
    }
}
