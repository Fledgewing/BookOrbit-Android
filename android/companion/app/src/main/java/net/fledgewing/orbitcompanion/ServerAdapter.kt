package net.fledgewing.orbitcompanion

import java.io.File

/** Neutral companion-owned account and connector boundary. No operation returns credentials. */
interface ServerAdapter {
    fun state(): Map<String, Any?>
    fun signIn(server: String, username: String, password: CharArray)
    fun signOut()
    fun setLogin(kind: String, server: String, username: String, secret: CharArray, derivedKey: Boolean = false)
    fun removeLogin(kind: String)
    fun useAccountLogin(kind: String)
    fun refreshStats()
    fun owner(): String?
    fun stats(owner: String): Map<*, *>?
    fun position(document: String, update: Map<String, Any?>? = null): Map<String, Any?>
    fun catalog(page: Int = 1, limit: Int = 24): Map<String, Any?>
    fun download(key: String, destination: File): Boolean
}
