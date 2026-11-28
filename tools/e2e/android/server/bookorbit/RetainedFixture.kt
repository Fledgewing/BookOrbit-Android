// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.io.File
import java.time.LocalDate

/** Disposable build only: real cached connector projections, zero HTTP. */
internal object RetainedFixture {
    private fun <T> cached(root:File,owner:String,block:(CacheStore)->T):T = CacheStore(File(root,"retained-fixture"),log={}).use { store ->
        store.own(owner)
        val year=LocalDate.now().year
        if(store.meta("fixture_year")!=year.toString()) {
            fun books(y:Int)= (1..12).map { mapOf("id" to it.toLong(),"title" to "Retained book $it","authors" to listOf("Fixture"),"readStatus" to "read","finishedOn" to "$y-06-01","seriesId" to 7L,"seriesName" to "Fixture series") }
            for(y in listOf(year-1,year)) store.putEntry("dashboard","/koreader/plugin/catalog/dashboard",mapOf("readingGoal" to mapOf("year" to y,"completedBooks" to 100L),"finishedThisYear" to books(y),
                "achievements" to mapOf("earned" to 3L,"total" to 20L,"latest" to mapOf("name" to "Saved milestone","awardedAt" to "$y-06-01T00:00:00Z"),"next" to mapOf("name" to "Next milestone","threshold" to 10L,"currentProgress" to 7L))),100L+y)
            store.putEntry("next","/koreader/plugin/catalog/dashboard/sections/up-next-in-series",mapOf("section" to mapOf("type" to "up-next-in-series","books" to listOf(books(year)[8],books(year)[1],books(year)[4]))),200L+year)
            store.setMeta("fixture_year",year)
        }
        block(store)
    }
    fun options(root:File,owner:String):List<Any> = cached(root,owner) { store ->
        val current=LocalDate.now().year
        listOf(mapOf("src" to "upnext","title" to "Up next in series","count" to 3L,"default_sort" to 0)) + listOf(current,current-1).map { y -> mapOf("src" to "year:$y","title" to "Finished in $y","count" to 100L,"default_sort" to 0) }
    }
    fun handles(request:Map<*,*>) = (request["source"] as? Map<*,*>)?.get("kind")=="finished-year" || request["source"]=="series-next" || request["op"]=="account.badges"
    fun project(root:File,owner:String,request:Map<*,*>):Map<String,Any?> = cached(root,owner) { BookOrbitProjection(it).project(owner,request) }
}
