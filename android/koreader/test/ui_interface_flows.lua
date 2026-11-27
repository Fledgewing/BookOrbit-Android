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
    -- Use the real settings service, merge policy, persistence ordering and wire echo.
    local function settingsWorld()
        local e,L=world()
        for _,name in ipairs({"logic/sleep_pool.lua","logic/settings_ui.lua","ko/shared.lua"}) do
            setfenv(assert(loadfile(root..name)),e)()
        end
        local f=assert(io.open(here.."/../../../shared/settings/schema.json"));local raw=f:read("*a");f:close()
        e.SCHEMA=e.SettingsSync.index(e.SettingsSync.decodeJson(raw))
        e.S.shared_settings_at=1
        e.sent={};e.effects={};e.saved={}
        e.saveSettings=function() e.saves=e.saves+1;e.saved=e.Cache.copy(e.S) end
        e.Companion.installed=function() return true end
        e.Companion.has=function() return true end
        e.Companion.ACTION.SETTINGS="settings"
        e.Companion.send=function(action,extras)
            eq(action,"settings");e.sent[#e.sent+1]=extras
            eq(e.saved.shared_settings_at,e.S.shared_settings_at,"save precedes push")
        end
        e.Wifi={applySettings=function() e.effects[#e.effects+1]="wifi" end}
        e.Shared.onSchedule=function(value) e.effects[#e.effects+1]="schedule:"..value end
        e.Sleep={changed=function() e.effects[#e.effects+1]="sleep" end}
        return e,L
    end
    test("Settings intents: single edit and toggle apply exactly once after save and push",function()
        local e,L=settingsWorld()
        e.Wifi.applySettings=function()
            eq(e.saves,1);eq(#e.sent,1);eq(e.saved.wifi_mode,"jit")
            e.effects[#e.effects+1]="wifi"
        end
        L.settings.set("wifi_mode","jit")
        eq(e.S.wifi_mode,"jit");eq(#e.effects,1)
        eq(e.S.settings_at.wifi_mode,e.S.shared_settings_at)
        -- The existing menu toggle used Shared.set without onChange; it must be complete too.
        e.Wifi.applySettings=function() e.effects[#e.effects+1]="wifi" end
        -- Load the public toggle with the same Library settings interface.
        e.OrbitAndroid={};setfenv(assert(loadfile(root.."ko/menu.lua")),e)()
        e.toggle("wifi_via_companion","Wi-Fi").callback()
        eq(e.S.wifi_via_companion,true);eq(#e.effects,2);eq(e.saves,2);eq(#e.sent,2)
        L.settings.write("news_012_pending",false);eq(e.saves,3);eq(#e.sent,2)
        eq(e.S.settings_at.news_012_pending,nil)
        local pair={1,2};L.settings.writePair("font",pair);eq(e.S.reading_pairs.font,pair)
        eq(L.settings.read().settings_at,nil)
        eq(L.settings.onChange,nil,"UI cannot split persistence from effects")
    end)
    test("Settings intents: preset publishes one complete snapshot before ordered effects",function()
        local e,L=settingsWorld();local values=e.SettingsUI.modes[3].values
        local function complete()
            eq(e.saves,1);eq(#e.sent,1)
            for _,key in ipairs(e.SettingsUI.modeKeys) do
                eq(e.S[key],values[key]);eq(e.saved[key],values[key])
                eq(e.S.settings_at[key],e.S.shared_settings_at)
            end
        end
        e.Wifi.applySettings=function() complete();e.effects[#e.effects+1]="wifi" end
        e.Shared.onSchedule=function(value) complete();e.effects[#e.effects+1]="schedule:"..value end
        L.settings.preset(values)
        eq(table.concat(e.effects,","),"wifi,wifi,schedule:min10")
        local wire=e.SettingsSync.decodeJson(e.sent[1].values)
        eq(wire.sync_on_wake.v,"1");eq(wire.reading_schedule.v,"min10")
    end)
    test("Settings intents: incoming newest-wins merge echoes once; replay has no effects",function()
        local e,L=settingsWorld()
        e.S.wifi_mode="always_on";e.S.settings_at.wifi_mode=5000
        e.S.reading_schedule="off";e.S.settings_at.reading_schedule=1
        e.Companion.status=function() return {settings={values={wifi_mode={v="jit",at=100},reading_schedule={v="min10",at=8000}}}} end
        e.Companion.updateCaps=function() return false end
        e.Clicks={parse=function() return {} end,count=0}
        e.Schedule={request=function() return nil end}
        e.MenuLock={locked=function() return false end}
        eq(L.settings.refresh("start"),true)
        eq(e.S.wifi_mode,"always_on");eq(e.S.reading_schedule,"min10")
        eq(e.S.settings_at.reading_schedule,8000);eq(e.saves,1);eq(#e.sent,1)
        eq(table.concat(e.effects,","),"schedule:min10")
        local wire=e.SettingsSync.decodeJson(e.sent[1].values)
        eq(wire.wifi_mode.at,5000);eq(wire.reading_schedule.at,8000)
        eq(L.settings.refresh("start"),false);eq(e.saves,1);eq(#e.effects,1)
        eq(#e.sent,2,"older remote Wi-Fi still needs an echo")
    end)
    test("Settings intents: failed follow-up preserves intent and later preset effects",function()
        local e,L=settingsWorld();local failures=0
        e.log=function(_,_,message) if message==": follow-up failed:" then failures=failures+1 end end
        e.Wifi.applySettings=function() error("fixture failure") end
        L.settings.preset(e.SettingsUI.modes[3].values)
        eq(failures,2);eq(e.saves,1);eq(#e.sent,1)
        eq(e.saved.wifi_mode,"always_on");eq(e.S.settings_at.wifi_mode,e.S.shared_settings_at)
        eq(table.concat(e.effects,","),"schedule:min10")
        L.settings.set("sleep_from","scope:42");eq(e.effects[2],"sleep")
        -- The older sleep interface delegates to the same complete intent, with no second effect.
        setfenv(assert(loadfile(root.."ko/sleep_backend.lua")),e)()
        e.Sleep.changed=function() e.effects[#e.effects+1]="sleep" end
        L.sleep.set("sleep_from","scope:43");eq(#e.effects,3)
        local commands=0
        L.backgroundCommand=function() commands=commands+1 end
        L.settings.set("recommended_choice","all=ours");eq(commands,1)
        L.settings.set("recommended_choice","");eq(commands,1,"worker acknowledgement must not apply again")
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
