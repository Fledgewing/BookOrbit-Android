-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Neutral display/focus policy; never accepts a secret.
AccountPlan = {names={sync="Sync login",opds="OPDS login"}}
function AccountPlan.login(a,k) return type(a[k])=="table" and a[k] or {} end
function AccountPlan.status(l)
    return not l.set and "Not set" or l.origin=="account" and "Set up by your account" or "Set by you"
end
function AccountPlan.summary(a)
    if a.signedIn then return "Signed in as " .. (a.username or "your account") end
    return AccountPlan.login(a,"sync").available and "Not signed in · Position sync uses your sync login · Stats from this reader only"
        or "Not signed in · nothing syncs yet · Stats from this reader only"
end
function AccountPlan.sync(a,home)
    if AccountPlan.login(a,"sync").available then return nil end
    if a.signedIn then return home and "No sync login · Set up" or "Set up sync", "sync",
        "No sync login, so your place and highlights don't sync." end
    return home and "Not signed in · Sign in" or "Sign in to sync", "account",
        "Not signed in, so nothing syncs: not your place, highlights or new books."
end
function AccountPlan.signout(a)
    local set,own={},{}
    for _,k in ipairs({"sync","opds"}) do
        local l=AccountPlan.login(a,k)
        if l.set then (l.origin=="account" and set or own)[#(l.origin=="account" and set or own)+1]=k end
    end
    local names={sync="the sync login",opds="the OPDS login"}
    local t="Signs out of your account"
    if #set>0 then
        t=t .. ", and removes " .. names[set[1]] .. (#set==2 and " and " .. names[set[2]] or "") .. " it set up."
    else t=t .. "." end
    for _,k in ipairs(set) do t=t .. (k=="sync" and " Sync stops on this reader." or " Browsing and downloading from your server stop.") end
    for _,k in ipairs(own) do t=t .. (k=="sync" and " Your own sync login stays, so sync keeps working." or " Your own OPDS login stays, so you can still download.") end
    return t .. " Your downloaded books and your place in them stay on this reader. Stats from your other devices stop."
end
AccountPlan.errors={
    unauthorized={"That user name and password didn't work","Check both and try again. Passwords are case-sensitive.","password"},
    unavailable={"Can't reach your server","Check the address, Wi-Fi and your VPN if your server needs it.","server"},
    ["too-old"]={"Your server is too old for this","Update your server and try again. Until then, stats come from this reader only.","cancel"},
    ["two-step"]={"This account uses two-step sign-in","Sign in from your phone instead. Phone setup is on the X4 build.","phone"},
}
function AccountPlan.error(code) return AccountPlan.errors[code] or AccountPlan.errors.unavailable end
function AccountPlan.result(before,after)
    local rows,focus={},"account"
    for _,k in ipairs({"sync","opds"}) do
        local old,l=AccountPlan.login(before,k),AccountPlan.login(after,k)
        local text
        if old.set and old.origin=="user" then text="Kept: the one you set · Replace with the account's in " .. AccountPlan.names[k]
        elseif l.set then
            text=not old.set and l.outcome=="created" and "Created" or "Found"
            if not old.set and focus=="account" then focus=k end
        else text="Not set · Set up in " .. AccountPlan.names[k] end
        rows[#rows+1]=AccountPlan.names[k] .. ": " .. text
    end
    return rows,focus
end
