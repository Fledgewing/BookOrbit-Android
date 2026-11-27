// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

/** Selection only, on the companion. Contextual series order never wraps or chooses another series. */
object SeriesDownloadPlan {
    data class Selection(val books:List<Map<String,Any?>>,val earlier:Map<String,Any?>?,val anchor:String?)
    private val order=LibraryFilter.comparator(mapOf("sort" to "series","dir" to "asc"))
    private val recent=LibraryFilter.comparator(mapOf("sort" to "last","dir" to "asc"))
    fun select(books:List<Map<String,Any?>>,count:Int=3,currentKey:String?=null,startKey:String?=null,active:Set<String> = emptySet()):Selection {
        require(count in 1..10)
        val sorted=books.sortedWith(order)
        val reading=sorted.filter { SeriesPresentation.state(it)=="reading" }.maxWithOrNull(recent)
        val current=sorted.indexOfFirst { it["key"]==currentKey && currentKey!=null }
        val anchor=when {
            startKey!=null -> sorted.indexOfFirst { it["key"]==startKey }.also { require(it>=0) }-1
            current>=0 -> current
            reading!=null -> sorted.indexOf(reading)
            else -> sorted.indexOfLast { SeriesPresentation.state(it)=="read" }
        }
        fun eligible(book:Map<String,Any?>)=book["status"]=="unread" && book["on_device"]==false && book["key"] !in active
        val next=sorted.drop(anchor+1).filter(::eligible).take(count)
        val earlier=if(startKey==null) sorted.take(anchor.coerceAtLeast(0)).firstOrNull(::eligible) else null
        return Selection(next,earlier,sorted.getOrNull(anchor)?.get("key") as? String)
    }
}
