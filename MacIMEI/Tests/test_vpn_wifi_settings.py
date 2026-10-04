#!/usr/bin/env python3
"""Run production Lua against an isolated in-memory UCI fixture; no modem access."""
from pathlib import Path
import shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
LUA=shutil.which('lua')
HARNESS=r'''
local source=arg[1]
local function copy(value) if type(value)~='table' then return value end local out={} for k,v in pairs(value) do out[k]=copy(v) end return out end
local function equal(a,b) if type(a)~=type(b) then return false end if type(a)~='table' then return a==b end for k,v in pairs(a) do if not equal(v,b[k]) then return false end end for k in pairs(b) do if a[k]==nil then return false end end return true end
local db,backup,prefs,bytes,status,commits,errors,writes,pending
local function fresh(configured)
 db={wireless={main_5g={kind='wifi-iface',ssid='Primary Five',key='main-five-secret',encryption='sae-mixed',ieee80211w='1',sae='1'},main_2g={kind='wifi-iface',ssid='Primary Two',key='main-two-secret',encryption='psk2'},guest_2g={kind='wifi-iface',ssid='Existing24',key='old-two-password',encryption='psk2',disabled='1',network=configured and 'vpn' or 'guest',bridge=configured and 'br-vpn' or 'br-guest'},guest_5g={kind='wifi-iface',ssid='Existing5',key='old-five-password',encryption='sae-mixed',disabled='1',network=configured and 'vpn' or 'guest',bridge=configured and 'br-vpn' or 'br-guest'},zte_mbb={mesh_onoff='0'}},network={},firewall={}}
 backup=copy(db);prefs=nil;bytes=nil;status=nil;commits={};errors='';writes=0;pending=false
end
package.preload['uci']=function() return {cursor=function(path)
 local data=path=='/data/zte-vpn/backup' and backup or db
 return {get=function(_,p,s,k) local item=data[p] and data[p][s];if not item then return nil end if k then return item[k] else return item.kind end end,
 set=function(_,p,s,k,v) writes=writes+1;db[p]=db[p] or {};db[p][s]=db[p][s] or {};if v==nil then db[p][s].kind=k else db[p][s][k]=copy(v) end return true end,
 delete=function(_,p,s,k) if k then db[p][s][k]=nil else db[p][s]=nil end return true end,
 save=function()return true end,commit=function(_,p)table.insert(commits,p);return true end}
 end}end
package.preload['luci.jsonc']=function()return{parse=function()return copy(prefs)end,stringify=function(v)status=copy(v);return 'STATUS_ONLY'end}end
local open=io.open
io.open=function(path,mode)
 if path=='/data/zte-vpn/wifi-settings.pending' then if pending then return {close=function()end} else return nil end end
 if path=='/data/zte-vpn/wifi-settings.json' then if not prefs and not bytes then return nil end return {read=function(_,limit)return (bytes or '{}'):sub(1,limit)end,close=function()end} end
 error('Unexpected filesystem path '..path)
end
io.stderr={write=function(_,s)errors=errors..s end}
os.exit=function(code)error('EXIT:'..code,0)end
os.execute=function()error('Shell execution is forbidden in fixture')end
local function run(mode) arg={mode};return pcall(dofile,source)end
local count=0
local function check(name,fn)fresh(true);fn();count=count+1;print('PASS '..name)end
check('status reports both actual guest SSIDs without mutation or secrets',function()
 local before=copy(db);prefs={ssid='Pending Name',password_mode='custom',password='never-in-status'}
 assert(run('status'));assert(status.ssid=='Existing5' and status.ssid_2g=='Existing24' and status.ssid_5g=='Existing5');assert(status.main_ssid=='Primary Five');assert(not status.key and not status.password);assert(equal(db,before) and writes==0 and #commits==0)
end)
check('new network defaults to ZTE-VPN and current main Wi-Fi credentials',function()
 fresh(false);local main=copy(db.wireless.main_5g);assert(run('apply'));for _,name in ipairs({'guest_2g','guest_5g'})do local g=db.wireless[name];assert(g.ssid=='ZTE-VPN' and g.key==main.key and g.encryption==main.encryption and g.disabled=='1' and g.network=='vpn' and g.bridge=='br-vpn')end;assert(equal(db.wireless.main_5g,main))
end)
check('explicit preserve renames both guests without changing either password',function()
 local two=copy(db.wireless.guest_2g);local five=copy(db.wireless.guest_5g);local main=copy(db.wireless.main_5g)
 prefs={ssid="My VPN 'name'",password_mode='preserve'};assert(run('wifi-settings'))
 for _,name in ipairs({'guest_2g','guest_5g'})do assert(db.wireless[name].ssid==prefs.ssid and db.wireless[name].disabled=='1')end
 assert(db.wireless.guest_2g.key==two.key and db.wireless.guest_5g.key==five.key and db.wireless.guest_5g.encryption==five.encryption);assert(equal(main,db.wireless.main_5g));assert(#commits==1 and commits[1]=='wireless')
end)
check('custom credentials pass through literal UCI values and use WPA2 CCMP',function()
 prefs={ssid='$(literal); VPN',password_mode='custom',password="$(not executed); 'secret'"};assert(run('wifi-settings'));for _,name in ipairs({'guest_2g','guest_5g'})do local g=db.wireless[name];assert(g.ssid==prefs.ssid and g.key==prefs.password and g.encryption=='psk2+ccmp' and g.sae=='0')end;assert(not errors:find('secret',1,true))
end)
check('explicit main mode copies credentials once and does not touch main AP',function()
 local main=copy(db.wireless.main_5g);prefs={ssid='VPN Copy',password_mode='main'};assert(run('wifi-settings'));assert(db.wireless.guest_5g.key==main.key and equal(db.wireless.main_5g,main));db.wireless.main_5g.key='changed-main-password';assert(run('enable'));assert(db.wireless.guest_5g.key==main.key)
end)
check('missing or invalid 5GHz credentials fall back to valid main2GHz',function()
 for _,broken in ipairs({'missing','security'})do fresh(true);if broken=='missing'then db.wireless.main_5g.key=nil else db.wireless.main_5g.encryption='none'end;prefs={ssid='Fallback VPN',password_mode='main'};assert(run('status'));assert(status.main_ssid=='Primary Two');assert(run('wifi-settings'));assert(db.wireless.guest_5g.key=='main-two-secret')end
end)
check('main mode retains a supported existing UTF8 password',function()
 db.wireless.main_5g.key='секрет123';prefs={ssid='VPN UTF8',password_mode='main'};assert(run('wifi-settings'));assert(db.wireless.guest_5g.key=='секрет123')
end)
check('one or both enabled guest APs prevent settings writes',function()
 for _,name in ipairs({'guest_2g','guest_5g'})do fresh(true);db.wireless[name].disabled='0';local before=copy(db);prefs={ssid='No change',password_mode='preserve'};assert(not run('wifi-settings'));assert(errors:find('VPN_WIFI_SETTINGS_ENABLED',1,true));assert(equal(db,before) and writes==0 and #commits==0)end
end)
check('changed guest network binding prevents settings writes',function()
 db.wireless.guest_2g.network='guest';local before=copy(db);prefs={ssid='No change',password_mode='preserve'};assert(not run('wifi-settings'));assert(errors:find('VPN_WIFI_CONFIGURATION_CHANGED',1,true));assert(equal(db,before) and writes==0)
end)
check('bad SSIDs and custom passwords are rejected before UCI mutations',function()
 for _,ssid in ipairs({'','   ','line\nbreak',string.rep('a',33)})do fresh(true);prefs={ssid=ssid,password_mode='main'};assert(not run('wifi-settings'));assert(writes==0 and errors:find('VPN_INVALID_WIFI_SSID',1,true))end
 for _,password in ipairs({'short','line\nbreak',string.rep('x',64),string.rep('a',65)})do fresh(true);prefs={ssid='Valid SSID',password_mode='custom',password=password};assert(not run('wifi-settings'));assert(writes==0 and errors:find('VPN_INVALID_WIFI_PASSWORD',1,true))end
end)
check('oversized private settings are rejected without mutation',function()
 bytes=string.rep('x',4097);assert(not run('wifi-settings'));assert(writes==0 and errors:find('VPN_INVALID_WIFI_SETTINGS',1,true))
end)
check('new network cannot preserve an unspecified previous VPN password',function()
 fresh(false);prefs={ssid='New VPN',password_mode='preserve'};assert(not run('apply'));assert(writes==0 and errors:find('VPN_WIFI_NOT_CONFIGURED',1,true))
end)
check('pending settings prevent direct enable but allow explicit disable',function()
 pending=true;local before=copy(db);assert(not run('enable'));assert(errors:find('VPN_WIFI_SETTINGS_PENDING',1,true));assert(equal(db,before) and writes==0 and #commits==0);assert(run('disable'))
end)

check('apply removes the stock timer only on both VPN guest APs',function()
 fresh(false)
 db.wireless.guest_2g.guest_active_time='120';db.wireless.guest_5g.guest_active_time='240'
 db.wireless.guest_2g.guest_remaining='99';db.wireless.guest_5g.guest_remaining='14316'
 db.wireless.main_2g.guest_active_time='9';db.wireless.zte_mbb.wifi_sleep_time='10'
 local main=copy(db.wireless.main_2g);local global=copy(db.wireless.zte_mbb)
 assert(run('apply'))
 assert(db.wireless.guest_2g.guest_active_time=='0' and db.wireless.guest_5g.guest_active_time=='0')
 assert(db.wireless.guest_2g.guest_remaining=='99' and db.wireless.guest_5g.guest_remaining=='14316')
 assert(equal(main,db.wireless.main_2g) and equal(global,db.wireless.zte_mbb))
end)
check('enable upgrades existing guests without rewriting remaining time',function()
 db.wireless.guest_2g.guest_active_time='240';db.wireless.guest_5g.guest_active_time=nil
 db.wireless.guest_2g.guest_remaining='14316'
 assert(run('enable'))
 for _,name in ipairs({'guest_2g','guest_5g'})do assert(db.wireless[name].disabled=='0' and db.wireless[name].guest_active_time=='0')end
 assert(db.wireless.guest_2g.guest_remaining=='14316' and db.wireless.guest_5g.guest_remaining==nil)
 local once=copy(db);assert(run('enable'));assert(equal(once,db))
end)
check('enable validates both owned sections before any UCI change',function()
 for _,name in ipairs({'guest_2g','guest_5g'})do
  for _,bad in ipairs({'missing','kind','network','bridge'})do
   fresh(true)
   if bad=='missing' then db.wireless[name]=nil elseif bad=='kind' then db.wireless[name].kind='other' else db.wireless[name][bad]='foreign' end
   local before=copy(db);assert(not run('enable'));assert(equal(before,db) and writes==0 and #commits==0)
  end
 end
end)
check('apply missing guest refuses before creating network or changing its peer',function()
 for _,name in ipairs({'guest_2g','guest_5g'})do
  fresh(false);db.wireless[name]=nil;local before=copy(db)
  assert(not run('apply'));assert(equal(before,db) and writes==0 and #commits==0)
 end
end)
check('restore returns original timer values and original absence after runtime changes',function()
 for _,pattern in ipairs({'both','mixed','absent'})do
  fresh(false)
  if pattern~='absent' then db.wireless.guest_2g.guest_active_time='240';db.wireless.guest_2g.guest_remaining='14316' end
  if pattern=='both' then db.wireless.guest_5g.guest_active_time='120';db.wireless.guest_5g.guest_remaining='99' end
  backup=copy(db);local original=copy(db.wireless)
  assert(run('apply'));assert(run('enable'))
  db.wireless.guest_2g.guest_remaining='0';db.wireless.guest_5g.guest_remaining='0'
  assert(run('restore'))
  for _,name in ipairs({'guest_2g','guest_5g'})do
   for _,key in ipairs({'guest_active_time','guest_remaining','disabled','network','bridge'})do assert(db.wireless[name][key]==original[name][key])end
  end
  assert(not db.network.vpn and not db.network.br_vpn and not db.firewall.zte_vpn_zone and not db.firewall.zte_vpn_rules)
 end
end)
check('disable does not alter guest timers or global sleep',function()
 db.wireless.guest_2g.guest_active_time='120';db.wireless.guest_5g.guest_active_time='240';db.wireless.guest_2g.guest_remaining='99'
 db.wireless.zte_mbb.wifi_sleep_time='10';local before=copy(db)
 assert(run('disable'));assert(equal(before,db))
end)
check('pending settings refuse enable without timer changes',function()
 pending=true;db.wireless.guest_2g.guest_active_time='240';local before=copy(db)
 assert(not run('enable'));assert(equal(before,db) and writes==0 and #commits==0)
end)
check('Wi-Fi credential edits do not alter either timer',function()
 db.wireless.guest_2g.guest_active_time='120';db.wireless.guest_5g.guest_remaining='14316'
 prefs={ssid='New name',password_mode='preserve'};assert(run('wifi-settings'))
 assert(db.wireless.guest_2g.guest_active_time=='120' and db.wireless.guest_2g.guest_remaining==nil)
 assert(db.wireless.guest_5g.guest_active_time==nil and db.wireless.guest_5g.guest_remaining=='14316')
end)

print('VPN_WIFI_LUA_RESULT checks='..count..' failures=0')
'''
class WifiLuaTests(unittest.TestCase):
 def test_production_configure_lua(self):
  self.assertIsNotNone(LUA,'A local Lua interpreter is required for this isolated fixture')
  with tempfile.TemporaryDirectory(prefix='vpn-wifi-lua-') as temporary:
   script=Path(temporary)/'test.lua';script.write_text(HARNESS)
   result=subprocess.run([LUA,str(script),str(ROOT/'Resources/VPN/configure.lua')],capture_output=True,text=True,timeout=20)
   print(result.stdout,end='');self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   self.assertIn('VPN_WIFI_LUA_RESULT checks=21 failures=0',result.stdout)
if __name__=='__main__':unittest.main()
