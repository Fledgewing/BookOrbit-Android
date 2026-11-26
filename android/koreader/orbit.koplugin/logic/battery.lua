-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Presentation selection only; all values and evidence labels are companion-owned.
BatteryPlan = {tabs={"Overview","Rates","Daily","Charges"}}
function BatteryPlan.display(data)
    return data and data.display or {level="—",estimate="Learning · needs measured use",
        narrow_estimate="Learning · usual use",page_estimate="Learning · estimate available after measured use",
        reading="— Needs measured reading",standby="— Needs measured standby"}
end
function BatteryPlan.widget(data,w,h)
    local d=BatteryPlan.display(data)
    local lines={w == 1 and d.narrow_estimate or d.estimate,d.reading,d.standby}
    if w>1 and h>1 then
        lines[#lines+1]=d.reading_rate or "— Needs measured reading"
        lines[#lines+1]=d.standby_rate or "— Needs measured standby"
        lines[#lines+1]=d.used_week or "— Needs measured daily use"
        if h>=3 or w>=4 then
            lines[#lines+1]="Per 100 pages · — Needs tracked page measurements"
            lines[#lines+1]=d.charging_rate or "— Needs measured charging"
        end
        lines[#lines+1]=d.last_charge or "— No charges recorded"
    end
    return {level=d.level or "—",lines=lines,level_fraction=data and data.level and data.level/100 or 0}
end
function BatteryPlan.page(data,tab,page)
    local d=BatteryPlan.display(data)
    local key=({"overview","rates","daily","charges"})[tab] or "overview"
    local count=math.min(d[key.."_count"] or 0,key == "daily" and 14 or key == "charges" and 5 or 9)
    local rows={}
    local first=key == "daily" and page == 2 and 8 or 1
    local last=key == "daily" and math.min(count,first+6) or count
    for i=first,last do rows[#rows+1]=d[key][i] end
    if #rows==0 then rows[1]=key == "charges" and "— No charges recorded" or "— Needs measured use" end
    return {level=d.level or "—",estimate=d.page_estimate,rows=rows,daily=key == "daily",pages=key == "daily" and 2 or 1}
end
