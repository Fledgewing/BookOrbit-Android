-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bounded local-setting observations/actions. The companion chooses, labels and counts rows.
Recommendations={items={},snapshot={items={}}}
local function context() local ui=liveUI();return ui and ui.gestures end
local function equal(a,b)
    if a==b then return true end
    if type(a)~="table" or type(b)~="table" then return false end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function observe(item,raw)
    local unavailable=(item.needs and not Companion.has(item.needs)) or
        item.required_by=="wifi" and not S.wifi_via_companion
    local obs
    if item.kind=="connector" then obs=Library.observeSetting and Library.observeSetting(item) or {available=false,reason="Connector unavailable"}
    elseif item.kind=="ko" then obs={available=true,current=G_reader_settings:readSetting(item.key)}
    elseif item.kind=="gesture" then
        local g=context();local defaults=g and g.default_settings and g.default_settings.data
        if g and defaults and defaults.gesture_reader then
            obs={available=true,current=(g.data.gesture_reader or {})[item.key],default=defaults.gesture_reader[item.key]}
        else obs={available=false,reason="Turn on KOReader's Gestures plugin"} end
    else obs={available=false} end
    if unavailable and not raw then obs.available=false;obs.reason="Needs companion capability" end
    return obs
end
local function write(item,value)
    if item.kind=="connector" then return Library.writeSetting and Library.writeSetting(item,value) end
    if item.kind=="ko" then
        if value==nil then G_reader_settings:delSetting(item.key) else G_reader_settings:saveSetting(item.key,value) end
        return true
    end
    local g=context();if not g then return false end
    g.data.gesture_reader=g.data.gesture_reader or {};g.data.gesture_reader[item.key]=value;g.updated=true
    if g.onFlushSettings then g:onFlushSettings() end;return true
end
function Recommendations.pass(why,choices,lost,done)
    if Recommendations.pending then return end
    if #Recommendations.items==0 then
        Recommendations.pending=true
        return Library.recommendations({definitions=true},function(result)
            if result.error then Recommendations.pending=nil;return end
            Recommendations.items=result.items or {};if #Recommendations.items>0 then Recommendations.pass(why,choices,lost,done) end
        end)
    end
    local observations={}
    for i,item in ipairs(Recommendations.items) do if i<=8 then observations[item.id]=observe(item) end end
    Recommendations.pending=true
    return Library.recommendations({observations=observations,record=S.recommended,backup=S.recommended_backup,choices=choices,lost=lost,wifi=S.wifi_via_companion and Companion.has("wifi")},function(result)
        Recommendations.pending=nil;if result.error then return end
        -- Persist backups before native writes. An interrupted pass can recover Undo.
        S.recommended_backup=result.backup
        S.recommended=S.recommended or {items={}}
        S.recommended.items=S.recommended.items or {}
        for _,op in ipairs(result.writes or {}) do S.recommended.items[op.id]="unavailable" end
        saveSettings()
        local failed={}
        for i,op in ipairs(result.writes or {}) do
            if i>8 then break end
            for _,item in ipairs(Recommendations.items) do
                if item.id==op.id then
                    -- A user action while the worker ran wins; never overwrite it on return.
                    local same=equal(observe(item,true).current,op.expected)
                    local worked,took=false,false
                    if same then worked,took=pcall(write,item,op.value) end
                    if not same or not worked or not took then
                        failed[#failed+1]=op.id;result.record.items[op.id]="unavailable"
                    end
                end
            end
        end
        S.recommended,S.recommended_backup=result.record,result.backup;saveSettings()
        local actual={}
        for _,item in ipairs(Recommendations.items) do actual[item.id]=observe(item) end
        Library.recommendations({ack=true,observations=actual,record=result.record,backup=result.backup,wifi=S.wifi_via_companion and Companion.has("wifi")},function(snapshot)
            Recommendations.pending=nil;if snapshot.error then return end
            Recommendations.snapshot=snapshot
            if snapshot.line then Recommendations.line_pending=true end
            Recommendations.report(why,true)
            if Recommendations.onSnapshot then Recommendations.onSnapshot() end
            if done then done(snapshot) end
        end)
    end)
end
function Recommendations.report(why,force)
    local snapshot=Recommendations.snapshot
    Companion.send(Companion.ACTION.REPORT,{reason=why,signed_in=Library.cachedAccountState().signedIn and "1" or "0",recommended=snapshot.report or "none",conflicts=tostring(snapshot.conflicts or 0)})
end
function Recommendations.applyChoices(why)
    local choices={}
    for _,c in ipairs(SettingsSync.choices(S.recommended_choice)) do choices[c.id]=c.what end
    if next(choices) then Recommendations.pass(why,choices,false,function() Shared.set("recommended_choice","") end) end
end
function OrbitAndroid:recommendedPass(why)
    Recommendations.pass(why,nil,false,function() self:maybeRecommendedLine() end)
end
function OrbitAndroid:maybeRecommendedLine(where)
    if not Recommendations.line_pending or (where or self:whereNow())=="reader" then return end
    Recommendations.line_pending=false
    if Recommendations.snapshot.line then orbitNote(Recommendations.snapshot.line.." · Tools › BookSync › Recommended settings",4) end
end
function OrbitAndroid:recommendedMenuText()
    local line=Recommendations.snapshot.line
    return line and ("Recommended settings: "..line) or "Recommended settings"
end
function OrbitAndroid:showRecommended(why)
    local finish=Budgets.span("recommendations.draw",now_s,log)
    local paint=Library.paint("settings-recommendations")
    local snapshot=paint:widget("recommendations"):read("settings.recommendations",{limit=8}) or {items={}}
    paint:flush(true)
    local items={}
    local function choice(id,what)
        if what=="mine" then
            for _,item in ipairs(snapshot.items or {}) do
                if (id==item.id or id=="all") and item.state=="conflict" and item.needs_wifi then
                    S.wifi_via_companion=false;saveSettings()
                end
            end
        end
        Recommendations.pass("review",{[id]=what},false)
    end
    if snapshot.use_all then
        items[#items+1]={text="Use all of BookSync's",callback=function() choice("all","ours") end}
        items[#items+1]={text="Keep all mine",callback=function() choice("all","mine") end}
    end
    local section
    for i,row in ipairs(snapshot.items or {}) do
        if i>8 then break end
        local item=row
        if item.section~=section then
            section=item.section;items[#items+1]={text=section,bold=true,callback=function() end}
        end
        items[#items+1]={text=item.label,mandatory=item.state=="applied" and (tostring(item.orbit).." (was: "..tostring(item.was)..")") or item.state=="unavailable" and item.reason or tostring(item.yours or ""),
            dim=item.state=="already" or item.state=="unavailable",callback=function()
            if item.state=="already" or item.state=="unavailable" then return end
            local d
            d=require("ui/widget/buttondialog"):new{title=item.label,buttons={{
                {text="Use BookSync's",callback=function() UIManager:close(d);choice(item.id,"ours") end},
                {text=item.state=="applied" and "Undo" or "Keep mine",callback=function()
                    UIManager:close(d)
                    local function apply()
                        if item.needs_wifi then S.wifi_via_companion=false;saveSettings() end
                        choice(item.id,item.state=="applied" and "undo" or "mine")
                    end
                    if item.state=="applied" and item.needs_wifi then
                        UIManager:show(ConfirmBox:new{text="Wi-Fi switching needs this. Turn it off and undo?",ok_callback=apply}) -- gate: user action (Recommended settings menu)
                    else apply() end
                end}}}}
            UIManager:show(d) -- gate: user action (Recommended settings menu)
        end}
    end
    if snapshot.undo_all then items[#items+1]={text="Undo all",callback=function() choice("all","undo") end} end
    if #items==0 then items[1]={text="Preparing recommended settings…"};Recommendations.pass(why) end
    if S.recommended then S.recommended.unseen=0;saveSettings() end
    items[#items+1]={text="Done",callback=function() if self.rec_menu then UIManager:close(self.rec_menu);self.rec_menu=nil end end}
    self.rec_menu=require("ui/widget/menu"):new{title="Recommended settings",item_table=items,is_borderless=true,covers_fullscreen=true}
    UIManager:show(self.rec_menu) -- gate: user action (Recommended settings menu)
    local visible=self.rec_menu
    Recommendations.onSnapshot=function()
        if self.rec_menu~=visible or UIManager:getTopmostVisibleWidget()~=visible then return end
        UIManager:close(visible);self.rec_menu=nil;self:showRecommended("refresh")
    end
    finish();return self.rec_menu
end
function silentWifiOn() -- first pass runs after the neutral library has loaded
    UIManager:nextTick(function() Recommendations.pass("load") end)
end
