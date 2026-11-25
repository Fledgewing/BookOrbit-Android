package net.fledgewing.orbitcompanion

import org.json.JSONTokener
import org.junit.Assert.*
import org.junit.Test

class MirrorJsonTest {
    @Test fun tokenParsingMatchesLegacyModelsIncludingUnicodeNullsAndNumbers() {
        val values = listOf("{}", "[]", "null", "42", "1.25", "true",
            """{"title":"Café 🌙","items":[null,{},[],{"id":2,"n":null}],"escaped":"a\nb\"c","fraction":1.25,"exp":1e3}""")
        for (json in values) assertArrayEquals(json, LuaValue.encode(LuaValue.fromJsonValue(JSONTokener(json).nextValue())), LuaValue.encode(LuaValue.fromJson(json)))
        val ascii = "reused model string"
        assertSame(ascii, LuaValue.str(ascii))
    }

    @Test fun incompleteAndDeepRepliesAreRejected() {
        for (json in listOf("{", "[", "{\"a\":}", "[] trailing", "[".repeat(50) + "]".repeat(50))) {
            try { LuaValue.fromJson(json); fail("accepted malformed reply") } catch (_: Exception) { }
        }
    }
}
