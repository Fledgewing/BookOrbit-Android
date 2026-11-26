-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,here,M)
    local R=M.ReadingStyle
    test("Custom styles: defaults, ranges, quantization and invalid values",function()
        local d=R.record(); eq(d.fontIndex,1); eq(d.weight,1); eq(d.margins,46); eq(d.spacing,1.42); eq(d.contrast,.2)
        for key,l in pairs(R.limits) do
            eq(R.clamp(key,-1e6),l[1]); eq(R.clamp(key,1e6),l[2])
            eq(R.clamp(key,0/0),l[1]); eq(R.clamp(key,math.huge),l[1])
            local field=key=="font" and "weight" or key
            local s=R.record(); s[field]=l[1]
            local stepped=R.step(s,key,1)
            ok(math.abs(stepped[field]-(l[1]+l[3]))<.00001)
            for _=1,100 do stepped=R.step(stepped,key,1) end
            eq(stepped[field],l[2]); eq(s[field],l[1],"input is immutable")
        end
        eq(R.clamp("margins",47),48); eq(R.clamp("spacing",1.431),1.44)
        eq(R.record({fontIndex=-5}).fontIndex,1); eq(R.record({fontIndex=90}).fontIndex,4)
        eq(R.record({face=string.rep("x",161)}).face,nil)
    end)
    test("Custom styles: human labels and apply before edit",function()
        local s=R.record()
        eq(R.label(s,"font"),"Baskerville · weight +1"); eq(R.label(s,"margins"),"46 px"); eq(R.label(s,"spacing"),"1.42")
        eq(R.label(s,"contrast"),"Darker 0.2"); s.contrast=-.5; eq(R.label(s,"contrast"),"Lighter 0.5")
        s.contrast=0; eq(R.label(s,"contrast"),"Normal"); s.weight=0; eq(R.label(s,"font"),"Baskerville")
        eq(R.tap(1,"custom"),"apply"); eq(R.tap("custom","custom"),"edit"); eq(R.tap("custom",1),"apply")
    end)
    test("Custom styles: copy is independent and Undo restores all previous values",function()
        local s=R.record({fontIndex=4,face="Fixture Face",weight=-1,margins=78,spacing=1.98,contrast=-.4})
        local current={fontIndex=2,weight=0,margins=40,spacing=1.3,contrast=.1}
        local copied,undo=R.copy(s,current)
        for k,v in pairs(current) do eq(copied[k],v) end
        for k,v in pairs(s) do eq(undo[k],v) end
        current.margins=80; eq(copied.margins,40); copied.weight=2; eq(undo.weight,-1)
        for _,key in ipairs(R.keys) do local p=R.pair(key,{[key]={999,1}}); eq(p[1],R.defaultPairs[key][1]) end
    end)
end
