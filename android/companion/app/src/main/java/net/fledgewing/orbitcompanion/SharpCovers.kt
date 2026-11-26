package net.fledgewing.orbitcompanion

import android.content.Context
import java.io.File

interface CoverService {
    fun dir(ctx: Context): File
    fun state(ctx: Context): SharpCoversLogic.State
    fun lostWhy(ctx: Context): String?
    fun user(ctx: Context): String?
    fun account(dir: File): SharpCovers.Account?
    fun fileFor(ctx: Context, id: Long): File?
    fun sharpCount(ctx: Context, ids: List<Long>): Int
    fun signIn(ctx: Context, server: String, user: String, password: CharArray): String?
    fun signOut(ctx: Context, why: String)
    fun sync(ctx: Context, why: String)
    fun syncNow(ctx: Context, why: String): Int
    fun check(ctx: Context): Check?
}

/** Sleep UI talks to this neutral service. Connector authentication stays in the adapter. */
object SharpCovers : CoverService by ServerAdapters.covers {
    const val SETUP_ID = "sharp_covers"
    data class Account(val server: String, val user: String, val storageLimitMb: Int)
    fun account(): Account? = account(SleepScreen.dir())
}
