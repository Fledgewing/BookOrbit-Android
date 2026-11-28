// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.content.Context
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.format.DateFormat
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/** Only local registers in 0.12.1. No server/account or catalog dependency. Every command
 * uses one worker, bounded values and device lifetime, never an Activity or notification. */
object LibraryReminders {
    private val queue=Executors.newSingleThreadExecutor()
    private val main by lazy {Handler(Looper.getMainLooper())}
    private var initialized=false
    @Synchronized fun initialize(ctx:Context) {
        if(initialized) return
        initialized=true
        val receiver=object:BroadcastReceiver() {
            override fun onReceive(context:Context,intent:Intent) {
                // Dynamic OS clock/zone/format values are read by the policy. Never
                // initiate time sync, wake a reader or paint from this callback.
                queue.execute {service?.candidates()}
            }
        }
        val filter=IntentFilter().apply {addAction(Intent.ACTION_TIME_CHANGED);addAction(Intent.ACTION_TIMEZONE_CHANGED)}
        if(Build.VERSION.SDK_INT>=33) ctx.applicationContext.registerReceiver(receiver,filter,Context.RECEIVER_NOT_EXPORTED)
        else ctx.applicationContext.registerReceiver(receiver,filter)
    }
    private var service: Reminders?=null
    private var store: RemindersStore?=null
    private var grant: Reminders.Grant?=null
    private var sleepToken: String?=null
    private var sleepAttempt: String?=null
    private var inputSerial: String?=null
    private var lastInput=0L
    private var runtime: Reminders.Runtime?=null
    private var lastSampled=0L
    private fun service(): Reminders = service ?: run {
        val file=File(Environment.getExternalStorageDirectory(),"koreader/settings/booksync-reminders.sqlite3")
        if(file.exists()) {
            check(file.length()>0) {"Reminders could not be loaded"}
            AndroidSql(file,readOnly=true).use { probe ->
                check(probe.query("SELECT name FROM sqlite_master WHERE type='table' AND name='reminders_state' LIMIT 1") {it.text(0)}.size==1)
            }
        }
        val sql=AndroidSql(file)
        try {
            val storage=RemindersStore(sql)
            Reminders(storage,System::currentTimeMillis,SystemClock::elapsedRealtime,ZoneId::systemDefault).also {service=it;store=storage}
        } catch(e:Exception) {sql.close();throw e}
    }
    private fun available(ctx:Context)=Net.adminActive(ctx) && OrbitService.current!=null && Mode.caps(ctx).contains("screen_off")
    private fun snapshot(ctx:Context,s:Reminders): Map<String,Any?> {
        val result=s.snapshot(!DateFormat.is24HourFormat(ctx))
        return result+mapOf(
        "state" to if(store?.recovered==true) "recovered" else "ready",
        "notice" to if(store?.recovered==true) "Previous reminders recovered" else null,
        "capabilities" to mapOf("reminders" to mapOf("kinds" to listOf("time","interval"),"timeLimit" to 8,
            "intervalLimit" to 1,"clockStatus" to result["clockStatus"],
            "operations" to mapOf("time" to listOf("add","edit","setEnabled","delete","claimDue","respond"),"interval" to listOf("edit","setEnabled","claimDue","respond")),"messageCharacters" to 60,"messageBytes" to 240,"localOnly" to true,"sleepAvailable" to available(ctx))))
    }
    private fun payload(ctx:Context,s:Reminders,d:Reminders.Due):Map<String,Any?> {
        val r=s.records().first {it.id==d.id}
        val formatter=DateTimeFormatter.ofPattern(if(DateFormat.is24HourFormat(ctx)) "HH:mm" else "h:mm a")
        return mapOf("event" to d.event,"id" to d.id,"revision" to d.revision,"source" to "local","kind" to d.kind,
            "message" to LuaValue.str(if(d.kind=="interval") Reminders.EYE_TEXT else r.message?.takeIf {it.isNotEmpty()} ?: Reminders.DEFAULT_TEXT),
            "dueLabel" to if(d.kind=="time" && d.missed) LuaValue.str("Due at "+Instant.ofEpochMilli(d.due).atZone(ZoneId.systemDefault()).format(formatter)) else null,
            "sleepAvailable" to available(ctx),"editable" to true,
            "expiresElapsed" to if(d.kind=="time") d.elapsedExpiry ?: (SystemClock.elapsedRealtime()+(d.expiry-System.currentTimeMillis()).coerceAtLeast(0)) else null)
    }
    fun command(ctx:Context,op:String,args:Map<*,*>,done:(Map<String,Any?>?,String?)->Unit) {
        val app=ctx.applicationContext
        queue.execute {
            val start=System.nanoTime()
            val result=runCatching {
                if(op=="reminders.retry" || service?.storageReady()==false && op in setOf("reminders.list","reminders.add","reminders.edit","reminders.setEnabled","reminders.delete")) {
                    runCatching {store?.close()}
                    service=null;store=null;grant=null;sleepToken=null;sleepAttempt=null
                    inputSerial=null;lastInput=0;lastSampled=0;runtime=null
                }
                val s=service()
                fun text(k:String)=(args[k] as? String)?.let(LuaValue::utf8) ?: throw IllegalArgumentException(k)
                fun number(k:String):Long {val n=args[k] as? Number ?: throw IllegalArgumentException(k);require(n.toDouble().isFinite() && n.toLong().toDouble()==n.toDouble());return n.toLong()}
                fun boolean(k:String)=args[k] as? Boolean ?: throw IllegalArgumentException(k)
                fun fields():Reminders.Record {
                    require(args.keys.all {it in setOf("kind","id","revision","enabled","minuteOfDay","days","message","intervalMinutes","mutation")})
                    require(args["message"]==null || args["message"] is String)
                    return Reminders.Record("draft",text("kind"),enabled=boolean("enabled"),minuteOfDay=args["minuteOfDay"]?.let {number("minuteOfDay").also {require(it in 0..1439)}.toInt()},
                        days=args["days"]?.let {number("days").also {require(it in 1..127)}.toInt()},message=(args["message"] as? String)?.let(LuaValue::utf8),
                        intervalMinutes=args["intervalMinutes"]?.let {number("intervalMinutes").also {require(it in 20..60)}.toInt()})
                }
                when(op) {
                    "reminders.list","reminders.retry" -> snapshot(app,s)
                    "reminders.runtime" -> {
                        fun apply(values: Map<*,*>) {
                            val now=SystemClock.elapsedRealtime()
                            val sampledAt=(values["at"] as? Number)?.toLong() ?: now
                            require(sampledAt>=0 && sampledAt<=now+50)
                            if(sampledAt<lastSampled) return
                            lastSampled=sampledAt
                            val owner=values["owner"] as? String ?: throw IllegalArgumentException("owner")
                            val serial=values["input"] as? String ?: throw IllegalArgumentException("input")
                            require(owner.length in 1..80 && serial.length in 1..80)
                            val age=(values["age"] as? Number)?.toLong()?.coerceIn(0,Reminders.BREAK) ?: throw IllegalArgumentException("age")
                            if(serial!=inputSerial) {inputSerial=serial;lastInput=(sampledAt-age).coerceAtLeast(0)}
                            fun flag(k:String)=values[k] as? Boolean ?: throw IllegalArgumentException(k)
                            val rt=Reminders.Runtime(owner,flag("visible"),flag("sleeping"),flag("page"),flag("modal"),lastInput,
                                presenting=flag("presenting"),at=sampledAt)
                            if(rt.owner!=runtime?.owner || !rt.visible || rt.sleeping || rt.modal || !rt.presenting) {sleepToken=null;sleepAttempt=null}
                            runtime=rt;s.activity(rt)
                        }
                        // Preserve the first transition in a coalesced UI turn (e.g. page
                        // to menu to page), with capture time rather than worker arrival time.
                        (args["previous"] as? Map<*,*>)?.let(::apply)
                        apply(args)
                        if(grant?.let {s.valid(it)}==false) grant=null
                        val due=s.candidates().take(8).map {payload(app,s,it)}
                        mapOf("due" to due,"grantValid" to (grant!=null))
                    }
                    "reminders.draft" -> {
                        val input=(args["inputTime"] as? String)?.let(LuaValue::utf8)
                        var fields=args.filterKeys {it!="inputTime"}
                        if(input!=null) {
                            fields=fields+mapOf("minuteOfDay" to Reminders.parseTime(input,!DateFormat.is24HourFormat(app)))
                        }
                        require(fields.keys.all {it in setOf("id","revision","kind","enabled","minuteOfDay","days","message","intervalMinutes")})
                        val r=Reminders.Record(if(fields["kind"]=="interval") Reminders.INTERVAL else "local:00000000-0000-0000-0000-000000000000",
                            fields["kind"] as String,enabled=fields["enabled"] as Boolean,
                            minuteOfDay=(fields["minuteOfDay"] as? Number)?.toInt(),days=(fields["days"] as? Number)?.toInt(),
                            message=(fields["message"] as? String)?.let(LuaValue::utf8),intervalMinutes=(fields["intervalMinutes"] as? Number)?.toInt())
                        for(k in listOf("minuteOfDay","days","intervalMinutes")) fields[k]?.let {
                            val range=when(k) {"minuteOfDay"->0L..1439L;"days"->1L..127L;else->20L..60L}
                            require(it is Number && it.toDouble().isFinite() && it.toDouble()==it.toLong().toDouble() && it.toLong() in range)
                        }
                        Reminders.validate(r)
                        s.presentation(r,!DateFormat.is24HourFormat(app)).filterKeys {it !in setOf("id","revision")}
                    }
                    "reminders.add" -> {
                        require(args["id"]==null && args["revision"]==null)
                        val r=fields();val saved=s.add(r.kind,r.enabled,r.minuteOfDay,r.days,r.message,r.intervalMinutes,text("mutation"));snapshot(app,s)+mapOf("saved" to mapOf("id" to saved.id,"revision" to saved.revision))
                    }
                    "reminders.edit" -> {
                        val r=fields();val saved=s.edit(text("id"),number("revision"),r.kind,r.enabled,r.minuteOfDay,r.days,r.message,r.intervalMinutes,text("mutation"));snapshot(app,s)+mapOf("saved" to mapOf("id" to saved.id,"revision" to saved.revision))
                    }
                    "reminders.setEnabled" -> {require(args.keys.all {it in setOf("id","revision","enabled","mutation")});s.setEnabled(text("id"),number("revision"),boolean("enabled"),text("mutation"));snapshot(app,s)}
                    "reminders.delete" -> {require(args.keys.all {it in setOf("id","revision","mutation")});s.delete(text("id"),number("revision"),text("mutation"));snapshot(app,s)}
                    "reminders.claimDue" -> {
                        require(args.keys.all {it in setOf("event","owner")})
                        val claimed=s.claim(text("event"),text("owner"))
                        val g=claimed?.takeIf {s.drawable(it)}
                        if(claimed!=null && g==null) s.retire(claimed)
                        if(g!=null) grant=g
                        if(g==null) mapOf("stale" to true) else payload(app,s,g.due)+mapOf("grant" to g.token,"owner" to g.owner,"grantExpiresElapsed" to g.issuedAt+120000)
                    }
                    "reminders.respond" -> {
                        require(args.keys.all {it in setOf("grant","owner","action")})
                        val g=grant?.takeIf {it.token==text("grant") && it.owner==text("owner")}
                        if(g==null) mapOf("stale" to true) else {
                            val action=text("action")
                            val response=s.respond(g,action,available(app))
                            if(response.accepted && !response.sleep) {grant=null;sleepToken=null;sleepAttempt=null}
                            if(response.sleep) {sleepToken=g.token;sleepAttempt=g.token}
                            if(!response.accepted && action=="sleep" && s.valid(g)) mapOf("error" to "unavailable")
                            else mapOf("accepted" to response.accepted,"stale" to !response.accepted,"sleep" to response.sleep)
                        }
                    }
                    "reminders.sleep" -> {
                        require(args.keys.all {it in setOf("grant","owner")})
                        // Intent is issued only by an explicit response, consumed once. Sleep
                        // still requires the current visible owner and existing service path.
                        val token=text("grant");val rt=runtime
                        if(sleepToken!=token || rt?.owner!=text("owner") || !rt.visible || rt.sleeping || rt.modal || !rt.presenting || !available(app)) mapOf("error" to "unavailable")
                        else {sleepToken=null;mapOf("sleepIntent" to token)}
                    }
                    else -> throw IllegalArgumentException("unsupported")
                }.also {check(LuaValue.encode(it).size<=8192)}
            }
            OLog.i("library.reminders ms=${(System.nanoTime()-start)/1_000_000}")
            main.post {
                result.fold({value ->
                    if(value["sleepIntent"]!=null) {
                        val error=OrbitService.current?.reminderSleepNow() ?: "unavailable"
                        if(error=="ok") queue.execute {
                            val token=value["sleepIntent"] as String
                            grant?.takeIf {it.token==token}?.let {service?.retire(it);grant=null}
                            if(sleepAttempt==token) {sleepToken=null;sleepAttempt=null}
                            main.post {done(mapOf("ok" to true),null)}
                        }
                        else queue.execute {
                            // A failed native attempt may be tried again only by fresh input
                            // in the same still-visible sheet. No autonomous retry is queued.
                            val token=value["sleepIntent"] as String
                            val rt=runtime
                            if(sleepAttempt==token && rt!=null && rt.owner==args["owner"] && rt.visible && rt.presenting && !rt.modal && !rt.sleeping) sleepToken=token
                            done(null,error)
                        }
                    } else done(value,null)
                },{done(null,if(it is IllegalArgumentException) it.message?.takeIf {m -> m in setOf("limit","conflict")} ?: "invalid" else "storage")})
            }
        }
    }
}
