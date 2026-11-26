-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Native reader adapter behind Library. No server contract is involved in local styles.
-- KOReader 9192014d: readerfont.lua:163-179,212-226,269-275;
-- readertypeset.lua:73-75,541-557; creoptions.lua:581-592 (gamma lookup).
local gamma = {.3,.35,.4,.45,.5,.55,.6,.65,.7,.75,.8,.85,.9,.95,.98,1,1.02,1.05,1.1,1.15,1.2,1.25,1.3,1.35,1.4,1.45,
    1.5,1.6,1.7,1.8,1.9,2,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3,3.5,4,4.5,5,5.5,6,7,8,9,10,11,12,13,14,15}
local function span(id) return Budgets.span("library.reading-style." .. id, now_s, log) end
local function scale(n) return require("device").screen:scaleBySize(n) end
local function nearestGamma(value)
    local best=1
    for i,v in ipairs(gamma) do if math.abs(v-value)<math.abs(gamma[best]-value) then best=i end end
    return best-1
end
function Library.readingCustom(screen)
    local finish=span("read")
    local b=Budgets.get("screens",screen or "settings-reading")
    assert(Budgets.check(b,{rows=1,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}))
    local record=ReadingStyle.record(S.custom_reading)
    finish(); return record
end
function Library.readingChoices(ui)
    if not ui then return {} end
    if not ui.booksync_reading_choices then
        ui.booksync_reading_choices = ui.doc_settings and ui.doc_settings:readSetting("booksync_reading_choices") or {}
    end
    return ui.booksync_reading_choices
end
function Library.readingSupported(ui)
    return ui and ui.rolling and ui.font and ui.typeset and ui.document and ui.document.setFontFace ~= nil
end
function Library.readingFace(index, copied)
    local f=ReadingStyle.fonts[index]
    local cre=require("document/credocument"):engineInit()
    local face=copied or f.face
    local path, faceindex=cre.getFontFaceFilenameAndFaceIndex(face)
    if not path then face=f.fallback; path,faceindex=cre.getFontFaceFilenameAndFaceIndex(face) end
    return face, path or f.file, faceindex
end
function Library.readingApply(ui,key,choice,deferUpdate,screen)
    local finish=span("apply")
    if not Library.readingSupported(ui) then finish(); return false end
    local custom=Library.readingCustom(screen or "reader-top-panel")
    local value
    if choice=="custom" then value=custom[key] else value=ReadingStyle.presets[key][choice][2] end
    local config=ui.font.configurable
    if key=="font" then
        local face
        if choice=="custom" then face=Library.readingFace(custom.fontIndex,custom.face)
        elseif value then face=Library.readingFace(value)
        else face=ui.document.default_font end
        ui.font.font_face=face; ui.document:setFontFace(face)
        config.font_base_weight=choice=="custom" and custom.weight or 0
        ui.document:setFontBaseWeight(config.font_base_weight)
        -- Book's own permits embedded fonts; the other choices use the selected face.
        ui.typeset.configurable.embedded_fonts=choice==1 and 1 or 0
        ui.document:setEmbeddedFonts(ui.typeset.configurable.embedded_fonts)
    elseif key=="margins" then
        local m=ui.typeset.unscaled_margins
        -- scaleBySize rounds up (koreader-base ffi/framebuffer.lua:414).
        -- Calibrate at a large size so a fractional screen scale is not rounded
        -- to the next whole factor, then guard floating-point ceil overshoot.
        local unscaled=value/(scale(10000)/10000)
        if scale(unscaled)>value then unscaled=unscaled-0.000001 end
        ui.typeset.configurable.h_page_margins={unscaled,unscaled}
        ui.typeset.unscaled_margins={unscaled,m[2],unscaled,m[4]}
        ui.typeset:onSetPageMargins(ui.typeset.unscaled_margins)
    elseif key=="spacing" then
        config.line_spacing=math.floor(value*100+.5)
        ui.document:setInterlineSpacePercent(config.line_spacing)
    elseif key=="contrast" then
        config.font_gamma=nearestGamma(1+value)
        ui.document:setGammaIndex(config.font_gamma)
    end
    local selected=Library.readingChoices(ui); selected[key]=choice
    if ui.doc_settings then ui.doc_settings:saveSetting("booksync_reading_choices",selected) end
    if not deferUpdate and key~="margins" then ui:handleEvent(require("ui/event"):new(key=="contrast" and "RedrawCurrentView" or "UpdatePos")) end
    finish(); return true
end
function Library.readingSave(record,ui,screen)
    local finish=span("save")
    local old=Library.readingCustom(screen)
    S.custom_reading=ReadingStyle.record(record); saveSettings()
    local changed,marginApplied,layoutChanged=false,false,false
    for _,key in ipairs({"font","spacing","contrast","margins"}) do
        local different=key=="font" and (old.fontIndex~=S.custom_reading.fontIndex or old.face~=S.custom_reading.face or old.weight~=S.custom_reading.weight)
            or key~="font" and old[key]~=S.custom_reading[key]
        if different and Library.readingChoices(ui)[key]=="custom" then
            local applied=Library.readingApply(ui,key,"custom",true,screen)
            changed=applied or changed
            layoutChanged=layoutChanged or (applied and key~="contrast")
            marginApplied=marginApplied or (key=="margins" and applied)
        end
    end
    if changed and not marginApplied then ui:handleEvent(require("ui/event"):new(layoutChanged and "UpdatePos" or "RedrawCurrentView")) end
    finish()
end
function Library.readingCopy(ui)
    local finish=span("copy")
    local f=Library.readingSupported(ui) and ui.font or nil
    local function value(key, default) return f and f.configurable[key] or G_reader_settings:readSetting("copt_" .. key) or default end
    local margins=f and ui.typeset.unscaled_margins or {20,0,20,0}
    if not f then
        local pair=G_reader_settings:readSetting("copt_h_page_margins")
        if type(pair)=="table" then margins={pair[1],0,pair[2],0} end
    end
    local face=f and f.font_face or G_reader_settings:readSetting("cre_font")
    local fontIndex=1
    for i,font in ipairs(ReadingStyle.fonts) do
        if face==font.face then fontIndex=i; face=nil; break end
    end
    local record={fontIndex=fontIndex,face=face,
        weight=value("font_base_weight",0),margins=scale(margins[1]),spacing=value("line_spacing",100)/100,
        contrast=(gamma[value("font_gamma",15)+1] or 1)-1}
    local copied,previous=ReadingStyle.copy(Library.readingCustom(),record)
    Library.readingSave(copied,ui); finish(); return previous
end

-- A book remembers which choices it uses; newly edited device-local Custom values take
-- effect when that book next opens. Restore silently, without opening a surface.
function Library.readingRestore(ui)
    if not Library.readingSupported(ui) then return end
    local applied,marginApplied,layoutChanged=false,false,false
    for _,key in ipairs({"font","spacing","contrast","margins"}) do
        if Library.readingChoices(ui)[key]=="custom" then
            applied=Library.readingApply(ui,key,"custom",true,"reader-top-panel") or applied
            layoutChanged=layoutChanged or key~="contrast"
            marginApplied=marginApplied or key=="margins"
        end
    end
    if applied and not marginApplied then ui:handleEvent(require("ui/event"):new(layoutChanged and "UpdatePos" or "RedrawCurrentView")) end
end
local baseReady=OrbitAndroid.onReaderReady
if baseReady then
    function OrbitAndroid:onReaderReady(...)
        local result=baseReady(self,...)
        Library.readingRestore(self.ui)
        return result
    end
end
