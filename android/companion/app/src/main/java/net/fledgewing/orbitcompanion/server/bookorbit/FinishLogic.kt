// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File

/** Worker-only finish decisions; sheets receive two preselected display cards, never catalogs. */
internal object FinishLogic {
    fun sendStatus(seen:Any?,remote:Any?) = remote!="read" && !(remote in setOf("rereading","on_hold","abandoned") && remote!=seen)
    private fun number(v:Any?)=(v as? Number)?.toDouble() ?: (v as? String)?.toDoubleOrNull()
    private fun fmt(n:Double)=if(n==n.toLong().toDouble()) n.toLong().toString() else n.toString()
    fun snapshot(store:CacheStore,owner:String,args:Map<*,*>):Map<String,Any?> {
        val path=args["path"] as? String
        val entry=BookOrbitLibrary.localEntries(store,owner)?.firstOrNull { it["path"]==path }
        val id=BookOrbitLibrary.id(owner,"book",args["key"]) ?: (entry?.get("book_id") as? Number)?.toLong()
        val d=id?.let { (store.detail(it)?.first ?: store.bookItem(it)) as? Map<*,*> }.orEmpty()
        val state=CatalogWorkflow.load(File(store.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
        val hash=args["document"] as? String ?: entry?.get("md5")
        val job=(state["finishes"] as? Map<*,*>)?.get(hash) as? Map<*,*>
        val paths=BookOrbitLibrary.localPaths(store,owner).orEmpty()
        fun card(b:Map<*,*>,line:String):Map<String,Any?> {
            val bid=(b["id"] as? Number)?.toLong()
            return mapOf("line" to LuaValue.str(line),"title" to (b["title"] as? String)?.let { LuaValue.boundedText(LuaValue.utf8(it),160) },"book_id" to bid?.let { BookOrbitLibrary.key(owner,"book",it) },
                "book" to mapOf("cover_path" to bid?.let { store.meta("cover_file_$it") }?.takeIf { File(LuaValue.utf8(it)).isFile }),
                "local_path" to paths[bid],"action" to if(paths[bid]!=null) "open" else "download")
        }
        val members=(d["seriesMembers"] as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }
        val index=number(d["seriesIndex"])
        var next:Map<String,Any?>?=null
        var nextId:Any?=null
        if(d["seriesId"]!=null && index!=null) {
            val sorted=members.filter { it["id"]!=id && number(it["seriesIndex"])!=null }
                .sortedWith(compareBy<Map<*,*>> { number(it["seriesIndex"]) }.thenBy { (it["id"] as? Number)?.toLong() })
            val after=sorted.firstOrNull { number(it["seriesIndex"])!!>index }
            if(after!=null) {
                val n=number(after["seriesIndex"])!!;val whole=kotlin.math.floor(index)+1
                next=if(n>whole) mapOf("line" to LuaValue.str("Book ${fmt(whole)} isn't in your library")) else {
                    nextId=after["id"];card(after,"Next in series · Book ${fmt(n)}"+(if(after["readStatus"]=="read") " · Read" else ""))
                }
            } else {
                val unread=sorted.firstOrNull { it["readStatus"]!="read" }
                next=if(unread==null) mapOf("line" to LuaValue.str("You've finished the series")) else {
                    nextId=unread["id"];card(unread,"Last book · not read yet: Book ${fmt(number(unread["seriesIndex"])!!)}")
                }
            }
        }
        val read=members.filter { it["readStatus"]=="read" }.map { it["id"] }.toSet()
        val related=(d["relatedSections"] as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }.associateBy { it["id"] }
        val author=(d["authors"] as? List<*>)?.firstOrNull() as? String
        var suggestion:Map<String,Any?>?=null
        for(source in listOf("author","similar")) {
            val selected=(related[source]?.get("books") as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }
                .firstOrNull { it["id"]!=id && it["id"]!=nextId && it["id"] !in read && it["readStatus"]!="read" } ?: continue
            suggestion=card(selected,if(source=="author" && author!=null) "Also by ${LuaValue.utf8(author)}" else "You might like");break
        }
        val title=d["title"] ?: path?.substringAfterLast('/') ?: ""
        return mapOf("key" to id?.let { BookOrbitLibrary.key(owner,"book",it) },"title" to LuaValue.boundedText(LuaValue.utf8(title.toString()),256),"author" to author?.let { LuaValue.boundedText(LuaValue.utf8(it),80) },
            "stars" to (job?.get("rating") ?: args["rating"]).takeIf { it!="clear" },"undo" to (job!=null),"can_mark" to (job==null),
            "status" to LuaValue.str(if(job!=null) "✓ Marked as finished" else "Not marked as finished"),
            "next" to next,"suggestion" to suggestion,"row_count" to (1+(if(next?.get("book_id")!=null) 1 else 0)+(if(suggestion!=null) 1 else 0)),
            "freshness" to mapOf("saved" to d.isNotEmpty()))
    }
}
