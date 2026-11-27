package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test

class LiteralValueTest {
    @Test fun boundedNestingRoundTrips() {
        val text = "{".repeat(40) + "1" + "}".repeat(40)
        assertNotNull(LuaValue.parse(text.toByteArray()))
        assertArrayEquals(text.toByteArray(), LuaValue.encode(LuaValue.parse(text.toByteArray())))
    }
    @Test fun largerNestingReturnsNoValue() {
        for (count in listOf(41, 10000)) {
            assertNull(LuaValue.parse(("{".repeat(count) + "1" + "}".repeat(count)).toByteArray()))
            assertNull(LuaValue.parse(("{[".repeat(count) + "1" + "]=1}".repeat(count)).toByteArray()))
        }
    }
}
