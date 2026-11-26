package net.fledgewing.orbitcompanion

object RefreshStatus {
    fun runningProgressLine(pct: Long?, paused: Boolean) =
        "Full refresh · ${(pct ?: 0L).coerceIn(0, 100)}%" + if (paused) " · paused while reading" else ""
}
