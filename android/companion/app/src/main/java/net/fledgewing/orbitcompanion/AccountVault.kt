package net.fledgewing.orbitcompanion

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Private, backup-excluded account storage. The password is never a stored field. */
interface AccountVault {
    fun load(): Map<String, Any?>?
    fun save(value: Map<String, Any?>?)
}

class EncryptedAccountVault(file: File, private val key: () -> SecretKey) : AccountVault {
    private val atomic = AtomicFile(file)
    @Synchronized override fun load(): Map<String, Any?>? {
        if (!atomic.baseFile.exists()) return null
        return try {
            val bytes = atomic.readFully()
            require(bytes.size in 29..MAX_BYTES)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.updateAAD(AAD)
            val decoded = cipher.doFinal(bytes.copyOfRange(12, bytes.size))
            try {
                val map = LuaValue.parse(decoded) as? Map<*, *> ?: return null
                map.entries.associate { it.key.toString() to it.value }
            } finally { decoded.fill(0) }
        } catch (_: Exception) {
            // Unavailable key, invalid tag or corrupt file: require a new sign-in, never plaintext fallback.
            atomic.delete()
            null
        }
    }
    @Synchronized override fun save(value: Map<String, Any?>?) {
        if (value == null) { atomic.delete(); return }
        val plain = LuaValue.encode(value)
        try {
            require(plain.size <= MAX_BYTES - 28)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            cipher.updateAAD(AAD)
            val bytes = cipher.iv + cipher.doFinal(plain)
            val out = atomic.startWrite()
            try { out.write(bytes); atomic.finishWrite(out) }
            catch (e: Exception) { atomic.failWrite(out); throw e }
        } finally { plain.fill(0) }
    }
    companion object {
        const val MAX_BYTES = 262144
        private val AAD = "BookSync account v1".toByteArray()
        fun android(ctx: Context): EncryptedAccountVault = EncryptedAccountVault(File(ctx.noBackupFilesDir, "account.enc")) {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey("booksync-account-v1", null) as? SecretKey) ?: KeyGenerator.getInstance("AES", "AndroidKeyStore").run {
                init(KeyGenParameterSpec.Builder("booksync-account-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
                generateKey()
            }
        }
    }
}
