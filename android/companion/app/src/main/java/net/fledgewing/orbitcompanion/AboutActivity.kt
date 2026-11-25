package net.fledgewing.orbitcompanion

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import org.json.JSONObject

/** Public, including while Settings is locked. The shared notice ships in the APK. */
class AboutActivity : EinkActivity() {
    override val pinPage = PinPage.NEUTRAL

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val credits = JSONObject(assets.open("about_credits.json").bufferedReader().use { it.readText() })
        val root = page()
        root.addView(Ui.header(this, "About BookSync", "‹ Back") { finish() })
        root.addView(Ui.text(this, "BookSync ${BuildConfig.VERSION_NAME}", 21f, bold = true))
        val paragraphs = credits.getJSONArray("paragraphs")
        for (i in 0 until paragraphs.length()) {
            root.addView(Ui.text(this, paragraphs.getString(i), 18f))
            if (i == 1) {
                root.addView(Ui.row(this, credits.getString("url"), null, Ui.value(this, "›"), onClick = {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(credits.getString("url"))))
                }).apply { tag = "bookorbit-credit" })
            }
            root.addView(Ui.gap(this, 12))
        }
        root.addView(Ui.row(this, "Open-source licenses", null, Ui.value(this, "›"), onClick = {
            startActivity(Intent(this, LicensesActivity::class.java))
        }))
    }
}
