package net.fledgewing.orbitcompanion

import org.json.JSONObject
import java.security.MessageDigest

/** One atomic envelope: the exact payload bytes and their root-certified signature. */
data class AndroidReleaseFeed(val releases: List<ReleaseInfo>, val withdrawn: Set<Version>) {
    companion object {
        const val URL = "https://raw.githubusercontent.com/${Updater.REPO}/android-feed/android/releases.json"
        internal const val LEGACY_URL = "https://raw.githubusercontent.com/${Updater.LEGACY_REPO}/android-feed/android/releases.json"
        const val TAG = "android-feed"
        const val ASSET = "android-releases.json"

        /** Both locations must pass the same signature and payload checks. */
        internal fun <T> fromLocations(read: (String) -> T): T {
            return try {
                read(URL)
            } catch (primary: Exception) {
                try {
                    read(LEGACY_URL)
                } catch (fallback: Exception) {
                    fallback.addSuppressed(primary)
                    throw fallback
                }
            }
        }

        fun parse(text: String, root: String, minSerial: Long): AndroidReleaseFeed {
            val envelope = JSONObject(text)
            val payload = envelope.getString("payload")
            val digest = MessageDigest.getInstance("SHA-256").digest(payload.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            require(ReleaseSignature.check(root, minSerial, envelope.getString("signatures"), TAG, ASSET, digest)
                == ReleaseSignature.Result.Ok) { "Android release feed signature failed; no update installed" }
            val doc = JSONObject(payload)
            val list = doc.getJSONArray("releases")
            val withdrawn = doc.getJSONArray("withdrawn")
            return AndroidReleaseFeed((0 until list.length()).map { ReleaseInfo.from(list.getJSONObject(it)) },
                (0 until withdrawn.length()).map {
                    requireNotNull(ReleaseTags.version(withdrawn.getString(it))) { "Invalid withdrawn Android tag" }
                }.toSet())
        }
    }
}
