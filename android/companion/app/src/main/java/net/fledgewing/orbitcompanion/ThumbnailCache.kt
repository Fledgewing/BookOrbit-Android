package net.fledgewing.orbitcompanion

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File

/** Browsing images only; sleep images retain their full-screen resolution. */
object ThumbnailCache {
    fun shrink(file: File, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return
        val scale = minOf(1.0, width.toDouble() / bounds.outWidth, height.toDouble() / bounds.outHeight)
        val jpeg = file.inputStream().use { it.read() == 0xff && it.read() == 0xd8 }
        if (scale >= 1.0 && jpeg) return
        val w = maxOf(1, (bounds.outWidth * scale).toInt())
        val h = maxOf(1, (bounds.outHeight * scale).toInt())
        val sampled = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply {
            inSampleSize = SharpCoversLogic.sample(bounds.outWidth, bounds.outHeight, w, h)
        }) ?: return
        val image = Bitmap.createScaledBitmap(sampled, w, h, true)
        val tmp = File(file.path + ".resize")
        val before = file.length()
        val shown = file.lastModified()
        try {
            val ok = tmp.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            val after = tmp.length()
            if (ok && after > 0 && tmp.renameTo(file)) {
                file.setLastModified(shown)
                OLog.i("covers: thumbnail ${bounds.outWidth}x${bounds.outHeight} -> ${w}x$h: $before -> $after bytes; saved ${before - after} bytes; estimated same-size cache saving ${100 - after * 100 / before}%")
            }
        } finally {
            tmp.delete()
            if (image !== sampled) image.recycle()
            sampled.recycle()
        }
    }
}
