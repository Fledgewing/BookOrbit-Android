package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.nio.file.Files
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AccountVaultTest {
    @Test fun encryptedFileNeverContainsTokensAndTamperingFailsClosed() {
        val file = Files.createTempDirectory("account-vault").resolve("account.enc").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val vault = EncryptedAccountVault(file) { key }
        val value = mapOf("access" to "private-access-token", "refresh" to "private-refresh-token")
        vault.save(value)
        assertEquals(value, vault.load())
        val first = file.readBytes()
        for (token in value.values) assertFalse(String(first).contains(token))
        vault.save(value); assertFalse(first.contentEquals(file.readBytes()))
        val bytes = file.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); file.writeBytes(bytes)
        assertNull(vault.load()); assertFalse(file.exists())
        vault.save(value); vault.save(null); assertFalse(file.exists())
    }
    @Test fun allThreeLoginsAreEncryptedAndAccountRemovalPreservesDirectLogin() {
        val file = Files.createTempDirectory("three-logins").resolve("account.enc").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val vault = EncryptedAccountVault(file) { key }
        val credentials = ServerCredentials(vault)
        credentials.accountVault.save(mapOf("access" to "fixture-access", "refresh" to "fixture-refresh"))
        credentials.set("sync",ServerCredentials.Login("https://library.invalid/api/v1","fixture-sync","a".repeat(32),"user"))
        credentials.set("opds",ServerCredentials.Login("https://library.invalid/api/v1","fixture-opds","fixture-opds-password","account"))
        val stored = String(file.readBytes())
        for (secret in listOf("fixture-access","fixture-refresh","fixture-opds-password","a".repeat(32))) assertFalse(stored.contains(secret))
        credentials.accountVault.save(null)
        val reloaded = ServerCredentials(vault)
        assertNull(reloaded.accountVault.load()); assertNull(reloaded.login("opds"))
        assertEquals("user",reloaded.status("sync")["origin"])
        reloaded.remove("sync"); assertFalse(file.exists())
    }

}
