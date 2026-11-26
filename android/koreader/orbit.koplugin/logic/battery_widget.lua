-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Display measured scalars only; no history scans, model fitting or estimates here.
BatteryWidgetPlan = {}
function BatteryWidgetPlan.model(data)
    data=data or {}
    local function finite(value)
        return type(value)=="number" and value==value and value>=0 and value<math.huge and value or nil
    end
    local level=finite(data.level)
    if level and level>100 then level=nil end
    local function duration(value) return ReaderPanelPlan.duration(value,true) or "—" end
    local usual=ReaderPanelPlan.duration(data.hours_usual_use,true)
    local function rate(value)
        local n=value and finite(value.pct_per_hour)
        return n and string.format("%.1f %%/h",n) or "—"
    end
    local charge=data.recent_charges and data.recent_charges[1]
    local last="Charge history not recorded"
    if charge and finite(charge.from_pct) and finite(charge.to_pct) then
        last=string.format("Last charge %d%% → %d%%",charge.from_pct,charge.to_pct)
    end
    return {level=level,level_text=level and string.format("%d%%",level) or "—",
        fraction=level and level/100,charging=data.charging==true,
        usual=usual and ("≈ "..usual.." at your usual use") or ((data.usual_use or {}).missing or "More measured use needed"),
        narrow_usual=usual and ("≈ "..usual.." · usual use") or "More measured use needed",
        screen_on="Screen on "..rate(data.screen_on),standby="Standby "..rate(data.standby),
        reading="Reading non-stop "..duration(data.hours_reading_nonstop),
        asleep="Standby only "..duration(data.hours_standby_only),charge=last}
end
