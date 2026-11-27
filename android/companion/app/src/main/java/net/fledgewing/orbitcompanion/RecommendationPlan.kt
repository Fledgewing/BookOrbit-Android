// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

/** Eight local settings, never a catalog. The connector supplies its native binding descriptors;
 * observations and compare-before-write acknowledgements stay behind Library on the reader. */
object RecommendationPlan {
    fun evaluate(definitions:List<Map<String,Any?>>,args:Map<*,*>):Map<String,Any?> {
        require(definitions.size<=8)
        val record=(args["record"] as? Map<*,*>).orEmpty()
        val prior=(record["items"] as? Map<*,*>).orEmpty().toMutableMap()
        val backup=(args["backup"] as? Map<*,*>).orEmpty().toMutableMap()
        val observed=(args["observations"] as? Map<*,*>).orEmpty()
        val choices=(args["choices"] as? Map<*,*>).orEmpty()
        val failed=(args["failed"] as? List<*>).orEmpty()
        val writes=mutableListOf<Map<String,Any?>>()
        val rows=definitions.map { item ->
            val id=item["id"] as String
            val obs=(observed[id] as? Map<*,*>).orEmpty()
            val current=obs["current"];val ours=item["ours"]
            val status=prior[id]
            var next=status
            val choice=choices[id] ?: choices["all"].takeUnless { it=="ours" && status=="kept" || it=="undo" && item["required_by"]=="wifi" && args["wifi"]==true }
            val available=obs["available"]==true
            fun apply() {
                backup[id]=mapOf("had" to obs.containsKey("current"),"prior" to current,"ours" to ours)
                writes.add(mapOf("id" to id,"expected" to current,"value" to ours));next="applied"
            }
            if(choice=="mine" && status=="conflict") next="kept"
            else if(choice=="undo" && status=="applied" || args["lost"]==true && !available && status=="applied") {
                val saved=backup[id] as? Map<*,*>
                if(saved!=null && current==saved["ours"]) writes.add(mapOf("id" to id,"expected" to current,"value" to saved["prior"]))
                backup.remove(id);next=if(args["lost"]==true) "unavailable" else "kept"
            } else if(available && choice=="ours" && status in setOf("kept","conflict")) apply()
            else if(args["ack"]!=true && (status==null || status=="unavailable")) {
                next=when {
                    !available -> "unavailable"
                    current==ours -> if(backup[id]!=null) "applied" else "already"
                    current==obs["default"] || item["stock"]!=null && current==item["stock"] -> "applied"
                    else -> "conflict"
                }
                if(next=="applied" && current!=ours) apply()
            }
            if(id in failed) next="unavailable"
            prior[id]=next
            item+mapOf("state" to next,"section" to when(next) { "conflict" -> "To review";"applied","already" -> "Applied";"kept" -> "Kept yours";else -> "Unavailable" },
                "needs_wifi" to (item["required_by"]=="wifi" && args["wifi"]==true),"yours" to label(item,current),"orbit" to label(item,ours),
                "was" to label(item,(backup[id] as? Map<*,*>)?.get("prior")),"reason" to obs["reason"])
        }
        val conflicts=prior.values.count { it=="conflict" }
        val applied=writes.count { w -> prior[w["id"]]=="applied" }
        val unseen=((record["unseen"] as? Number)?.toInt().orZero()+applied-(if(args["ack"]==true) failed.toSet().size else 0)).coerceAtLeast(0)
        val line=when { unseen>0 && conflicts>0 -> "Applied $unseen · $conflicts to review"; unseen>0 -> "Applied $unseen recommended settings · Review"; conflicts>0 -> "Review $conflicts recommended settings";else -> null }
        val ordered=rows.sortedBy { when(it["state"]) { "conflict" -> 0;"applied" -> 1;"already" -> 2;"kept" -> 3;else -> 4 } }
        val result=mapOf("items" to ordered,"use_all" to (conflicts>0),"undo_all" to prior.values.any { it=="applied" },"writes" to writes,"record" to mapOf("rev" to 1,"items" to prior,"unseen" to unseen),"backup" to backup,
            "conflicts" to conflicts,"seen_line" to (if(conflicts>0) LuaValue.str("Review $conflicts recommended settings") else null),"line" to line?.let(LuaValue::str),"report" to if(conflicts>0) "partial" else if("kept" in prior.values) "reviewed" else "applied")
        require(LuaValue.encode(result).size<=16384);return result
    }
    private fun Int?.orZero()=this ?: 0
    private fun label(item:Map<String,Any?>,v:Any?):String {
        val labels=(item["value_labels"] as? Map<*,*>).orEmpty()
        return when(v) {
            null -> "Unset"
            true -> "On"
            false -> "Off"
            is Map<*,*> -> if(v.isEmpty()) "Nothing" else v.keys.map { labels[it] as? String ?: "Custom action" }.sorted().joinToString(" + ")
            else -> labels[v.toString()] as? String ?: v.toString()
        }.take(200)
    }
}
