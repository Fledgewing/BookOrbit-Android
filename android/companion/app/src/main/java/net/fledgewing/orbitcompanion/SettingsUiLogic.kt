package net.fledgewing.orbitcompanion

import org.json.JSONObject
import java.util.Locale

/**
 * The Settings pages' pure parts (docs/design/companion-settings.md §5, §6): the companion-only
 * rows each section holds, search, the plugin's lists for the sleep-screen picker and the
 * Recommended settings review list. Tested on the JVM; the pages draw them (SettingsPages.kt).
 */
object SettingsUi {
    /**
     * A row the companion draws that is not a shared key: its id (stable; the page draws it by id),
     * its section, where it goes ([before]: drawn before that schema key; null: after the shared
     * rows), and the words search matches.
     */
    data class Extra(val id: String, val section: String, val label: String, val before: String? = null, val words: List<String> = emptyList(), val action: Boolean = false)

    /** Every companion row, by section (§3.4, §5.1; the launcher page's moved choices, §5.9). */
    val EXTRAS = listOf(
        Extra("home_opens", "reading", "Home opens", before = "home_button", words = listOf("launcher", "home app")),
        Extra("shown_by", "sleep", "Shown by", words = listOf("screen saver", "screensaver")),
        // Drawn by its slot (SharpCoversRow); listed here so search finds it.
        Extra("sharp_covers", "sleep", SharpCoversLogic.TITLE, words = listOf("opds", "full size", "sign in", "cover")),
        Extra("preview", "sleep", "Preview", words = listOf("screensaver")),
        Extra("helper_wifi", "sync", "Wi-Fi switching", before = "wifi_mode", words = listOf("helper", "wifi")),
        Extra("wifi_after_sleep", "sync", "Wi-Fi after sleep sync", words = listOf("wifi", "nap")),
        Extra("helper_sleep_sync", "sync", "Sleep sync", before = "sync_on_sleep", words = listOf("helper")),
        Extra("screen_off", "sync", "Screen off after Sync and sleep", before = "sync_on_sleep", words = listOf("helper", "lock")),
        Extra("wake_lock", "sync", "Keep the reader awake while syncing", words = listOf("wake lock")),
        Extra("notify_tailscale", "sync", "Tailscale alert", words = listOf("notify", "vpn")),
        Extra("do_sync_sleep", "sync", "Sync and sleep now", action = true),
        Extra("do_test_sync_path", "sync", "Test the sync path", action = true, words = listOf("network")),
        Extra("do_test_network", "sync", "Test network", action = true, words = listOf("wifi", "tailscale")),
        Extra("do_full_refresh", "library", "Full refresh now", action = true, words = listOf("offline", "mirror")),
        Extra("helper_clicker", "buttons", "Clicker buttons helper", words = listOf("helper", "bluetooth")),
        Extra("clickers", "buttons", "Clicker buttons", words = listOf("bluetooth", "page turn", "remote")),
        Extra("helper_pin", "kids", "Settings PIN helper", words = listOf("helper")),
        Extra("pin", "kids", "Settings PIN", words = listOf("kid", "lock", "child", "password")),
        Extra("guarded", "kids", "Guarded apps", words = listOf("kid", "lock")),
        Extra("setup", "setup", "Setup", words = listOf("checklist")),
        Extra("mode", "setup", "Mode", words = listOf("full", "add-on", "addon")),
        Extra("recommended", "setup", "Recommended settings", words = listOf("review", "koreader")),
        Extra("skipped", "setup", "Skipped setup steps"),
        Extra("app_version", "updates", "App version", before = "auto_update_patch", words = listOf("update", "check")),
        Extra("debug_log", "updates", "Debug log", words = listOf("logcat")),
        Extra("details", "updates", "Details", words = listOf("support", "version")),
        Extra("licenses", "updates", "Open-source licenses"),
    )

    fun extras(section: String): List<Extra> = EXTRAS.filter { it.section == section }

    /** A search hit: a shared key or an extra's id, its section, and the parent to open instead when it is hidden. */
    data class Hit(val id: String, val section: String, val label: String, val shared: Boolean)

    /**
     * Matches labels, lines, value labels and search words, case-insensitively; every word of the
     * query must match. Hidden (internal) keys never show. Results in section order.
     */
    fun search(schema: SettingsSchema, query: String, extras: List<Extra> = EXTRAS): List<Hit> {
        val words = query.lowercase(Locale.ROOT).split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return emptyList()
        fun matches(hay: String) = words.all { hay.contains(it) }
        val shared = schema.settings.filter { !it.hidden }.filter { d ->
            matches(listOf(d.label, d.line, d.key.replace('_', ' '), d.values.joinToString(" ") { it.second }, d.search.joinToString(" "), schema.section(d.section)?.title.orEmpty())
                .joinToString(" ").lowercase(Locale.ROOT))
        }.map { Hit(it.key, it.section, it.label, true) }
        val own = extras.filter { e -> matches((listOf(e.label, schema.section(e.section)?.title.orEmpty()) + e.words).joinToString(" ").lowercase(Locale.ROOT)) }
            .map { Hit(it.id, it.section, it.label, false) }
        val order = schema.sections.map { it.id }
        return (shared + own).sortedBy { order.indexOf(it.section) }
    }

    /** "Shown when Sleep screen is Recommended cover": why a hidden row's parent must change first. */
    fun shownWhen(schema: SettingsSchema, key: String): String? {
        val d = schema.byKey[key] ?: return null
        val p = schema.byKey[d.parentKey ?: return null] ?: return null
        val words = when {
            d.parentIs != null -> d.parentIs.joinToString(" or ") { label(p, it) }
            d.parentNot != null -> "not " + d.parentNot.joinToString(" or ") { label(p, it) }
            else -> return null
        }
        return "Shown when ${p.label} is $words"
    }

    private fun label(d: SettingDef, wire: String): String = if (d.type == "bool") (if (wire == "1") "on" else "off") else d.valueLabel(wire)

    /** The value as the row shows it, in words. */
    fun valueLabel(d: SettingDef, wire: String, choices: SleepChoices? = null): String = when (d.type) {
        "bool" -> if (wire == "1") "On" else "Off"
        "rules" -> wire.split('\n').count { it.isNotBlank() }.let { if (it == 0) "None" else if (it == 1) "1 rule" else "$it rules" }
        "text" -> wire.ifEmpty { "None" }
        "source" -> d.values.firstOrNull { it.first == wire }?.second ?: choices?.title(wire) ?: SleepChoices.fallback(wire)
        else -> d.valueLabel(wire)
    }

    /** The review page's choices: [current] ("id=what;…") with [id] set to [what]; one entry per id. */
    fun withChoice(current: String, id: String, what: String): String {
        val kept = current.split(';').map { it.trim() }.filter { it.isNotEmpty() && it.substringBefore('=') != id && !(id == "all") }
        return (kept + "$id=$what").joinToString(";")
    }

    /** The choice queued for [id], or null. */
    fun choiceFor(current: String, id: String): String? =
        current.split(';').map { it.trim() }.lastOrNull { it.substringBefore('=') == id || it.substringBefore('=') == "all" }?.substringAfter('=')
}

/** The plugin's choices.json (android/docs/INTERFACE.md "Sleep screen"): lists for the picker and the tag list. */
data class SleepChoices(
    val at: Long,
    val cached: Boolean,
    val scopes: List<Item>,
    val collections: List<Item>,
    val tags: List<Tag>,
) {
    data class Item(val id: Long, val title: String, val count: Int?)
    data class Tag(val tag: String, val label: String, val count: Int)

    /** "Romance (smart scope)" for scope:4; null when the plugin's lists don't have it. */
    fun title(wire: String): String? {
        val id = wire.substringAfter(':').toLongOrNull() ?: return null
        return when (wire.substringBefore(':')) {
            "scope" -> scopes.firstOrNull { it.id == id }?.let { "${it.title} (smart scope)" }
            "collection" -> collections.firstOrNull { it.id == id }?.let { "${it.title} (collection)" }
            else -> null
        }
    }

    /** A leave-out rule in words. */
    fun ruleLabel(rule: String): String = if (rule.startsWith("tag:")) "Tag: ${rule.removePrefix("tag:")}" else title(rule) ?: fallback(rule)

    companion object {
        const val FILE = "choices.json"

        /** "Scope not found" (X7) when an id is not in the lists. */
        fun fallback(wire: String): String = when (wire.substringBefore(':')) {
            "scope" -> "Smart scope ${wire.substringAfter(':')} (not found)"
            "collection" -> "Collection ${wire.substringAfter(':')} (not found)"
            "tag" -> "Tag: ${wire.substringAfter(':')}"
            else -> wire
        }

        fun parse(text: String?): SleepChoices? {
            if (text.isNullOrBlank()) return null
            val o = runCatching { JSONObject(text) }.getOrNull() ?: return null
            fun items(name: String): List<Item> = o.optJSONArray(name)?.let { a ->
                (0 until a.length()).mapNotNull { a.optJSONObject(it) }.mapNotNull { j ->
                    val id = j.optLong("id", 0L).takeIf { it > 0 } ?: return@mapNotNull null
                    Item(id, j.optString("title").ifEmpty { "#$id" }, if (j.has("count")) j.optInt("count") else null)
                }
            }.orEmpty()
            val tags = o.optJSONArray("tags")?.let { a ->
                (0 until a.length()).mapNotNull { a.optJSONObject(it) }.mapNotNull { j ->
                    val t = j.optString("tag").trim().lowercase(Locale.ROOT).takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    Tag(t, j.optString("label").ifEmpty { t }, j.optInt("count", 0))
                }
            }.orEmpty().sortedByDescending { it.count }
            return SleepChoices(o.optLong("at", 0L), o.optBoolean("cached", false), items("scopes"), items("collections"), tags)
        }
    }
}

/** orbit-recommended.json: the plugin's Recommended settings review list (§5.8). */
data class RecommendedReview(val at: Long, val items: List<Item>) {
    data class Item(val id: String, val label: String, val state: String, val yours: String, val orbit: String, val was: String, val reason: String) {
        /** What the review page offers for it: Use Orbit's / Keep mine for a conflict, Undo once applied. */
        val offers: List<String> get() = when (state) {
            "conflict" -> listOf("ours", "mine")
            "kept" -> listOf("ours")
            "applied" -> listOf("undo")
            else -> emptyList()
        }

        val stateLine: String get() = when (state) {
            "applied" -> "Orbit's: $orbit"
            "conflict" -> "Yours: $yours · Orbit's: $orbit"
            "kept" -> "Kept yours: $yours"
            "unavailable" -> reason.ifEmpty { "Not on this reader" }
            else -> state
        }
    }

    companion object {
        const val FILE = "orbit-recommended.json"

        fun parse(text: String?): RecommendedReview? {
            if (text.isNullOrBlank()) return null
            val o = runCatching { JSONObject(text) }.getOrNull() ?: return null
            val a = o.optJSONArray("items") ?: return RecommendedReview(o.optLong("at"), emptyList())
            val items = (0 until a.length()).mapNotNull { a.optJSONObject(it) }.map { j ->
                Item(j.optString("id"), j.optString("label"), j.optString("state"), j.optString("yours"), j.optString("orbit"), j.optString("was"), j.optString("reason"))
            }.filter { it.id.isNotEmpty() }
            return RecommendedReview(o.optLong("at"), items)
        }

        val CHOICE_WORDS = mapOf("ours" to "Use Orbit's", "mine" to "Keep mine", "undo" to "Undo")
    }
}
