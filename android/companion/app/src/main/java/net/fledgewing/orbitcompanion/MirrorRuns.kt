package net.fledgewing.orbitcompanion

import java.io.File

/** Admission and liveness live outside the bulk executor: queued work is still alive.
 * Only this process can claim a run is alive; a query after process death reports stopped. */
internal class MirrorRuns(private val root: () -> File) {
    private var active: String? = null
    private var state: Map<String, Any?> = emptyMap()

    private fun publish(query: String? = null) {
        val file = File(root(), "mirror/run.lua")
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(LuaValue.encode(state + ("query_for" to query)))
        check(tmp.renameTo(file))
    }

    @Synchronized fun admit(run: String, op: String, done: Long, total: Long): Boolean {
        if (active != null) { publish(run); return false }
        active = run
        state = mapOf("run" to run, "op" to op, "state" to "queued", "done" to done, "total" to total,
            "left" to maxOf(0L, total - done), "pct" to if (total > 0) done * 100 / total else 0L)
        publish(run)
        return true
    }

    @Synchronized fun started(run: String) {
        check(active == run)
        state = state + ("state" to "started")
        publish()
    }

    @Synchronized fun progress(status: Map<String, Any?>) {
        if (status["run"] != active) return
        state = status + ("state" to "progress")
        publish()
    }

    @Synchronized fun ended(run: String) {
        if (active != run) return
        active = null
        state = state + ("state" to "stopped")
        publish()
    }

    @Synchronized fun query(run: String) {
        if (active == null) state = mapOf("run" to run, "state" to "stopped")
        publish(run)
    }
}
