-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Presentation only: owned settings rows, header and modal surface over the shared kit.
SettingsPage={}
function SettingsPage.new(o)
    local K=BookSyncUI.new(); local p=K.px
    local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
    local w=o.w or (o.modal and math.min(sw-p(104),p(598)) or sw)
    local h=o.h or sh
    local c=K.canvas(w,h)
    local edge=o.modal and p(24) or p(25)
    local widgets={}
    local function put(widget,x,y,id)
        K.put(c,widget,x,y)
        if id then widgets[id]=widget end
        return widget
    end
    local function icon(name,size)
        if name:match("^settings%-") then return require("ui/widget/imagewidget"):new{file=SOURCE_DIR.."/ko/ui/icons/"..name..".svg",width=size,height=size,is_icon=true} end
        return K.icon{name=name,w=size}
    end
    local function rule(y)
        local line=K.frame(K.canvas(w-2*edge,p(1)),{w=w-2*edge,h=p(1)})
        line.background=K.light;put(line,edge,y)
    end
    if o.modal then
        K.label(c,o.title,edge,p(24),w-2*edge,20,{serif=true,bold=true})
        if o.subtitle then K.label(c,o.subtitle,edge,p(58),w-2*edge,"caption") end
    else
        put(K.button{text=o.backText or "Back",icon="arrowL",w=p(88),h=p(58),variant="ghost",callback=o.onBack},p(15),p(3),"back")
        K.label(c,o.title,p(103),p(9),w-p(125),"medium",{bold=true})
        K.label(c,o.subtitle or "BookSync settings",p(103),p(35),w-p(125),"caption",{muted=true})
        put(K.frame(K.canvas(w,p(1)),{w=w,h=p(1),ink=true}),0,p(63))
    end
    local y=o.startY or p(o.modal and 92 or o.root and 63 or 67)
    if o.intro then
        local sample=K.text{text="",w=w-2*edge,size="body"}
        local paragraph=require("ui/widget/textboxwidget"):new{text=o.intro,width=w-2*edge,face=sample.face}
        put(paragraph,edge,y)
        y=y+paragraph:getSize().h+p(24)
        sample:free()
    end
    for i,row in ipairs(o.rows or {}) do
        local rh=row.h or p(o.root and 105 or 73)
        local rc=K.canvas(w-2*edge,rh)
        local rw=w-2*edge
        local x=0
        if row.icon then
            local tile=K.canvas(p(40),p(40))
            K.put(tile,icon(row.icon,p(23)),p(8),p(8))
            local well=K.frame(tile,{w=p(40),h=p(40),radius=p(11)})
            well.background=K.light;K.put(rc,well,0,(rh-p(40))/2)
            x=p(54)
        end
        local detail=row.detail
        local dw=detail and math.min(rw*.48,K.text{text=detail,w=rw*.48,size="small"}:getSize().w+p(8)) or p(25)
        local labelY=row.sub and (rh-p(42))/2 or (rh-p(23))/2
        K.label(rc,row.text,x,labelY,rw-x-dw-p(18),o.root and "body" or "small",{bold=true,serif=row.serif,muted=row.enabled==false})
        if row.sub then K.label(rc,row.sub,x,labelY+p(23),rw-x-p(12),"caption",{muted=not o.root}) end
        if row.toggle~=nil then
            K.put(rc,K.toggle{value=row.toggle,enabled=row.enabled,onChange=function() if row.callback then row.callback() end end},rw-p(56),(rh-p(32))/2)
        elseif detail then K.label(rc,detail,rw-dw,(rh-p(23))/2,dw,"small",{muted=row.enabled==false})
        elseif row.callback then K.put(rc,icon("settings-chevR",p(17)),rw-p(20),(rh-p(17))/2) end
        local hit=K.hit(rc,{w=rw,h=rh,text=row.text,callback=row.callback,enabled=row.enabled})
        hit.callback=row.callback;hit.enabled=row.enabled~=false
        put(hit,edge,y,row.id or tostring(i))
        if row.rule~=false then rule(y+rh) end
        y=y+rh
    end
    if o.content then o.content(K,c,w,y,put) end
    local Input=require("ui/widget/container/inputcontainer"):extend{name="booksync_settings_page",covers_fullscreen=not o.modal,modal=o.modal}
    function Input:onClose() if o.onBack then o.onBack() end;return true end
    function Input:getButtonById(id) return widgets[id] end
    function Input:moveFocusTo(x,y) self.focus={x,y} end
    function Input:closeMenu() if o.onBack then o.onBack() end end
    local frame=K.frame(c,{w=w,h=h,radius=o.modal and p(18) or 0,border=o.modal and p(2) or 0})
    if o.modal then frame=require(o.bottom and "ui/widget/container/bottomcontainer" or "ui/widget/container/centercontainer"):new{dimen=require("ui/geometry"):new{w=sw,h=sh},frame} end
    return Input:new{dimen=require("ui/geometry"):new{w=sw,h=sh},key_events={Close={{"Back"}}},frame}
end
