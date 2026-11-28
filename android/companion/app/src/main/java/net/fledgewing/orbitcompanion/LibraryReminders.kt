// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

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

/** Only local registers in 0.12. No server/account or catalog dependency. Every command
 * uses one worker, bounded values and device lifetime, never an Activity or notification. */
object LibraryReminders {
    private val queue=Executors.newSingleThreadExecutor()
    private val main by lazy {Handler(Looper.getMainLooper())}
    private var service: Reminders?=null
    private var store: RemindersStore?=null
    private var grant: Reminders.Grant?=null
    private var sleepToken: String?=null
    private var inputSerial: String?=null
    private var lastInput=0L
    private var runtime: Reminders.Runtime?=null
    private fun service(): Reminders = service ?: run {
        val file=File(Environment.getExternalStorageDirectory(),"koreader/settings/booksync-reminders.sqlite3")
        val sql=AndroidSql(file)
        try {
            val storage=RemindersStore(sql)
            Reminders(storage,System::currentTimeMillis,SystemClock::elapsedRealtime,ZoneId::systemDefault).also {service=it;store=storage}
        } catch(e:Exception) {sql.close();throw e}
    }
    private fun available(ctx:Context)=Net.adminActive(ctx) && OrbitService.current!=null && Mode.caps(ctx).contains("screen_off")
    private fun snapshot(ctx:Context,s:Reminders)=s.snapshot(!DateFormat.is24HourFormat(ctx))+mapOf(
        "state" to if(store?.recovered==true) "recovered" else "ready",
        "notice" to if(store?.recovered==true) "Previous reminders recovered" else null,
        "capabilities" to mapOf("reminders" to mapOf("kinds" to listOf("time","interval"),"timeLimit" to 8,
            "intervalLimit" to 1,"messageCharacters" to 60,"messageBytes" to 240,"localOnly" to true,"sleepAvailable" to available(ctx))))
    private fun payload(ctx:Context,s:Reminders,d:Reminders.Due):Map<String,Any?> {
        val r=s.records().first {it.id==d.id}
        val formatter=DateTimeFormatter.ofPattern(if(DateFormat.is24HourFormat(ctx)) "HH:mm" else "h:mm a")
        return mapOf("event" to d.event,"id" to d.id,"revision" to d.revision,"source" to "local","kind" to d.kind,
            "message" to LuaValue.str(if(d.kind=="interval") Reminders.EYE_TEXT else r.message?.takeIf {it.isNotEmpty()} ?: Reminders.DEFAULT_TEXT),
            "dueLabel" to if(d.kind=="time" && d.missed) LuaValue.str("Due at "+Instant.ofEpochMilli(d.due).atZone(ZoneId.systemDefault()).format(formatter)) else null,
            "sleepAvailable" to available(ctx),"editable" to true,
            "expiresElapsed" to if(d.kind=="time") SystemClock.elapsedRealtime()+(d.expiry-System.currentTimeMillis()).coerceAtLeast(0) else null)
    }
    fun command(ctx:Context,op:String,args:Map<*,*>,done:(Map<String,Any?>?,String?)->Unit) {
        val app=ctx.applicationContext
        queue.execute {
            val start=System.nanoTime()
            val result=runCatching {
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
                        val now=SystemClock.elapsedRealtime()
                        val owner=text("owner");require(owner.length in 1..80)
                        val serial=text("input");require(serial.length in 1..80)
                        val age=number("age").coerceIn(0,Reminders.BREAK)
                        if(serial!=inputSerial) {inputSerial=serial;lastInput=(now-age).coerceAtLeast(0)}
                        val rt=Reminders.Runtime(owner,boolean("visible"),boolean("sleeping"),boolean("page"),boolean("modal"),lastInput,presenting=boolean("presenting"))
                        runtime=rt;s.activity(rt)
                        if(grant?.let {s.valid(it)}==false) grant=null
                        val due=s.candidates().take(8).map {payload(app,s,it)}
                        mapOf("due" to due,"grantValid" to (grant!=null))
                    }
                    "reminders.draft" -> {
                        val input=(args["inputTime"] as? String)?.let(LuaValue::utf8)
                        var fields=args.filterKeys {it!="inputTime"}
                        if(input!=null) {
                            val twelve=!DateFormat.is24HourFormat(app)
                            val pattern=if(twelve) Regex("([0-9]{1,2}):([0-9]{2}) (AM|PM)",RegexOption.IGNORE_CASE) else Regex("([0-9]{1,2}):([0-9]{2})")
                            val match=pattern.matchEntire(input.trim()) ?: throw IllegalArgumentException("time")
                            val hour=match.groupValues[1].toInt();val minute=match.groupValues[2].toInt()
                            require(minute in 0..59 && hour in if(twelve) 1..12 else 0..23)
                            val h=if(twelve) hour%12+(if(match.groupValues[3].equals("PM",true)) 12 else 0) else hour
                            fields=fields+mapOf("minuteOfDay" to h*60+minute)
                        }
                        require(fields.keys.all {it in setOf("id","revision","kind","enabled","minuteOfDay","days","message","intervalMinutes")})
                        val r=Reminders.Record(if(fields["kind"]=="interval") Reminders.INTERVAL else "local:00000000-0000-0000-0000-000000000000",
                            fields["kind"] as String,enabled=fields["enabled"] as Boolean,
                            minuteOfDay=(fields["minuteOfDay"] as? Number)?.toInt(),days=(fields["days"] as? Number)?.toInt(),
                            message=(fields["message"] as? String)?.let(LuaValue::utf8),intervalMinutes=(fields["intervalMinutes"] as? Number)?.toInt())
                        Reminders.validate(r)
                        s.presentation(r,!DateFormat.is24HourFormat(app)).filterKeys {it !in setOf("id","revision")}
                    }
                    "reminders.add" -> {
                        val r=fields();s.add(r.kind,r.enabled,r.minuteOfDay,r.days,r.message,r.intervalMinutes,text("mutation"));snapshot(app,s)
                    }
                    "reminders.edit" -> {
                        val r=fields();s.edit(text("id"),number("revision"),r.kind,r.enabled,r.minuteOfDay,r.days,r.message,r.intervalMinutes,text("mutation"));snapshot(app,s)
                    }
                    "reminders.setEnabled" -> {require(args.keys.all {it in setOf("id","revision","enabled","mutation")});s.setEnabled(text("id"),number("revision"),boolean("enabled"),text("mutation"));snapshot(app,s)}
                    "reminders.delete" -> {require(args.keys.all {it in setOf("id","revision","mutation")});s.delete(text("id"),number("revision"),text("mutation"));snapshot(app,s)}
                    "reminders.claimDue" -> {
                        val g=s.claim(text("event"),text("owner"))
                        if(g!=null) grant=g
                        if(g==null) mapOf("stale" to true) else payload(app,s,g.due)+mapOf("grant" to g.token,"owner" to g.owner)
                    }
                    "reminders.respond" -> {
                        val g=grant?.takeIf {it.token==text("grant") && it.owner==text("owner")}
                        if(g==null) mapOf("stale" to true) else {
                            val response=s.respond(g,text("action"),available(app))
                            if(response.accepted) grant=null
                            if(response.sleep) sleepToken=g.token
                            mapOf("accepted" to response.accepted,"stale" to !response.accepted,"sleep" to response.sleep)
                        }
                    }
                    "reminders.sleep" -> {
                        // Intent is issued only by an explicit response, consumed once. Sleep
                        // still requires the current visible owner and existing service path.
                        val token=text("grant");val rt=runtime
                        if(sleepToken!=token || rt?.owner!=text("owner") || !rt.visible || rt.sleeping || !available(app)) mapOf("error" to "unavailable")
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
                        done(if(error=="ok") mapOf("ok" to true) else null,if(error=="ok") null else error)
                    } else done(value,null)
                },{done(null,if(it is IllegalArgumentException) it.message?.takeIf {m -> m in setOf("limit","conflict")} ?: "invalid" else "storage")})
            }
        }
    }
}
