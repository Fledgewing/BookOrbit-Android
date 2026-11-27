// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test

class RetirementPlanTest {
    @Test fun bootstrapIsOneSmallStaticRowWithoutCredentialsOrCatalogData() {
        val plan=ConnectorPlugin.retirementPlan()
        assertEquals(1,plan["row_count"])
        assertTrue(LuaValue.encode(plan).size<=16384)
        assertEquals(setOf("plugins","modules","settings_key","home_key","row_count","actions"),plan.keys)
        assertEquals(listOf("bookorbit"),plan["plugins"])
        assertEquals(listOf("bookorbit_api"),plan["modules"])
        assertEquals(2,(plan["actions"] as List<*>).size)
    }
}
