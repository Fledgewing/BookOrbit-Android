package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.StringReader
import java.net.URI

/** OPDS is parsed only on the companion worker, bounded before display rows are published. */
object OpdsCatalog {
    class Book(val title: String, val authors: List<String>, val href: String, val format: String)
    class Page(val items: List<Book>, val hasNext: Boolean)
    fun parse(xml: String, server: String, limit: Int): Page {
        require(xml.toByteArray(Charsets.UTF_8).size <= 1048576 && limit in 1..24)
        val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setInput(StringReader(xml))
        val books = mutableListOf<Book>()
        var title = ""; var authors = mutableListOf<String>(); var href: String? = null; var format = ""
        var entryDepth = 0; var authorDepth = 0; var hasNext = false
        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            require(parser.depth <= 24)
            when (parser.eventType) {
                XmlPullParser.DOCDECL -> throw IllegalArgumentException("OPDS document declaration")
                XmlPullParser.START_TAG -> when (parser.name) {
                    "entry" -> { require(entryDepth == 0 && books.size < limit); entryDepth = parser.depth; title = ""; authors = mutableListOf(); href = null; format = "" }
                    "author" -> if (entryDepth > 0) authorDepth = parser.depth
                    "title" -> if (entryDepth > 0) title = parser.nextText().take(256)
                    "name" -> if (entryDepth > 0 && authorDepth > 0 && authors.size < 8) authors.add(parser.nextText().take(128))
                    "link" -> {
                        val rel = parser.getAttributeValue(null, "rel").orEmpty()
                        if (entryDepth == 0 && rel == "next") hasNext = true
                        if (entryDepth > 0 && rel.startsWith("http://opds-spec.org/acquisition")) {
                            val raw = parser.getAttributeValue(null, "href") ?: throw IllegalArgumentException("OPDS link")
                            href = safePath(server, raw)
                            format = parser.getAttributeValue(null,"type").orEmpty().take(100)
                        }
                    }
                }
                XmlPullParser.END_TAG -> {
                    if (parser.depth == authorDepth) authorDepth = 0
                    if (parser.depth == entryDepth && parser.name == "entry") {
                        href?.let { books.add(Book(title, authors.toList(), it, format)) }; entryDepth = 0
                    }
                }
            }
            parser.nextToken()
        }
        return Page(books, hasNext)
    }
    fun safePath(server: String, link: String): String {
        val base = URI(server + "/")
        val uri = base.resolve(link).normalize()
        require(uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port && uri.userInfo == null && uri.fragment == null)
        val prefix = base.path.trimEnd('/')
        require(uri.path.startsWith("$prefix/opds/") && !uri.rawPath.contains('%'))
        val path = uri.rawPath.removePrefix(prefix)
        require(path.matches(Regex("/opds/[0-9]+/download")))
        return path + (uri.rawQuery?.let { "?$it" } ?: "")
    }
}
