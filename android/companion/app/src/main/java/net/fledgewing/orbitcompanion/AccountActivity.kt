package net.fledgewing.orbitcompanion

import android.os.Bundle
import android.text.InputFilter
import android.text.InputType
import android.view.WindowManager
import android.widget.EditText

/** Temporary plain account screen; the UI never receives adapter JSON or tokens. */
class AccountActivity : EinkActivity() {
    override val returnable = false
    override val pinGuarded = true
    private var busy = false
    private var message = ""
    private var serverValue = ""
    private var userValue = ""
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        serverValue = intent.getStringExtra("server").orEmpty()
        LibraryAccount.initialize(this) { if (!isFinishing && !isDestroyed) render() }
    }
    override fun onResume() { super.onResume(); render() }
    override fun refresh() = render()
    private fun render() {
        val start = System.nanoTime()
        val root = page()
        root.addView(Ui.text(this, "Sign in to your server", 26f, bold = true))
        val state = LibraryAccount.state()
        require(LuaValue.encode(state).size <= 16384)
        if (state["signedIn"] == true) {
            root.addView(Ui.text(this, "Signed in", 20f))
            if (state["connector"] == "existing-login-needed") root.addView(Ui.text(this,
                "Your server already has a reader login. Use the existing reader login in KOReader to connect this reader.", 18f))
            if (state["connector"] == "forbidden") root.addView(Ui.text(this, "Your account does not permit reader connection setup.", 18f))
            if (state["connector"] == "unavailable") root.addView(Ui.button(this, "Try connection setup again") {
                if (!busy) { busy = true; render(); LibraryAccount.retryConnection(this) { finishCommand(it) } }
            })
            root.addView(Ui.button(this, if (busy) "Signing out…" else "Sign out") {
                if (!busy) { busy = true; render(); LibraryAccount.signOut(this) { finishCommand(it) } }
            })
        } else {
            fun field(hintText: String, initial: String, type: Int, max: Int) = EditText(this).apply {
                hint = hintText; setText(initial); inputType = type; filters = arrayOf(InputFilter.LengthFilter(max))
                isSaveEnabled = false; setSingleLine(true); root.addView(this)
            }
            val server = field("Server address", serverValue, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI, 2048)
            val username = field("Username", userValue, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS, 100)
            val password = field("Password", "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD, 1024)
            root.addView(Ui.button(this, if (busy) "Signing in…" else "Sign in", solid = true) {
                if (!busy) {
                    serverValue = server.text.toString(); userValue = username.text.toString()
                    val secret = CharArray(password.length()) { password.text[it] }
                    password.text.clear(); password.clearFocus()
                    busy = true; render()
                    LibraryAccount.signIn(this, serverValue, userValue, secret) { finishCommand(it) }
                }
            })
            root.addView(Ui.text(this, "Use your server account. Servers requiring browser sign-in are not supported by this screen yet.", 18f))
        }
        if (message.isNotEmpty()) root.addView(Ui.text(this, message, 18f))
        root.addView(Ui.button(this, "Back") { finish() })
        OLog.i("account.paint ms=${(System.nanoTime()-start)/1_000_000} rows=1 bytes=${LuaValue.encode(state).size} spawns=0 network=0")
    }
    private fun finishCommand(error: String?) {
        if (isFinishing || isDestroyed) return
        busy = false
        message = when (error) { null -> ""; "unauthorized" -> "Check your account login."; "forbidden" -> "Your server does not permit this operation."; "expired" -> "Session expired. Sign in again."; else -> "Could not reach your account. Try again." }
        render()
    }
}
