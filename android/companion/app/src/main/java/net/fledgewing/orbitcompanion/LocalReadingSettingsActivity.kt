// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.EditText

/** Presentation calls only the Library service. No account data or filesystem on paint. */
class LocalReadingSettingsActivity : SettingsPage() {
    private var snapshot: Map<String,Any?>? = null
    private var editing = false
    private var input: EditText? = null
    private var notice: String? = null
    private var generation = 0
    override fun onResume() { super.onResume(); load() }
    override fun onPause() { generation++; super.onPause() }
    private fun load() = call("reading.local.read",emptyMap<Any,Any>())
    private fun call(op: String, args: Map<*,*>) {
        val ticket=++generation
        LibraryLocalReading.command(op,args) { value,error -> Handler(Looper.getMainLooper()).post {
            if (ticket!=generation || isFinishing || isDestroyed) return@post
            notice=if(error=="invalid") "Enter a number from 1 to 999." else if(error!=null) "Not available · try again" else null
            if(error==null) {
                input?.let { (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(it.windowToken,0) }
                snapshot=value;editing=false
            }
            render()
        } }
    }
    override fun render() {
        val root=page(scroll=true)
        root.addView(Ui.header(this,if(editing) "Local reading goal" else "Reading statistics","‹ Back") {
            if(editing) { editing=false;render() } else finish()
        })
        lockedBar(root)
        val data=snapshot
        if(editing && !locked) {
            root.addView(note(data?.get("year").toString()))
            val typed=input?.text?.toString()
            input=EditText(this).apply {
                inputType=InputType.TYPE_CLASS_NUMBER
                setSingleLine()
                hint="Books to finish on this reader"
                setText(typed ?: data?.get("target")?.toString().orEmpty())
                tag="local-goal-target"
            }
            root.addView(input)
            root.addView(note("1–999 books. This reader only. Goal carries over each year."))
            notice?.let { root.addView(note(it)) }
            root.addView(Ui.button(this,"Off") { input=null;call("reading.local.goal",emptyMap<Any,Any>()) })
            root.addView(Ui.button(this,"Save") { call("reading.local.goal",mapOf("target" to input!!.text.toString())) })
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            input!!.requestFocus()
            input!!.post { (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(input,InputMethodManager.SHOW_IMPLICIT) }
        } else {
            input=null
            root.addView(Ui.row(this,"Local reading goal",data?.get("goal_label")?.toString()?.let(LuaValue::utf8) ?: "Loading…",onClick=if(locked || data==null) null else ({editing=true;render()})))
            root.addView(Ui.row(this,"Finished this year",data?.get("count_label")?.toString()?.let(LuaValue::utf8) ?: "Loading…"))
            root.addView(note("Only books explicitly marked finished count.\nAccount totals remain separate when overlap is unknown."))
            notice?.let { root.addView(note(it)) }
        }
    }
}
