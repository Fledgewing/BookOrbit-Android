package net.fledgewing.orbitcompanion

import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PositionPolicyTest {
    private val cases=JSONObject(File("../../../shared/fixtures/orbismart/cases.json").readText())
    @Test fun everySharedDecisionCase() {
        val rows=cases.getJSONArray("decide")
        for (n in 0 until rows.length()) {
            val row=rows.getJSONObject(n); val i=row.getJSONObject("in"); val want=row.getJSONObject("want")
            val marker=i.optJSONObject("marker")
            val input=PositionPolicy.Input(i.optDouble("local",0.0),if (i.has("server")&&!i.isNull("server")) i.getDouble("server") else null,
                i.optDouble("tolerance",1.0),i.optLong("server_at"),marker?.let { PositionPolicy.Marker(it.optLong("at"),it.optDouble("place")) },
                i.optLong("turn_at"),i.optBoolean("reset"),i.optBoolean("redated"),i.optBoolean("finished"),i.optBoolean("released"),
                i.optLong("declined_at"),i.optJSONObject("override")?.optLong("at"),i.optBoolean("percent_only"))
            val result=PositionPolicy.decide(input)
            assertEquals(row.getString("name"),want.getString("decision"),result.decision)
            assertEquals(row.getString("name"),want.getString("rule"),result.rule)
            assertEquals(row.getString("name"),want.optBoolean("dropped"),result.dropped)
        }
    }
    @Test fun everySharedPresentationAndBehindHoldCase() {
        val applied=cases.getJSONArray("apply")
        for (n in 0 until applied.length()) { val c=applied.getJSONObject(n)
            assertEquals(c.getString("applied"),PositionPolicy.apply(c.getString("decision"),c.getString("moment"))) }
        val push=cases.getJSONArray("push")
        for (n in 0 until push.length()) { val c=push.getJSONObject(n)
            assertEquals(c.getString("name"),c.getBoolean("allowed"),PositionPolicy.mayPush(c.optDouble("place"),
                if (c.isNull("server")) null else c.getDouble("server"),c.optDouble("tolerance",1.0),c.has("exempt"))) }
    }
}
