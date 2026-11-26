package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

/**
 * The companion's copy of every shared setting, with the time each last changed
 * (docs/design/companion-settings.md §4.2). Values live in "orbit_settings" as wire strings, keyed
 * by the schema, and a key never set reads as the schema's default: the one place defaults come
 * from. Prefs and SleepScreen read and write their shared keys here. Keys an older companion kept
 * elsewhere (Prefs "orbit", the sleep screen's "orbit_sleep") are moved in once ([migrate]), so
 * nothing a reader set is reset. Times: "orbit_settings_at"; the plugin's last reported time per
 * key (its echo): "orbit_settings_plugin_at"; when a key last came from KOReader:
 * "orbit_settings_from_plugin".
 *
 * reading_schedule is the exception: its value is the plugin's (Prefs.readingSchedule, as the
 * plugin reported it) and the companion's change is a request until the plugin echoes it.
 */
object SettingsStore {
    private const val VALUES = "orbit_settings"
    private const val AT = "orbit_settings_at"
    private const val PLUGIN_AT = "orbit_settings_plugin_at"
    private const val FROM_PLUGIN = "orbit_settings_from_plugin"
    private const val SEEDED = "_seeded"
    private const val MIGRATED = "_migrated"

    /** Where an older companion kept a shared key: its SharedPreferences file. */
    internal val LEGACY = mapOf(
        "wifi_mode" to "orbit", "wifi_idle_min" to "orbit", "home_button" to "orbit",
    ) + SleepSettings.KEYS.associateWith { "orbit_sleep" }

    @Volatile
    private var migrated = false

    @Volatile
    private var cached: SettingsSchema? = null

    /** The schema from the APK's assets (a test may set it first). */
    fun schema(ctx: Context): SettingsSchema = cached ?: synchronized(this) {
        cached ?: SettingsSchema.parse(ctx.assets.open(SettingsSchema.ASSET).use { it.readBytes().toString(Charsets.UTF_8) }).also { cached = it }
    }

    fun useSchema(s: SettingsSchema) { cached = s }

    private fun sp(ctx: Context, name: String): SharedPreferences = ctx.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)

    /**
     * Moves the shared keys an older companion kept in Prefs and the sleep screen's prefs into
     * "orbit_settings", once: a value set there and valid for the schema is kept (one already in
     * "orbit_settings" wins), then the old key is removed. Runs before any read or write here.
     */
    fun migrate(ctx: Context) {
        if (migrated) return
        synchronized(this) {
            if (migrated) return
            val values = sp(ctx, VALUES)
            // Independent of the older shared-settings migration: this also runs on upgrades.
            val old = sp(ctx, "orbit")
            val legacyChannel = old.contains("include_prereleases") || values.contains("patch_update_prerelease")
            if (!values.contains("update_channel") && legacyChannel) {
                val preview = if (old.contains("include_prereleases")) old.getBoolean("include_prereleases", false)
                    else values.getString("patch_update_prerelease", "0") == "1"
                if (!values.edit().putString("update_channel", if (preview) "preview" else "stable").commit()) return
            }
            val times = sp(ctx, AT)
            if (!times.contains("update_channel") && (legacyChannel ||
                    values.getString("update_channel", null)?.let { it != "stable" } == true)) {
                val inherited = maxOf(2L, times.getLong("patch_update_prerelease", 0L))
                if (!times.edit().putLong("update_channel", inherited).commit()) return
            }
            // Replacement is durable before either source is removed; later channel choices win.
            old.edit().remove("include_prereleases").commit()
            values.edit().remove("patch_update_prerelease").commit()
            if (!values.getBoolean(MIGRATED, false)) {
                val schema = schema(ctx)
                val e = values.edit()
                val moved = mutableListOf<String>()
                val cleanup = mutableListOf<SharedPreferences.Editor>()
                for ((file, keys) in LEGACY.entries.groupBy({ it.value }, { it.key })) {
                    val old = sp(ctx, file)
                    val oe = old.edit()
                    for (key in keys) {
                        if (!old.contains(key)) continue
                        val wire = SettingsMigration.wire(old.all[key])
                        val d = schema.byKey[key]
                        if (wire != null && d != null && !values.contains(key)) SettingsSync.fromWire(d, wire)?.let { e.putString(key, it); moved += key }
                        oe.remove(key)
                    }
                    cleanup += oe
                }
                // Persist every replacement before deleting any source. A failed write or a
                // process death during cleanup leaves at least one durable copy of each value.
                e.putBoolean(MIGRATED, true)
                if (!e.commit()) return
                cleanup.forEach { it.commit() }
                if (moved.isNotEmpty()) OLog.i("settings: moved ${moved.joinToString(" ")} into the schema store")
            }
            migrated = true
        }
    }

    /** Tests: forget that this process migrated (a new reader's preferences). */
    internal fun resetForTest() { migrated = false }

    /** The stored wire value, or null when never set (no default). */
    fun stored(ctx: Context, key: String): String? {
        migrate(ctx)
        return sp(ctx, VALUES).getString(key, null)
    }

    /** Stores a wire value as is: no time, no notice (Prefs, SleepScreen.save). */
    fun store(ctx: Context, key: String, wire: String) {
        migrate(ctx)
        sp(ctx, VALUES).edit().putString(key, wire).apply()
    }

    /** The value now, as a wire string (the schema's default when never set). */
    fun get(ctx: Context, key: String): String {
        val d = schema(ctx).byKey[key] ?: return ""
        if (key == "reading_schedule") {
            val p = Prefs(ctx)
            return ReadingSchedule.shown(p.readingSchedule, p.readingScheduleRequest)
        }
        return stored(ctx, key) ?: d.default
    }

    fun bool(ctx: Context, key: String): Boolean = get(ctx, key) == "1"

    fun at(ctx: Context, key: String): Long? = sp(ctx, AT).getLong(key, 0L).takeIf { it > 0 }

    fun pluginAt(ctx: Context, key: String): Long? = sp(ctx, PLUGIN_AT).getLong(key, 0L).takeIf { it > 0 }

    /** Waiting for KOReader: changed here, not yet reported back by the plugin (§4.5). */
    fun pending(ctx: Context, key: String): Boolean {
        seed(ctx)
        val d = schema(ctx).byKey[key] ?: return false
        return SettingsSync.pending(d, at(ctx, key), pluginAt(ctx, key))
    }

    /** When KOReader last changed [key] (ms), for "Changed in KOReader at …"; null: not lately. */
    fun fromPluginAt(ctx: Context, key: String): Long? = sp(ctx, FROM_PLUGIN).getLong(key, 0L).takeIf { it > 0 }

    fun clearFromPlugin(ctx: Context, keys: Collection<String>) {
        val e = sp(ctx, FROM_PLUGIN).edit()
        keys.forEach { e.remove(it) }
        e.apply()
    }

    /** Writes the value (no time, no notice); a sleep screen key through SleepScreen.save, which redraws. */
    private fun put(ctx: Context, key: String, wire: String, why: String) {
        when (key) {
            "reading_schedule" -> Prefs(ctx).readingSchedule = wire
            in SleepSettings.KEYS -> {
                val s = SleepSettings.merge(SleepScreen.settings(ctx)) { if (it == key) wire else null }
                if (s != SleepScreen.settings(ctx)) SleepScreen.save(ctx, s, why, shared = false)
            }
            else -> store(ctx, key, wire)
        }
    }

    /**
     * The first run with per-key times: the keys shared before get the old whole-set time;
     * the rest have none, so the plugin's values come in (it seeds them at 1 ms).
     */
    fun seed(ctx: Context) {
        val at = sp(ctx, AT)
        if (at.getBoolean(SEEDED, false)) return
        val legacy = Prefs(ctx).sharedSettingsAt
        val e = at.edit()
        if (legacy > 0) SettingsSync.LEGACY.forEach { k -> if (!at.contains(k)) e.putLong(k, legacy) }
        e.putBoolean(SEEDED, true).apply()
    }

    /**
     * A change made in the companion: stored with its time, then told to the plugin (the status
     * file, the "look now" line on /clicks; /status answers it). Returns false when the schema refuses it.
     */
    fun set(ctx: Context, key: String, value: String, why: String): Boolean {
        seed(ctx)
        val d = schema(ctx).byKey[key] ?: return false
        val wire = SettingsSync.fromWire(d, value) ?: return false
        val now = System.currentTimeMillis()
        val t = maxOf(now, (at(ctx, key) ?: 0L) + 1)
        val was = get(ctx, key)
        if (key == "reading_schedule") {
            // Prefs.readingSchedule is what the plugin reported; ours is a request until it echoes
            // (an older plugin applies the request, ReadingSchedule; a newer one the value).
            val p = Prefs(ctx)
            if (wire == p.readingSchedule) { p.readingScheduleRequest = ""; p.readingScheduleRequestAt = 0 }
            else { p.readingScheduleRequest = wire; p.readingScheduleRequestAt = t }
        } else {
            put(ctx, key, wire, why)
        }
        sp(ctx, AT).edit().putLong(key, t).apply()
        clearFromPlugin(ctx, listOf(key))
        Prefs(ctx).sharedSettingsAt = t
        OLog.i("settings: $key = ${wire.replace('\n', ',')} (was ${was.replace('\n', ',')}, $why)")
        changed(ctx, t, "setting $key")
        return true
    }

    /** Picker taps only change preference memory here; shared storage and picture work are queued. */
    fun setPicker(ctx: Context, key: String, value: String): Boolean {
        require(key == "sleep_from" || key == "sleep_leave_out")
        seed(ctx)
        val wire = SettingsSync.fromWire(schema(ctx).byKey.getValue(key), value) ?: return false
        val t = maxOf(System.currentTimeMillis(), (at(ctx, key) ?: 0L) + 1)
        store(ctx, key, wire)
        sp(ctx, AT).edit().putLong(key, t).apply()
        clearFromPlugin(ctx, listOf(key))
        Prefs(ctx).sharedSettingsAt = t
        val app = ctx.applicationContext
        SleepPickerWork.submit {
            changed(app, t, "sleep picker")
            SleepScreen.redrawPicture(app, "sleep picker")
        }
        return true
    }

    /** Tells the plugin and the service something changed. */
    private fun changed(ctx: Context, at: Long, why: String) {
        StatusFile.write(ctx, why)
        ClickChannel.settings(at)
        if (OrbitService.running) OrbitService.start(ctx, Intent(OrbitService.ACTION_REFRESH))
    }

    /** The values for the wire: every key with a time. */
    fun values(ctx: Context): Map<String, SettingEntry> {
        seed(ctx)
        return schema(ctx).settings.mapNotNull { d -> at(ctx, d.key)?.let { d.key to SettingEntry(get(ctx, d.key), it) } }.toMap()
    }

    fun valuesJson(ctx: Context): String = SettingsSync.valuesJson(values(ctx))

    /**
     * SETTINGS from the plugin with values (settings v2): takes the keys KOReader changed later,
     * and records the plugin's time for every key (its echo of our changes). -> the keys taken.
     */
    fun fromPlugin(ctx: Context, valuesText: String?, why: String): List<String> {
        seed(ctx)
        val remote = SettingsSync.parseValues(valuesText)
        if (remote.isEmpty()) return emptyList()
        val schema = schema(ctx)
        val local = schema.settings.associate { d -> d.key to SettingEntry(get(ctx, d.key), at(ctx, d.key)) }
        val taken = SettingsSync.merge(schema, local, remote, System.currentTimeMillis(), remoteWinsTie = false)
        val atE = sp(ctx, AT).edit()
        val fromE = sp(ctx, FROM_PLUGIN).edit()
        val changedKeys = mutableListOf<String>()
        for (t in taken) {
            if (!t.same) {
                put(ctx, t.key, t.v, "from KOReader")
                fromE.putLong(t.key, t.at)
                changedKeys += t.key
                OLog.i("settings: ${t.key} = ${t.v.replace('\n', ',')} (from KOReader, was ${t.was?.replace('\n', ',') ?: "unset"}, $why)")
            }
            atE.putLong(t.key, t.at)
        }
        atE.apply()
        fromE.apply()
        val pe = sp(ctx, PLUGIN_AT).edit()
        for ((k, e) in remote) e.at?.let { if (it > (pluginAt(ctx, k) ?: 0L)) pe.putLong(k, it) }
        pe.apply()
        // An older plugin's request done: the plugin reports the value we asked for.
        val p = Prefs(ctx)
        if (p.readingScheduleRequest.isNotEmpty() && remote["reading_schedule"]?.v == p.readingScheduleRequest) {
            p.readingSchedule = p.readingScheduleRequest
            p.readingScheduleRequest = ""
            p.readingScheduleRequestAt = 0
        }
        if (taken.isNotEmpty()) {
            val maxAt = taken.maxOf { it.at }
            if (maxAt > p.sharedSettingsAt) p.sharedSettingsAt = maxAt
            StatusFile.write(ctx, "settings from KOReader")
        }
        return changedKeys
    }
}

/** The one-time move into the schema store (SettingsStore.migrate). */
internal object SettingsMigration {
    /** An old SharedPreferences value as a wire string: strings as they are, numbers in decimal, bools 1/0. */
    fun wire(v: Any?): String? = when (v) {
        is String -> v
        is Int, is Long -> v.toString()
        is Boolean -> if (v) "1" else "0"
        else -> null
    }
}
