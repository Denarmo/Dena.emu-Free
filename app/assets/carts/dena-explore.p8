pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- dena explore: dena.emu's own cart launcher.
-- gpl-3.0-or-later. written clean-room for dena.emu; talks to
-- the app through the gpio mailbox at 0x5f80.
-- spec: docs/specs/pico8-launcher-cart.md

g=0x5f80
seq=0
queue={}
cur=nil
status=""
online=false
nohost=false
helloed=false
frames=0

-- mailbox --------------------------------------------------

function req(cmd,arg,cb)
 add(queue,{cmd=cmd,arg=arg or "",cb=cb})
end

function send(cmd,arg,chunk)
 local n=min(#arg,120)
 for i=1,n do poke(g+7+i,ord(arg,i)) end
 poke(g+1,cmd)
 poke(g+2,chunk)
 poke(g+3,n)
 poke(g+4,0)
 seq=seq%255+1
 poke(g+5,seq)
 poke(g,1)
end

function pump()
 if cur==nil then
  if #queue==0 then return end
  cur=deli(queue,1)
  cur.buf=""
  cur.chunk=0
  send(cur.cmd,cur.arg,0)
  return
 end
 if peek(g)~=3 or peek(g+5)~=seq then return end
 local s=""
 for i=1,peek(g+3) do s..=chr(peek(g+7+i)) end
 cur.buf..=s
 local flags=peek(g+4)
 if band(flags,1)~=0 then
  cur.chunk+=1
  send(7,"",cur.chunk)
 else
  poke(g,0)
  local c=cur
  cur=nil
  if c.cb then c.cb(c.buf,band(flags,2)~=0) end
 end
end

-- records: lines of tab-separated fields
function records(text)
 local out={}
 for line in all(split(text,"\n",false)) do
  if #line>0 then add(out,split(line,"\t",false)) end
 end
 return out
end

-- tabs -----------------------------------------------------

tabs={}
tab=1

function newtab(name,kind,arg)
 return {name=name,kind=kind,arg=arg,items={},sel=1,top=1,
  page=1,more=false,loaded=false}
end

function maketabs()
 tabs={newtab("library","local","all"),
  newtab("favourites","local","fav")}
 if online then
  add(tabs,newtab("featured","bbs","f"))
  add(tabs,newtab("new","bbs","n"))
  add(tabs,newtab("search","bbs","s"))
 end
end

function loadtab(t)
 if t.kind=="local" then
  status="loading..."
  req(2,t.arg,function(text,err)
   status=err and text or ""
   if err then return end
   t.items={}
   for r in all(records(text)) do
    add(t.items,{id=r[1],title=r[2],author=r[3] or "",
     fav=r[4]=="1",local_=true})
   end
   t.loaded=true
   clampsel(t)
  end)
 elseif t.arg~="s" or t.query then
  loadpage(t,1)
 end
end

function loadpage(t,page)
 local arg=t.arg.." "..page
 if t.query then arg=arg.." "..t.query end
 status="loading..."
 req(3,arg,function(text,err)
  status=err and text or ""
  if err then return end
  local rs=records(text)
  if page==1 then t.items={} end
  t.more=#rs>0 and rs[1][1]=="more" and rs[1][2]=="1"
  for i=2,#rs do
   local r=rs[i]
   local id=r[4]~="-" and r[4] or nil
   add(t.items,{idx=r[1],title=r[2],author=r[3] or "",
    inlib=id~=nil,id=id})
  end
  t.page=page
  t.loaded=true
  clampsel(t)
 end)
end

function rows(t)
 return #t.items+(t.more and 1 or 0)
end

function clampsel(t)
 t.sel=mid(1,t.sel,max(1,rows(t)))
 if t.sel<t.top then t.top=t.sel end
 if t.sel>t.top+9 then t.top=t.sel-9 end
end

function switchtab(d)
 tab=(tab-1+d)%#tabs+1
 local t=tabs[tab]
 if t.kind=="local" or not t.loaded then loadtab(t) end
end

-- actions --------------------------------------------------

function run(item)
 status="starting..."
 req(5,item.id,function(text,err)
  status=err and text or ""
 end)
end

function activate(t)
 if t.more and t.sel==#t.items+1 then
  loadpage(t,t.page+1)
  return
 end
 local item=t.items[t.sel]
 if item==nil then return end
 if item.local_ or item.inlib and item.id then
  run(item)
 else
  status="downloading..."
  req(4,item.idx,function(text,err)
   if err then status=text return end
   local r=split(text," ",false)
   item.inlib=true
   item.id=r[2]
   status=r[1]=="dup" and "already in library" or "added to library"
  end)
 end
end

function togglefav(item)
 if item==nil or not item.local_ then return end
 req(6,item.id,function(text,err)
  if err then status=text return end
  item.fav=text=="1"
 end)
end

-- search keyboard ------------------------------------------

keys="abcdefghijklmnopqrstuvwxyz0123456789 <>"
kb={on=false,x=1,y=1,text=""}

function kbkey()
 local i=(kb.y-1)*10+kb.x
 return sub(keys,i,i)
end

function updatekb(t)
 if btnp(0) then kb.x=(kb.x-2)%10+1 end
 if btnp(1) then kb.x=kb.x%10+1 end
 if btnp(2) then kb.y=(kb.y-2)%4+1 end
 if btnp(3) then kb.y=kb.y%4+1 end
 if kb.y==4 and kb.x>9 then kb.x=9 end
 if btnp(5) then kb.on=false end
 if btnp(4) then
  local k=kbkey()
  if k=="<" then
   kb.text=sub(kb.text,1,#kb.text-1)
  elseif k==">" then
   kb.on=false
   if #kb.text>0 then
    t.query=kb.text
    t.sel=1 t.top=1
    loadpage(t,1)
   end
  elseif #kb.text<24 then
   kb.text..=k
  end
 end
end

-- main -----------------------------------------------------

function _init()
 for i=0,127 do poke(g+i,0) end
 req(1,"",function(text,err)
  helloed=true
  online=not err and text=="1"
  maketabs()
  loadtab(tabs[1])
 end)
end

function _update60()
 frames+=1
 pump()
 if not helloed then
  if frames>120 then nohost=true end
  return
 end
 local t=tabs[tab]
 if kb.on then updatekb(t) return end
 if btnp(0) then switchtab(-1) end
 if btnp(1) then switchtab(1) end
 if btnp(2) then t.sel-=1 end
 if btnp(3) then t.sel+=1 end
 clampsel(t)
 if btnp(4) then
  if t.arg=="s" and (t.sel==1 and #t.items==0 or t.query==nil) then
   kb.on=true
  else
   activate(t)
  end
 end
 if btnp(5) then
  if t.arg=="s" then kb.on=true else togglefav(t.items[t.sel]) end
 end
end

function cut(s,n)
 if #s>n then return sub(s,1,n-1).."." end
 return s
end

function drawtop(t)
 rectfill(0,0,127,8,1)
 print("<",2,2,13)
 print(">",122,2,13)
 local w=#t.name*4
 print(t.name,64-w/2,2,10)
 -- one dot per tab
 for i=1,#tabs do
  pset(64-#tabs*2+i*4-2,10,i==tab and 10 or 5)
 end
end

function drawlist(t)
 if #t.items==0 and not t.more then
  local msg=t.loaded and "no carts here" or ""
  if t.arg=="s" and t.query==nil then msg="press o to search" end
  if t.kind=="local" and t.loaded and t.arg=="all" then
   msg="no carts yet"
  end
  print(msg,64-#msg*2,50,6)
  return
 end
 for i=0,9 do
  local n=t.top+i
  local y=14+i*8
  if n<=rows(t) then
   local sel=n==t.sel
   if sel then rectfill(0,y-1,127,y+5,2) end
   if n>#t.items then
    print("load more",4,y,sel and 10 or 12)
   else
    local item=t.items[n]
    local c=sel and 10 or 7
    if item.fav then print("*",2,y,8) end
    if item.inlib and not item.local_ then print("+",2,y,11) end
    print(cut(item.title,29),8,y,c)
   end
  end
 end
end

function drawfoot(t)
 rectfill(0,96,127,127,0)
 line(0,96,127,96,5)
 local item=t.items[t.sel]
 if item then
  print(cut(item.title,31),2,99,7)
  if #item.author>0 then print(cut("by "..item.author,31),2,106,6) end
 end
 local hint
 if t.arg=="s" then hint="o select  x keyboard"
 elseif t.kind=="local" then hint="o run  x favourite"
 elseif item and item.inlib then hint="o run"
 else hint="o download" end
 if #status>0 then print(cut(status,31),2,114,9) end
 print(hint,2,121,13)
end

function drawkb()
 rectfill(4,40,123,94,1)
 rect(4,40,123,94,10)
 print("search: "..kb.text.."_",8,43,7)
 for y=1,4 do
  for x=1,10 do
   local i=(y-1)*10+x
   if i<=#keys then
    local k=sub(keys,i,i)
    if k==" " then k="_" end
    if k=="<" then k="del" end
    if k==">" then k="go" end
    local px,py=8+(x-1)*11,52+(y-1)*10
    local sel=kb.x==x and kb.y==y
    if sel then rectfill(px-1,py-1,px+(#k*4),py+5,10) end
    print(k,px,py,sel and 0 or 7)
   end
  end
 end
end

function _draw()
 cls(0)
 if nohost then
  print("dena explore",40,50,10)
  print("open it from the dena.emu",14,62,6)
  print("app to browse your carts",16,70,6)
  return
 end
 if not helloed then
  print("dena explore",40,60,10)
  return
 end
 local t=tabs[tab]
 drawtop(t)
 drawlist(t)
 drawfoot(t)
 if kb.on then drawkb() end
end
