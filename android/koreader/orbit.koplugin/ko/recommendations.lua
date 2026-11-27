-- SPDX-License-Identifier: AGPL-3.0-or-later
function OrbitAndroid:recommendedPass(why)
    Library.preferences.pass(why,nil,false,function() self:maybeRecommendedLine() end)
end
function OrbitAndroid:maybeRecommendedLine(where)
    if (where or self:whereNow())=="reader" then return end
    local line=Library.preferences.takeLine()
    if line then orbitNote(line.." · Tools › BookSync › Recommended settings",4) end
end
function OrbitAndroid:recommendedMenuText()
    local line=Library.preferences.menuLine()
    return line and ("Recommended settings: "..line) or "Recommended settings"
end
function OrbitAndroid:showRecommended(why)
    local finish=Budgets.span("recommendations.draw",now_s,log)
    local paint=Library.paint("settings-recommendations")
    local snapshot=paint:widget("recommendations"):read("settings.recommendations",{limit=8}) or {items={}}
    paint:flush(true)
    local items={}
    local function choice(id,what)
        Library.preferences.choose(snapshot,id,what)
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
                        if item.needs_wifi then Library.preferences.keepWifi() end
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
    if #items==0 then items[1]={text="Preparing recommended settings…"};Library.preferences.pass(why) end
    Library.preferences.seen()
    items[#items+1]={text="Done",callback=function() if self.rec_menu then UIManager:close(self.rec_menu);self.rec_menu=nil end end}
    self.rec_menu=require("ui/widget/menu"):new{title="Recommended settings",item_table=items,is_borderless=true,covers_fullscreen=true}
    UIManager:show(self.rec_menu) -- gate: user action (Recommended settings menu)
    local visible=self.rec_menu
    Library.preferences.subscribe(function()
        if self.rec_menu~=visible or UIManager:getTopmostVisibleWidget()~=visible then return end
        UIManager:close(visible);self.rec_menu=nil;self:showRecommended("refresh")
    end)
    finish();return self.rec_menu
end
