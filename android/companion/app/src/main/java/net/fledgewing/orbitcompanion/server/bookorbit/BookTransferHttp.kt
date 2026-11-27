// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** Bounded streaming with strong-validator range recovery; final identity validation belongs
 * to CatalogWorkflow. A server declining Range restarts safely on an explicit Resume. */
internal class BookTransferHttp(private val connect:(String)->HttpURLConnection = { URL(it).openConnection() as HttpURLConnection },
    private val space:(File)->Long = { it.parentFile!!.usableSpace }) {
    companion object { const val MAX=536870912L;const val RESERVE=200_000_000L }
    fun transfer(server:String,path:String,headers:Map<String,String>,part:File,
        progress:(Long,Long?)->Unit,canceled:()->Boolean):Boolean {
        val meta=File(part.path+".http-resume")
        require(listOf(part,meta,File(meta.path+".new")).none { java.nio.file.Files.isSymbolicLink(it.toPath()) })
        val identity=MessageDigest.getInstance("SHA-256").digest((server+path+headers["x-auth-user"]).toByteArray()).joinToString("") { "%02x".format(it) }
        val saved=CatalogWorkflow.load(meta).takeIf { it["identity"]==identity }.orEmpty()
        if(canceled()) throw ServerFailure("canceled")
        val savedBytes=(saved["bytes"] as? Number)?.toLong()
        if(saved["complete"]==true && savedBytes==part.length() && part.isFile) { progress(part.length(),part.length());return true }
        val validator=(saved["etag"] as? String)?.takeIf { it.length<=512 && it.startsWith('"') && it.endsWith('"') }
        var offset=part.length().takeIf { validator!=null && savedBytes==it && it in 1..MAX } ?: 0L
        val c=connect(server+path)
        try {
            c.instanceFollowRedirects=false;c.connectTimeout=15000;c.readTimeout=20000
            headers.forEach { (k,v)->c.setRequestProperty(k,v) }
            if(offset>0) { c.setRequestProperty("Range","bytes=$offset-");c.setRequestProperty("If-Range",validator) }
            val code=c.responseCode
            when(code) { 401,403->throw ServerFailure("unauthorized");200,206->Unit;else->throw ServerFailure("offline") }
            val total=if(code==206) {
                val range=Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(c.getHeaderField("Content-Range").orEmpty()) ?: throw ServerFailure("invalid")
                if(offset==0L || range.groupValues[1].toLong()!=offset) throw ServerFailure("invalid")
                range.groupValues[3].toLong()
            } else { offset=0;c.contentLengthLong.takeIf { it>=0 } }
            if(total!=null && (total>MAX || total<offset || space(part)<total-offset+RESERVE)) throw ServerFailure("space")
            val etag=c.getHeaderField("ETag")?.takeIf { it.length<=512 && it.startsWith('"') && it.endsWith('"') }
            if(code==206 && etag!=validator) throw ServerFailure("invalid")
            var bytes=offset;var published=offset
            fun checkpoint(complete:Boolean=false) {
                val temp=File(meta.path+".new")
                temp.writeBytes(LuaValue.encode(mapOf("identity" to identity,"etag" to etag,"bytes" to bytes,"total" to total,"complete" to complete)))
                check(temp.renameTo(meta))
            }
            checkpoint()
            try {
                c.inputStream.use { input -> java.io.FileOutputStream(part,offset>0).use { output ->
                    val buffer=ByteArray(65536)
                    while(true) {
                        if(canceled()) throw ServerFailure("canceled")
                        val n=input.read(buffer);if(n<0) break
                        if(bytes+n>MAX || space(part)<RESERVE+n) throw ServerFailure("space")
                        output.write(buffer,0,n);bytes+=n
                        if(bytes-published>=262144) { progress(bytes,total);checkpoint();published=bytes }
                    }
                    output.fd.sync()
                } }
            } catch(e:Exception) { checkpoint();throw e }
            progress(bytes,total)
            if(canceled()) throw ServerFailure("canceled")
            if(total!=null && bytes!=total) throw ServerFailure("retryable")
            checkpoint(true);return true
        } catch(e:ServerFailure) { throw e }
        catch(_:java.io.IOException) { throw ServerFailure("offline") }
        finally { c.disconnect() }
    }
}
