package net.fledgewing.orbitcompanion

import android.graphics.BitmapFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import android.graphics.Bitmap
import java.io.File
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ThumbnailCacheTest {
    @Test fun oversizedCoverIsFittedOnceAndPreservesDisplayTime() {
        val file = File(Files.createTempDirectory("thumb").toFile(), "cover.jpg")
        val source = Bitmap.createBitmap(800, 1200, Bitmap.Config.ARGB_8888)
        val random = java.util.Random(7)
        for (y in 0 until source.height) for (x in 0 until source.width) source.setPixel(x, y, random.nextInt() or (0xff shl 24))
        file.outputStream().use { source.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        source.recycle()
        file.setLastModified(100_000)
        val before = file.length()
        ThumbnailCache.shrink(file, 300, 400)
        val image = BitmapFactory.decodeFile(file.path)
        assertTrue(image.width <= 300 && image.height <= 400)
        assertTrue(file.length() < before)
        assertEquals(100_000L, file.lastModified())
        val resized = file.readBytes()
        ThumbnailCache.shrink(file, 300, 400)
        assertArrayEquals("no repeated lossy recompression", resized, file.readBytes())
        image.recycle()
    }

    @Test fun smallPngBecomesJpegWithoutUpscaling() {
        val file = File(Files.createTempDirectory("thumb").toFile(), "cover.jpg")
        val source = Bitmap.createBitmap(40, 60, Bitmap.Config.ARGB_8888)
        file.outputStream().use { source.compress(Bitmap.CompressFormat.PNG, 100, it) }
        source.recycle()
        ThumbnailCache.shrink(file, 300, 400)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        file.inputStream().use { assertEquals(0xff, it.read()); assertEquals(0xd8, it.read()) }
        assertEquals(40, bounds.outWidth)
        assertEquals(60, bounds.outHeight)
    }
}
