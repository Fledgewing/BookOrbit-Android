// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit
import net.fledgewing.orbitcompanion.*

/** Saved server selection only, never a local recommendation algorithm or full series index. */
internal object UpNextSelection {
    fun window(store:CacheStore,owner:String,args:Map<*,*>,now:Long):Map<String,Any?> {
        val saved=store.db().query("SELECT body,fetched_at,stale FROM entries WHERE path=? ORDER BY fetched_at DESC LIMIT 1","/koreader/plugin/catalog/dashboard/sections/up-next-in-series") {
            Triple(it.bytes(0)?.let(LuaValue::parse) as? Map<*,*>,it.long(1),it.text(2))
        }.firstOrNull()
        val section=saved?.first?.get("section") as? Map<*,*>
        val books=(section?.get("books") as? List<*>)?.takeIf { section["type"]=="up-next-in-series" }
        val paths=BookOrbitLibrary.localPaths(store,owner)
        val overrides=CatalogWorkflow.statusOverrides(store,owner)
        val rows=books.orEmpty().take(12).mapIndexedNotNull { rank,value ->
            val b=value as? Map<*,*> ?: return@mapIndexedNotNull null
            val id=(b["id"] as? Number)?.toLong()?.takeIf { it>0 } ?: return@mapIndexedNotNull null
            val status=overrides[id]
            BookOrbitLibrary.summary(owner,if(status==null) b else b+mapOf("readStatus" to status.status),rank.toLong(),paths?.containsKey(id))+
                mapOf("local_path" to paths?.get(id),"status_note" to "Not synced".takeIf { status?.pending==true })
        }.distinctBy { it["key"] }
        val query=args["query"] as? Map<*,*> ?: emptyMap<Any,Any>();LibraryFilter.validate(query)
        val selected=rows.filter { LibraryFilter.matches(it,query) }.sortedWith(LibraryFilter.comparator(query))
        val offset=((args["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0);val limit=((args["limit"] as? Number)?.toInt() ?: 12).coerceIn(1,24)
        val fresh=mapOf("saved" to (books!=null),"origin" to "cached-remote","at" to saved?.second,"stale" to (saved?.third!=null))
        if(args["op"]=="groups") return SeriesPresentation.groups(selected,query,offset,limit,
            ((args["preview"] as? Number)?.toInt() ?: 3).coerceIn(1,9),((args["group_limit"] as? Number)?.toInt() ?: 3).coerceIn(1,6))+
            mapOf("context" to mapOf("coverage" to LuaValue.str("Saved selection · ${rows.size} books")),"freshness" to fresh)
        if(args["op"]=="facets") {
            val facet=LibraryFacets(args["field"].toString(),query.entries.associate { it.key.toString() to it.value },now)
            rows.forEach { facet.include(it) }
            return facet.page(offset,limit)+mapOf("total" to selected.size,"freshness" to fresh)
        }
        val page=selected.drop(offset).take(limit)
        return mapOf("items" to page,"total" to selected.size.takeIf { books!=null },"next" to (offset+page.size).takeIf { it<selected.size },
            "context" to mapOf("title" to "Up next in series","coverage" to LuaValue.str("Saved selection · ${rows.size} books")),"freshness" to fresh)
    }
}
