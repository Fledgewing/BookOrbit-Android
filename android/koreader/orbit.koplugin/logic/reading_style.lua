-- SPDX-License-Identifier: AGPL-3.0-or-later
-- One device-local record; no catalog, engine, IO or server dependencies.
ReadingStyle = {}
local R = ReadingStyle
R.keys = {"font", "margins", "spacing", "contrast"}
R.names = {font="Font", margins="Margins", spacing="Line spacing", contrast="Contrast"}
-- The prototype's named faces use bundled fallbacks when that face is not installed.
R.fonts = {
    {name="Baskerville", face="Baskerville", fallback="Noto Serif", file="NotoSerif-Regular.ttf"},
    {name="Literary", face="Literata", fallback="Noto Serif", file="NotoSerif-Regular.ttf"},
    {name="Classic", face="FreeSerif", fallback="FreeSerif", file="freefont/FreeSerif.ttf"},
    {name="Clean", face="Noto Sans", fallback="Noto Sans", file="NotoSans-Regular.ttf"},
}
R.limits = {font={-1,2,1}, margins={10,80,2}, spacing={1,2,.02}, contrast={-.5,.5,.1}}
R.presets = {
    font={{"Book's own", false},{"Literary", 2},{"Classic",3},{"Clean",4}},
    margins={{"Narrow",24},{"Medium",40},{"Wide",60}},
    spacing={{"Tight",1.35},{"Normal",1.5},{"Loose",1.7}},
    contrast={{"Soft",-.2},{"Normal",0},{"Dark",.2}},
}
R.defaultPairs = {font={1,2},margins={1,3},spacing={2,3},contrast={2,3}}
local function number(v, default)
    v=tonumber(v)
    return v and v==v and v~=math.huge and v~=-math.huge and v or default
end
function R.clamp(key, value)
    local l=assert(R.limits[key]); local v=number(value,l[1])
    local n=math.floor((math.max(l[1],math.min(l[2],v))-l[1])/l[3]+.5)
    return math.floor((l[1]+n*l[3])*100+.5)/100
end
function R.record(input)
    local s=type(input)=="table" and input or {}
    local out={fontIndex=math.max(1,math.min(#R.fonts,math.floor(number(s.fontIndex,1)))),
        weight=R.clamp("font",number(s.weight,1)), margins=R.clamp("margins",number(s.margins,46)),
        spacing=R.clamp("spacing",number(s.spacing,1.42)), contrast=R.clamp("contrast",number(s.contrast,.2))}
    -- A one-time copy may name any installed KOReader face (no installed-font scan).
    if type(s.face)=="string" and #s.face<=160 then out.face=s.face end
    return out
end
function R.copy(previous, current) return R.record(current), R.record(previous) end
function R.step(s,key,direction)
    local out=R.record(s); local field=key=="font" and "weight" or key
    out[field]=R.clamp(key,out[field]+R.limits[key][3]*direction)
    return out
end
function R.label(s,key)
    s=R.record(s)
    if key=="font" then return (s.face or R.fonts[s.fontIndex].name) .. (s.weight~=0 and string.format(" · weight %+d",s.weight) or "") end
    if key=="margins" then return s.margins .. " px" end
    if key=="spacing" then return string.format("%.2f",s.spacing) end
    if s.contrast==0 then return "Normal" end
    return (s.contrast<0 and "Lighter " or "Darker ") .. string.format("%.1f",math.abs(s.contrast))
end
function R.pair(key, saved)
    local p=type(saved)=="table" and saved[key] or nil
    if type(p)~="table" or not R.presets[key][p[1]] or not R.presets[key][p[2]] then p=R.defaultPairs[key] end
    return {p[1],p[2]}
end
-- Custom first applies; only an already-selected Custom opens the editor.
function R.tap(selected, choice) return choice=="custom" and selected=="custom" and "edit" or "apply" end
