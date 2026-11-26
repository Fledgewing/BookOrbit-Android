package net.fledgewing.orbitcompanion.server.bookorbit

import java.net.URLEncoder
import java.net.URLDecoder

object CoverProtocol {
    /** "https://h/", "https://h/api/v1", "https://h/api/v1/koreader" -> "https://h/api/v1" (as the BookOrbit plugin normalises). */
    fun apiBase(server: String): String? {
        val s = server.trim().trimEnd('/')
        if (!Regex("^https?://[^/?#]+.*$").matches(s)) return null
        val base = s.removeSuffix("/koreader") // orbify:not-a-route: a base-URL suffix the plugin may keep, not a call
        return if (base.endsWith("/api/v1")) base else "$base/api/v1"
    }

    /** A small acquisition feed: recent books, enough that one of them has a cover. */
    fun feedUrl(base: String): String = "$base/opds/recent?page=1&size=20"

    fun coverUrl(base: String, id: Long, token: String): String =
        "$base/opds/$id/cover?t=${URLEncoder.encode(token, "UTF-8")}"

    /** The token's shape at the pin: `<userId>.<32 hex>` (createCoverToken). */
    private val TOKEN = Regex("^\\d+\\.[0-9a-fA-F]{16,128}$")
    // orbify:not-a-route: a pattern for the feed's image links; the cover route is called in coverUrl.
    private val IMAGE_LINK = Regex("""/opds/\d+/(?:cover|thumbnail)\?t=([^"'&<\s]+)""") // orbify:not-a-route

    /** The cover token from a feed's image links (B opds.service.ts:205), or null. */
    fun tokenFromFeed(xml: String): String? = IMAGE_LINK.findAll(xml).map { m ->
        runCatching { URLDecoder.decode(m.groupValues[1], "UTF-8") }.getOrNull()
    }.firstOrNull { it != null && TOKEN.matches(it) }

}
