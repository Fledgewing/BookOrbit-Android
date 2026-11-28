// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test

class RecommendationPlanTest {
    private val items=listOf(mapOf("id" to "local","kind" to "ko","key" to "action","ours" to "turn_on","stock" to "prompt","label" to "Wi-Fi action"),
        mapOf("id" to "gesture","kind" to "gesture","key" to "tap","ours" to mapOf("sync" to true),"label" to "Tap"))
    private fun obs(value:Any?=null,default:Any?=null,available:Boolean=true)=mapOf("available" to available,"current" to value,"default" to default)
    private fun plan(observations:Map<String,Any?>,record:Any?=null,backup:Any?=null,choices:Any?=null,lost:Boolean=false)=
        RecommendationPlan.evaluate(items,mapOf("observations" to observations,"record" to record,"backup" to backup,"choices" to choices,"lost" to lost))
    @Test fun defaultsAreAppliedWithBackupAndCustomValuesBecomeConflicts() {
        val result=plan(mapOf("local" to obs("prompt"),"gesture" to obs(mapOf("other" to true))))
        assertEquals(1,(result["writes"] as List<*>).size)
        val states=(result["record"] as Map<*,*>)["items"] as Map<*,*>
        assertEquals("applied",states["local"]);assertEquals("conflict",states["gesture"])
        assertEquals("prompt",((result["backup"] as Map<*,*>)["local"] as Map<*,*>)["prior"])
    }
    @Test fun laterPassDoesNotResetUserChanges() {
        val first=plan(mapOf("local" to obs(),"gesture" to obs()))
        val second=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))),first["record"],first["backup"])
        assertTrue((second["writes"] as List<*>).isEmpty())
    }
    @Test fun missingSettingsWaitUntilTheirCapabilityReturns() {
        val first=plan(mapOf("local" to obs(available=false),"gesture" to obs(available=false)))
        val second=plan(mapOf("local" to obs(),"gesture" to obs()),first["record"],first["backup"])
        assertEquals(2,(second["writes"] as List<*>).size)
    }
    @Test fun explicitUseAndKeepHaveTheSameRulesInBothFrontends() {
        val first=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))))
        val second=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))),first["record"],first["backup"],mapOf("local" to "ours","gesture" to "mine"))
        assertEquals(1,(second["writes"] as List<*>).size)
        assertEquals("kept",((second["record"] as Map<*,*>)["items"] as Map<*,*>)["gesture"])
    }
    @Test fun bulkUseLeavesPreviouslyKeptItemsAloneButExplicitUseCanChangeThem() {
        val first=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))))
        val kept=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))),first["record"],first["backup"],mapOf("all" to "mine"))
        val bulk=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))),kept["record"],kept["backup"],mapOf("all" to "ours"))
        assertTrue((bulk["writes"] as List<*>).isEmpty())
        val explicit=plan(mapOf("local" to obs("ignore"),"gesture" to obs(mapOf("mine" to true))),kept["record"],kept["backup"],mapOf("local" to "ours"))
        assertEquals(1,(explicit["writes"] as List<*>).size)
    }
    @Test fun failedNativeWritesAreNotCountedAsAppliedDuringAcknowledgement() {
        val first=plan(mapOf("local" to obs(),"gesture" to obs()))
        val ack=RecommendationPlan.evaluate(items,mapOf("ack" to true,"failed" to listOf("local","gesture"),
            "record" to first["record"],"backup" to first["backup"]))
        assertEquals(0,((ack["record"] as Map<*,*>)["unseen"] as Number).toInt())
    }
    @Test fun undoRestoresOnlyWhileCurrentValueIsOurs() {
        val first=plan(mapOf("local" to obs("prompt"),"gesture" to obs()))
        val second=plan(mapOf("local" to obs("turn_on"),"gesture" to obs(mapOf("user" to true))),first["record"],first["backup"],mapOf("all" to "undo"))
        val writes=second["writes"] as List<*>
        assertEquals(1,writes.size);assertEquals("prompt",(writes[0] as Map<*,*>)["value"])
    }
    @Test fun losingCapabilityUndoesOnlyTheAppliedStillMatchingValue() {
        val first=plan(mapOf("local" to obs("prompt"),"gesture" to obs()))
        val second=plan(mapOf("local" to obs("turn_on",available=false),"gesture" to obs(mapOf("user" to true),available=false)),first["record"],first["backup"],lost=true)
        assertEquals(1,(second["writes"] as List<*>).size)
    }
    @Test fun snapshotAndDefinitionCountAreBounded() {
        val result=plan(mapOf("local" to obs(),"gesture" to obs()))
        assertTrue(LuaValue.encode(result).size<=16384)
        try { RecommendationPlan.evaluate(List(11){items[0]},emptyMap<Any,Any>());fail("missing budget") } catch(_:IllegalArgumentException) { }
    }
    @Test fun cleanMenusAreAutomaticOnlyForUntouchedReadersRegardlessOfDefinitionOrder() {
        val clean=mapOf("id" to "clean","kind" to "owned","key" to "clean_menus","ours" to true,"untouched_only" to true)
        for(defs in listOf(items+clean,listOf(clean)+items)) {
            val defaults=mapOf("local" to obs("prompt"),"gesture" to obs(),"clean" to obs())
            val fresh=RecommendationPlan.evaluate(defs,mapOf("observations" to defaults))
            assertTrue((fresh["writes"] as List<*>).any { (it as Map<*,*>)["id"]=="clean" && it["guard_untouched"]==true })
            val custom=RecommendationPlan.evaluate(defs,mapOf("observations" to defaults+mapOf("gesture" to obs(mapOf("custom" to true)))))
            assertFalse((custom["writes"] as List<*>).any { (it as Map<*,*>)["id"]=="clean" })
            assertEquals("conflict",((custom["record"] as Map<*,*>)["items"] as Map<*,*>)["clean"])
            val explicit=RecommendationPlan.evaluate(defs,mapOf("observations" to defaults,"record" to custom["record"],"backup" to custom["backup"],"choices" to mapOf("clean" to "ours")))
            assertTrue((explicit["writes"] as List<*>).any { (it as Map<*,*>)["id"]=="clean" && it["guard_untouched"]==false })
        }
    }
    @Test fun priorKeptSettingsAndExplicitMenuDisableAreNeverSilentlyOverwritten() {
        val defs=items+mapOf("id" to "clean","kind" to "owned","key" to "clean_menus","ours" to true,"untouched_only" to true)
        val values=mapOf("local" to obs("prompt"),"gesture" to obs(),"clean" to obs())
        val result=RecommendationPlan.evaluate(defs,mapOf("observations" to values,"record" to mapOf("items" to mapOf("gesture" to "kept"))))
        assertEquals("conflict",((result["record"] as Map<*,*>)["items"] as Map<*,*>)["clean"])
        val disabled=RecommendationPlan.evaluate(defs,mapOf("observations" to values+mapOf("clean" to obs(false))))
        assertFalse((disabled["writes"] as List<*>).any { (it as Map<*,*>)["id"]=="clean" })
    }

    @Test fun cleanMenuUndoRestoresUnsetAndIsNotReappliedOnTheNextPass() {
        val clean=listOf(mapOf("id" to "clean","kind" to "owned","key" to "clean_menus","ours" to true,"untouched_only" to true))
        val first=RecommendationPlan.evaluate(clean,mapOf("observations" to mapOf("clean" to obs())))
        val undone=RecommendationPlan.evaluate(clean,mapOf("observations" to mapOf("clean" to obs(true)),"record" to first["record"],"backup" to first["backup"],"choices" to mapOf("clean" to "undo")))
        val write=(undone["writes"] as List<*>).single() as Map<*,*>
        assertEquals(true,write["expected"]);assertNull(write["value"])
        val next=RecommendationPlan.evaluate(clean,mapOf("observations" to mapOf("clean" to obs()),"record" to undone["record"],"backup" to undone["backup"]))
        assertTrue((next["writes"] as List<*>).isEmpty())
    }

}
