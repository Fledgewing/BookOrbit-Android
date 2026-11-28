// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.os.Environment
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.io.File
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],qualifiers="w632dp-h840dp-port-xhdpi")
class LocalReadingSettingsTest {
    private val ledger get()=File(Environment.getExternalStorageDirectory(),"koreader/settings/booksync-local-reading.sqlite3")
    @Before fun setup() { ledger.delete();SettingsPage.forceLocked=false;Prefs(RuntimeEnvironment.getApplication()).mode=OrbitMode.FULL }
    @After fun cleanup() { ledger.delete();SettingsPage.forceLocked=null }
    private fun views(v:View):List<View> = listOf(v)+if(v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun texts(a:LocalReadingSettingsActivity)=views(a.window.decorView).filterIsInstance<TextView>()
    private fun waitFor(a:LocalReadingSettingsActivity,text:String) {
        val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
        while(texts(a).none {it.text.toString().contains(text)}) { ShadowLooper.idleMainLooper();check(System.nanoTime()<end);Thread.sleep(10) }
    }
    @Test fun companionNumericGoalSavesDisablesAndReopensThroughLibrary() {
        val controller=Robolectric.buildActivity(LocalReadingSettingsActivity::class.java).setup();val a=controller.get()
        waitFor(a,"Off · This reader only")
        texts(a).first {it.text.toString()=="Local reading goal"}.parent.parent.let { (it as View).performClick() }
        val input=views(a.window.decorView).filterIsInstance<EditText>().single()
        assertEquals(android.text.InputType.TYPE_CLASS_NUMBER,input.inputType)
        input.setText("12")
        texts(a).first {it.text.toString()=="Save"}.performClick()
        waitFor(a,"12 books · This reader only")
        controller.pause().stop().destroy()
        val second=Robolectric.buildActivity(LocalReadingSettingsActivity::class.java).setup();val b=second.get()
        waitFor(b,"12 books · This reader only")
        texts(b).first {it.text.toString()=="Local reading goal"}.parent.parent.let { (it as View).performClick() }
        texts(b).first {it.text.toString()=="Off"}.performClick()
        waitFor(b,"Off · This reader only")
        second.pause().stop().destroy()
    }
    @Test fun lockedStatisticsShowLocalValuesWithoutAnEditor() {
        SettingsPage.forceLocked=true
        val c=Robolectric.buildActivity(LocalReadingSettingsActivity::class.java).setup();val a=c.get()
        waitFor(a,"This reader only")
        assertTrue(views(a.window.decorView).filterIsInstance<EditText>().isEmpty())
        assertTrue(texts(a).any {it.text.toString()=="Finished this year"})
        c.pause().stop().destroy()
    }
}
