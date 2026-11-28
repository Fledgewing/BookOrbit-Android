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
    elseif item.kind=="owned" then obs={available=true,current=S[item.key]}
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
    if item.kind=="owned" then Library.setReaderMenus(liveUI(),value);return true end
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
            Recommendations.pending=nil
            Recommendations.items=result.items or {};if #Recommendations.items>0 then Recommendations.pass(why,choices,lost,done) end
        end)
    end
    local observations={}
    for i,item in ipairs(Recommendations.items) do if i<=10 then observations[item.id]=observe(item) end end
    local unseen=S.recommended and S.recommended.unseen or 0
    Recommendations.pending=true
    return Library.recommendations({observations=observations,record=S.recommended,backup=S.recommended_backup,choices=choices,lost=lost,wifi=S.wifi_via_companion and Companion.has("wifi")},function(result)
        if result.error then Recommendations.pending=nil;return end
        -- Persist backups before native writes. An interrupted pass can recover Undo.
        S.recommended_backup=result.backup
        S.recommended=S.recommended or {items={}}
        S.recommended.items=S.recommended.items or {}
        for _,op in ipairs(result.writes or {}) do S.recommended.items[op.id]="unavailable" end
        saveSettings()
        local failed={}
        for i,op in ipairs(result.writes or {}) do
            if i>10 then break end
            for _,item in ipairs(Recommendations.items) do
                if item.id==op.id then
                    -- A user action while the worker ran wins; never overwrite it on return.
                    local same=equal(observe(item,true).current,op.expected)
                    if same and op.guard_untouched then
                        for _,other in ipairs(Recommendations.items) do
                            if not other.untouched_only then
                                local actual=observe(other,true)
                                local state=S.recommended.items[other.id]
                                if state=="conflict" or state=="kept" or actual.available and
                                    not equal(actual.current,other.ours) and not equal(actual.current,actual.default) and
                                    not (other.stock~=nil and equal(actual.current,other.stock)) then same=false;break end
                            end
                        end
                    end
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
        Library.recommendations({ack=true,failed=failed,observations=actual,record=result.record,backup=result.backup,wifi=S.wifi_via_companion and Companion.has("wifi")},function(snapshot)
            Recommendations.pending=nil;if snapshot.error then return end
            Recommendations.snapshot=snapshot
            S.recommended=snapshot.record;saveSettings()
            if (snapshot.record.unseen or 0)>unseen then Recommendations.line_pending=true;Recommendations.reviewed=false end
            Recommendations.report(why,true)
            if Recommendations.onSnapshot then Recommendations.onSnapshot() end
            if done then done(snapshot) end
        end)
    end)
end
function Recommendations.report(why,force)
    local snapshot=Recommendations.snapshot
    return Library.report.send(why,Recommendations.snapshot)
end
function Recommendations.applyChoices(why)
    local choices={}
    for _,c in ipairs(SettingsSync.choices(S.recommended_choice)) do choices[c.id]=c.what end
    if next(choices) then Recommendations.pass(why,choices,false,function() Shared.set("recommended_choice","") end) end
end
function silentWifiOn() -- first pass runs after the neutral library has loaded
    UIManager:nextTick(function() Recommendations.pass("load") end)
end
