package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

/**
 * The companion's copy of every shared setting, with the time each last changed
 * (docs/design/companion-settings.md §4.2). Keys the companion already kept keep their old
 * storage (Prefs, the sleep screen's prefs), so nothing a reader set is reset; the rest live in
 * "orbit_settings". Times: "orbit_settings_at"; the plugin's last reported time per key (its echo):
 * "orbit_settings_plugin_at"; when a key last came from KOReader: "orbit_settings_from_plugin".
 */
object SettingsStore {
    private const val VALUES = "orbit_settings"
    private const val AT = "orbit_settings_at"
    private const val PLUGIN_AT = "orbit_settings_plugin_at"
    private const val FROM_PLUGIN = "orbit_settings_from_plugin"
    private const val SEEDED = "_seeded"

    @Volatile
    private var cached: SettingsSchema? = null

    /** The schema from the APK's assets (a test may set it first). */
    fun schema(ctx: Context): SettingsSchema = cached ?: synchronized(this) {
        cached ?: SettingsSchema.parse(ctx.assets.open(SettingsSchema.ASSET).use { it.readBytes().toString(Charsets.UTF_8) }).also { cached = it }
    }

    fun useSchema(s: SettingsSchema) { cached = s }

    private fun sp(ctx: Context, name: String): SharedPreferences = ctx.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)

    /** The value now, as a wire string (the default when never set). */
    fun get(ctx: Context, key: String): String {
        val d = schema(ctx).byKey[key] ?: return ""
        val p = Prefs(ctx)
        return when (key) {
            "wifi_mode" -> p.wifiMode.key
            "wifi_idle_min" -> p.wifiIdleMin.toString()
            "home_button" -> p.homeButton.key
            "reading_schedule" -> ReadingSchedule.shown(p.readingSchedule, p.readingScheduleRequest)
            in SleepSettings.KEYS -> SleepScreen.settings(ctx).toMap()[key] ?: d.default
            else -> sp(ctx, VALUES).getString(key, null) ?: d.default
        }
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

    /** Writes the value into its storage (no time, no notice). */
    private fun put(ctx: Context, key: String, wire: String, why: String) {
        val p = Prefs(ctx)
        when (key) {
            "wifi_mode" -> p.wifiMode = WifiMode.fromKey(wire)
            "wifi_idle_min" -> wire.toIntOrNull()?.let { p.wifiIdleMin = it }
            "home_button" -> p.homeButton = HomeButton.fromKey(wire)
            "reading_schedule" -> p.readingSchedule = wire
            in SleepSettings.KEYS -> {
                val s = SleepSettings.merge(SleepScreen.settings(ctx)) { if (it == key) wire else null }
                if (s != SleepScreen.settings(ctx)) SleepScreen.save(ctx, s, why, shared = false)
            }
            else -> sp(ctx, VALUES).edit().putString(key, wire).apply()
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
