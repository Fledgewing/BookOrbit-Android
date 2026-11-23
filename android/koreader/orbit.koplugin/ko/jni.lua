-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- JNI: explicit broadcasts, activities, screen state, VPN state, launch extras
-- Built on KOReader's own JNI bridge (android-luajit-launcher assets/android.lua:1400-1416,
-- JNI:context, with the raw JNIEnv). Every Java call is checked for a pending exception,
-- because calling on with one pending aborts the VM.
---------------------------------------------------------------------------------------------

Jni = {}

FLAG_INCLUDE_STOPPED_PACKAGES = 0x00000020
FLAG_RECEIVER_FOREGROUND = 0x10000000
FLAG_ACTIVITY_NEW_TASK = 0x10000000
TRANSPORT_VPN = 4

function int32(n) return ffi.new("int32_t", n) end

function check(env, what)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionClear(env)
        error("java exception in " .. what, 0)
    end
end

function del(env, obj)
    if obj ~= nil then env[0].DeleteLocalRef(env, obj) end
end

function methodId(env, obj, name, sig)
    local cls = env[0].GetObjectClass(env, obj)
    local id = env[0].GetMethodID(env, cls, name, sig)
    del(env, cls)
    if id == nil then
        env[0].ExceptionClear(env)
        error("no method " .. name .. sig, 0)
    end
    return id
end

function callObject(env, obj, name, sig, ...)
    local r = env[0].CallObjectMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
    return r
end

function callVoid(env, obj, name, sig, ...)
    env[0].CallVoidMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
end

function callBool(env, obj, name, sig, ...)
    local r = env[0].CallBooleanMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
    return r ~= 0
end

function callInt(env, obj, name, sig, ...)
    local r = env[0].CallIntMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
    return tonumber(r)
end

function withEnv(what, fn)
    if not has_android or not android.app then return nil, "no android bridge" end
    -- Results travel through upvalues: JNI:context returns unpack({...}), which drops
    -- values after a leading nil.
    local ra, rb, err
    local ok, ctx_err = pcall(android.jni.context, android.jni, android.app.activity.vm, function(jni)
        local env = jni.env
        local ok_inner, a, b = pcall(fn, env, android.app.activity.clazz, jni)
        if env[0].ExceptionCheck(env) ~= 0 then
            env[0].ExceptionClear(env)
            if ok_inner then ok_inner, a = false, "java exception" end
        end
        if ok_inner then ra, rb = a, b else err = a end
    end)
    if not ok then err = ctx_err end
    if err ~= nil then
        log(what, "failed:", tostring(err))
        return nil, err
    end
    return ra, rb
end

-- spec: { action, package?, class?, extras = { k = "string" }, flags? }
function newIntent(env, spec)
    local cls = env[0].FindClass(env, "android/content/Intent")
    check(env, "FindClass Intent")
    local ctor = env[0].GetMethodID(env, cls, "<init>", "(Ljava/lang/String;)V")
    check(env, "Intent.<init>")
    local jaction = env[0].NewStringUTF(env, spec.action)
    local intent = env[0].NewObject(env, cls, ctor, jaction)
    check(env, "new Intent")
    del(env, jaction)
    del(env, cls)
    if spec.class then
        local p = env[0].NewStringUTF(env, spec.package)
        local c = env[0].NewStringUTF(env, spec.class)
        del(env, callObject(env, intent, "setClassName",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;", p, c))
        del(env, p); del(env, c)
    elseif spec.package then
        local p = env[0].NewStringUTF(env, spec.package)
        del(env, callObject(env, intent, "setPackage", "(Ljava/lang/String;)Landroid/content/Intent;", p))
        del(env, p)
    end
    for k, v in pairs(spec.extras or {}) do
        local jk = env[0].NewStringUTF(env, k)
        local jv = env[0].NewStringUTF(env, tostring(v))
        del(env, callObject(env, intent, "putExtra",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;", jk, jv))
        del(env, jk); del(env, jv)
    end
    if spec.flags then
        del(env, callObject(env, intent, "addFlags", "(I)Landroid/content/Intent;", int32(spec.flags)))
    end
    return intent
end

function Jni.sendBroadcast(spec)
    spec.flags = (spec.flags or 0) + FLAG_INCLUDE_STOPPED_PACKAGES + FLAG_RECEIVER_FOREGROUND
    return withEnv("broadcast " .. spec.action, function(env, activity)
        local intent = newIntent(env, spec)
        callVoid(env, activity, "sendBroadcast", "(Landroid/content/Intent;)V", intent)
        del(env, intent)
        return true
    end)
end

function Jni.startActivity(spec)
    spec.flags = (spec.flags or 0) + FLAG_ACTIVITY_NEW_TASK
    return withEnv("startActivity " .. spec.action, function(env, activity)
        local intent = newIntent(env, spec)
        callVoid(env, activity, "startActivity", "(Landroid/content/Intent;)V", intent)
        del(env, intent)
        return true
    end)
end

function systemService(env, activity, name)
    local jname = env[0].NewStringUTF(env, name)
    local svc = callObject(env, activity, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", jname)
    del(env, jname)
    return svc
end

-- PowerManager.isInteractive(): false once the screen is off. nil if unknown.
function Jni.isInteractive()
    return withEnv("isInteractive", function(env, activity)
        local pm = systemService(env, activity, "power")
        if pm == nil then error("no PowerManager", 0) end
        local on = callBool(env, pm, "isInteractive", "()Z")
        del(env, pm)
        return on
    end)
end

-- WifiManager.isWifiEnabled(): the radio, not the connection. nil if unknown.
-- KOReader's Android backend only knows "connected" (device.lua:335-341, isWifiOn = isConnected).
-- Wi-Fi radio on? true/false, nil if unknown. Not WifiManager.isWifiEnabled(): KOReader's
-- manifest has no ACCESS_WIFI_STATE (android-luajit-launcher app/src/main/AndroidManifest.xml:
-- INTERNET, ACCESS_NETWORK_STATE, ...), so that call throws SecurityException. Settings.Global
-- "wifi_on" (Settings.Global.WIFI_ON) needs no permission: 1 on, 2 on in airplane mode, 0 off,
-- 3 off by airplane mode.
function Jni.wifiEnabled()
    return withEnv("wifi_on", function(env, activity)
        local cr = callObject(env, activity, "getContentResolver", "()Landroid/content/ContentResolver;")
        if cr == nil then error("no ContentResolver", 0) end
        local cls = env[0].FindClass(env, "android/provider/Settings$Global")
        check(env, "FindClass Settings$Global")
        local mid = env[0].GetStaticMethodID(env, cls, "getInt", "(Landroid/content/ContentResolver;Ljava/lang/String;I)I")
        check(env, "Settings.Global.getInt")
        local key = env[0].NewStringUTF(env, "wifi_on")
        local v = tonumber(env[0].CallStaticIntMethod(env, cls, mid, cr, key, int32(-1)))
        check(env, "Settings.Global.getInt wifi_on")
        del(env, key)
        del(env, cls)
        del(env, cr)
        return Plan.wifiOnSetting(v)
    end)
end

-- PackageManager.getApplicationEnabledSetting(pkg): 0 default, 1 enabled, 2/3/4 disabled.
-- nil when the package isn't installed (it throws IllegalArgumentException).
function Jni.appEnabledSetting(pkg)
    return withEnv("getApplicationEnabledSetting " .. pkg, function(env, activity)
        local pm = callObject(env, activity, "getPackageManager", "()Landroid/content/pm/PackageManager;")
        if pm == nil then error("no PackageManager", 0) end
        local jp = env[0].NewStringUTF(env, pkg)
        local okc, v = pcall(callInt, env, pm, "getApplicationEnabledSetting", "(Ljava/lang/String;)I", jp)
        del(env, jp)
        del(env, pm)
        if not okc then return false end -- missing: false, so withEnv doesn't log it as a failure
        return v
    end)
end

-- Whether any network has the VPN transport (Tailscale up). nil if unknown.
function Jni.vpnActive()
    return withEnv("vpnActive", function(env, activity)
        local cm = systemService(env, activity, "connectivity")
        if cm == nil then error("no ConnectivityManager", 0) end
        local nets = callObject(env, cm, "getAllNetworks", "()[Landroid/net/Network;")
        local found = false
        if nets ~= nil then
            local n = env[0].GetArrayLength(env, nets)
            for i = 0, n - 1 do
                local net = env[0].GetObjectArrayElement(env, nets, i)
                check(env, "GetObjectArrayElement")
                local caps = callObject(env, cm, "getNetworkCapabilities",
                    "(Landroid/net/Network;)Landroid/net/NetworkCapabilities;", net)
                if caps ~= nil then
                    if callBool(env, caps, "hasTransport", "(I)Z", int32(TRANSPORT_VPN)) then found = true end
                    del(env, caps)
                end
                del(env, net)
                if found then break end
            end
            del(env, nets)
        end
        del(env, cm)
        return found
    end)
end

-- Reads and removes a string extra from the activity's current intent (the launch intent,
-- or the latest one: MainActivity.onNewIntent calls setIntent, android-luajit-launcher
-- MainActivity.kt:205-210).
-- An app's label ("Meebook Launcher"), also when it's disabled; false when missing.
function Jni.appLabel(pkg)
    return withEnv("appLabel " .. pkg, function(env, activity, jni)
        local pm = callObject(env, activity, "getPackageManager", "()Landroid/content/pm/PackageManager;")
        if pm == nil then error("no PackageManager", 0) end
        local jp = env[0].NewStringUTF(env, pkg)
        local label = false
        local oka, ai = pcall(callObject, env, pm, "getApplicationInfo", "(Ljava/lang/String;I)Landroid/content/pm/ApplicationInfo;", jp, 0x200)
        if oka and ai ~= nil then
            local okl, cs = pcall(callObject, env, pm, "getApplicationLabel", "(Landroid/content/pm/ApplicationInfo;)Ljava/lang/CharSequence;", ai)
            if okl and cs ~= nil then
                local okt, js = pcall(callObject, env, cs, "toString", "()Ljava/lang/String;")
                if okt and js ~= nil then label = jni:to_string(js); del(env, js) end
                del(env, cs)
            end
            del(env, ai)
        end
        del(env, jp)
        del(env, pm)
        return label
    end)
end

function Jni.takeIntentExtra(key)
    return withEnv("takeIntentExtra", function(env, activity, jni)
        local intent = callObject(env, activity, "getIntent", "()Landroid/content/Intent;")
        if intent == nil then return false end
        local jk = env[0].NewStringUTF(env, key)
        local jv = callObject(env, intent, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;", jk)
        local value = false
        if jv ~= nil then
            value = jni:to_string(jv)
            del(env, jv)
            callVoid(env, intent, "removeExtra", "(Ljava/lang/String;)V", jk)
        end
        del(env, jk)
        del(env, intent)
        return value
    end)
end

---------------------------------------------------------------------------------------------
