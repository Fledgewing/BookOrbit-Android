package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class SyncProvisionTest {
    companion object {
        fun archive(user: String = "fixture", key: String = "b".repeat(32), suffix: String = ""): ByteArray {
            val out = ByteArrayOutputStream()
            fun quote(s: String) = "\"" + s.replace("\\","\\\\").replace("\"","\\\"").replace("\r","\\r").replace("\n","\\n") + "\""
            ZipOutputStream(out).use { zip ->
                zip.putNextEntry(ZipEntry("bookorbit.koplugin/main.lua")); zip.write("error('never execute')".toByteArray()); zip.closeEntry()
                zip.putNextEntry(ZipEntry("bookorbit.koplugin/bookorbit_provision.lua"))
                zip.write(("-- Fixture data\nreturn {\n username = ${quote(user)},\n userkey = ${quote(key)},\n}\n"+suffix).toByteArray(Charsets.UTF_8)); zip.closeEntry()
            }
            return out.toByteArray()
        }
    }
    @Test fun readsOnlyMatchingConnectionDataWithoutExecutingArchiveContents() {
        val user = "fixture\"位置"
        val bytes = archive(user,"B".repeat(32),"error('also never execute')")
        assertEquals("b".repeat(32),SyncProvision.key(bytes,LuaValue.str(user)))
        assertNull(SyncProvision.key(bytes,"other"))
        assertNull(SyncProvision.key(archive(key="invalid"),"fixture"))
    }
    @Test fun malformedAndOversizedInputsFailClosed() {
        assertNull(SyncProvision.key("not a zip".toByteArray(),"fixture"))
        assertNull(SyncProvision.key(ByteArray(SyncProvision.MAX_COMPRESSED+1),"fixture"))
        assertNull(SyncProvision.key(archive(suffix="x".repeat(8193)),"fixture"))
    }
}
