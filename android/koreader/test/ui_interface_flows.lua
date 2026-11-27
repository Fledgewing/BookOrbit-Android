-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Exercise the public intent contract with private dependencies available only to the service.
return function(here,test,eq,ok)
    local root=here.."/../orbit.koplugin/"
    local function world()
        local e=setmetatable({Library={},S={settings_at={},home_screen="booksync"},SCHEMA={byKey={}},
            saves=0,log=function() end,now_s=function() return 42 end,
            state={},NativeRetirement={plan={actions={{id="fixture"}}}},
            SettingsUI={modeKeys={"wifi_mode","sync_on_sleep"}},
            Shared={mode=function() return "jit" end},WifiPlan={modeLabel=function(value) return value.." label" end},
            Companion={ACTION={SHOW_PIN="pin",SHOW_SETUP="setup",SHOW_STATUS="status",SETUP_LATER="later",REPORT="report"},
                EXTRA_COMMAND="command",EXTRA_FROM="from",EXTRA_ROTATION="rotation"},
            Jni={},Recommendations={snapshot={items={}},line_pending=false}}, {__index=_G})
        e.saveSettings=function() e.saves=e.saves+1 end
        e.require=function(name) if name=="dkjson" then return dofile(here.."/json_mini.lua") end; return require(name) end
        for _,name in ipairs({"logic/ui_util.lua","logic/cache.lua","logic/layout.lua","logic/settings_sync.lua","ko/layout_store.lua","ko/library_services.lua"}) do
            setfenv(assert(loadfile(root..name)),e)()
        end
        return e,e.Library
    end
    test("UI interface: settings retain shared timestamps and local writes stay local",function()
        local e,L=world(); local pushes=0
        e.Shared.set=function(key,value) e.S[key]=value; e.S.settings_at[key]=42; pushes=pushes+1 end
        e.Shared.onChange=function(key,why) eq(key,"wifi_mode");eq(why,"menu") end
        e.Shared.refresh=function(why) eq(why,"menu");return true end
        e.Shared.setupNeededText=function() return "setup needed" end
        e.Shared.pin_locked=true
        eq(L.settings.read("home_screen"),"booksync");eq(L.settings.schema(),e.SCHEMA)
        L.settings.write("news_012_pending",false);eq(e.saves,1);eq(pushes,0)
        local pair={1,2};L.settings.writePair("font",pair);eq(e.S.reading_pairs.font,pair);eq(e.saves,2)
        L.settings.set("wifi_mode","jit");eq(e.S.settings_at.wifi_mode,42);eq(pushes,1)
        L.settings.onChange("wifi_mode","menu");eq(L.settings.refresh("menu"),true)
        eq(L.settings.mode(),"jit");eq(L.settings.wifiLabel(),"jit label");eq(L.settings.setupNeededText(),"setup needed");eq(L.settings.status("pin_locked"),true)
        eq(L.settings.read().wifi_mode,"jit");eq(L.settings.read().settings_at,nil,"presentation gets no private timestamp map")
        local d={type="bool"};eq(L.settings.fromWire(d,L.settings.toWire(d,true)),true)
    end)
    test("UI interface: launch consumes all extras and authenticates before dispatch",function()
        local e,L=world();local extras,seen={},{}
        e.Jni.takeIntentExtra=function(key) seen[#seen+1]=key;local v=extras[key];extras[key]=nil;return v end
        e.Companion.confirmCommand=function(cmd) return cmd=="home" end
        eq(L.launch.intake("test"),nil);eq(#seen,1)
        extras={command="restart",from="other_app",rotation="1"};seen={}
        eq(L.launch.intake("test"),nil);eq(#seen,3);eq(next(extras),nil)
        extras={command="home",from="other_app",rotation="1"}
        local cmd,from,held=L.launch.intake("test");eq(cmd,"home");eq(from,"other_app");eq(held,"1")
        eq(L.launch.intake("test"),nil,"consumed command cannot be replayed")
        e.patchFileVersion=function() return "0.12.1" end;eq(L.launch.patchVersion(),"0.12.1")
        local reader={restartForCompanion=function(_,why,quit) eq(why,"test");eq(quit,true);return "restart" end,
            reopenAfterRestart=function(_,why) eq(why,"test");return "open" end}
        eq(L.launch.restart(reader,"test",true),"restart");eq(L.launch.reopen(reader,"test"),"open")
        e.state.pending_home=true;eq(L.launch.finishPendingHome(),true);eq(L.launch.finishPendingHome(),false)
    end)
    test("UI interface: companion status and activity fallback remain behind intent names",function()
        local e,L=world();local sent,opened={},{}
        e.Companion.state=function() return "frozen" end;e.Companion.disabledText=function() return "disabled" end
        e.Companion.has=function(cap) return cap=="wifi" end;e.Companion.installed=function() return true end
        e.Companion.workerProblem=function(why) return "needed "..why end
        e.Companion.send=function(action,extras) sent={action=action,extras=extras} end
        e.Jni.startActivity=function(args) opened[#opened+1]=args.action;return args.action~="setup" end
        e.CompanionActivities={openStatus=function() return "status" end,openHome=function() return "home" end,openApps=function() return "apps" end}
        eq(L.companion.status(),"frozen");eq(L.companion.disabledText(),"disabled");eq(L.companion.has("wifi"),true)
        eq(L.companion.has("missing"),false);eq(L.companion.installed(),true);eq(L.companion.workerProblem("Battery"),"needed Battery")
        eq(L.companion.openStatus(),"status");eq(L.companion.openHome(),"home");eq(L.companion.openApps(),"apps")
        eq(L.companion.openPin(),true);eq(L.companion.openSetup(),true);eq(table.concat(opened,","),"pin,setup,status")
        L.companion.setupLater();eq(sent.action,"later")
        e.Library.cachedAccountState=function() return {signedIn=true} end
        L.report.send("test",{report="ready",conflicts=2});eq(sent.action,"report");eq(sent.extras.signed_in,"1");eq(sent.extras.conflicts,"2")
        e.Library.cachedAccountState=function() return {} end
        L.report.send("test",{});eq(sent.extras.signed_in,"0");eq(sent.extras.recommended,"none");eq(sent.extras.conflicts,"0")
    end)
    test("UI interface: sleep facade preserves late-bound callbacks and every existing operation",function()
        local e,L=world();e.Sleep={}
        for name,fn in pairs(L.sleep) do
            e.Sleep[name]=function(why,done) eq(why,"test");done("ready");return true end
            local delivered
            eq(fn("test",function(value) delivered=value end),true);eq(delivered,"ready",name)
        end
    end)
    test("UI interface: recommendation choices persist Wi-Fi intent before the worker pass",function()
        local e,L=world();local args
        e.Recommendations.pass=function(...) args={...};return true end
        e.S.wifi_via_companion=true
        local snapshot={items={{id="wifi",state="conflict",needs_wifi=true}}}
        ok(L.preferences.choose(snapshot,"wifi","mine"));eq(e.S.wifi_via_companion,false);eq(e.saves,1)
        eq(args[1],"review");eq(args[2].wifi,"mine")
        L.preferences.pass("test",nil,true);eq(args[1],"test");eq(args[3],true)
        e.Recommendations.line_pending=true;e.Recommendations.snapshot={line="new",seen_line="seen"}
        eq(L.preferences.takeLine(),"new");eq(L.preferences.takeLine(),nil)
        eq(L.preferences.menuLine(),"new");e.S.recommended={unseen=3};L.preferences.seen()
        eq(e.S.recommended.unseen,0);eq(L.preferences.menuLine(),"seen");eq(e.saves,2)
        local fn=function() end;L.preferences.subscribe(fn);eq(e.Recommendations.onSnapshot,fn)
    end)
    test("UI interface: setup prompt policy persists once and stays silent in a book",function()
        local e,L=world()
        setfenv(assert(loadfile(root.."logic/prompts.lua")),e)()
        e.Companion.has=function(cap) return cap=="setup" end
        e.Shared.setup_prompt={key="fixture",rows={"Permission"}}
        eq(L.setupPrompt("test","reader"),nil);eq(e.saves,0)
        ok(L.setupPrompt("test","menu"):find("Permission",1,true));eq(e.saves,1)
        eq(L.setupPrompt("test","menu"),nil);eq(e.saves,1)
    end)
    test("UI interface: resources load the same bundled data and fail when absent",function()
        local e,L=world();e.SOURCE_DIR=root:gsub('/$','');e.SettingsSync.decodeJson=dofile(here.."/json_mini.lua").decode
        local credits=L.resources.about();ok(type(credits.paragraphs)=="table");ok(credits.url)
        ok(type(L.resources.battery())=="table")
        e.SOURCE_DIR="/absent-fixture";eq(pcall(L.resources.about),false);eq(pcall(L.resources.battery),false)
    end)
    test("UI interface: layout primary and backup remain delegated to the existing validator",function()
        local e,L=world();local files={};e.S.home_layout={retained=true}
        e.Store={readFile=function(path) return files[path] end,writeFile=function(path,raw) files[path]=raw;return true end}
        L.layout.path=function() return "layout" end
        L.layout.load();eq(e.S.home_layout.retained,true,"no persisted layout retains host memory")
        local documents={};local seq=0
        L.layout.codec=function() return {encode=function(d) seq=seq+1;documents[tostring(seq)]=e.Layout.copy(d);return tostring(seq) end,
            decode=function(raw) return e.Layout.copy(documents[raw]) end} end
        -- Production layout validation uses the installed registry; existing editor flows cover failures too.
        setfenv(assert(loadfile(root.."logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root.."logic/widget_registry.lua")),e)()
        local d=e.Layout.default();ok(L.layout.save(d));eq(e.S.home_layout,d)
        L.layout.loaded=nil;L.layout.load();ok(e.Layout.validate(e.S.home_layout))
        ok(L.layout.save(d));ok(files["layout.bak"])
        files.layout="corrupt";L.layout.loaded=nil;L.layout.load();ok(e.Layout.validate(e.S.home_layout));ok(L.layout.notice)
    end)
end
