local uci = require('uci')
local root = '/data/zte-vpn'
local c = uci.cursor('/etc/config', root .. '/uci')
local fields = {'ssid','key','encryption','network','bridge','disabled','isolate','wps_state','ieee80211w','sae'}
local function set(pkg, section, key, value)
    assert(c:set(pkg,section,key,value), 'UCI set failed')
end
local function section(pkg, kind, name, values)
    assert(c:set(pkg,name,kind), 'UCI section creation failed')
    for key,value in pairs(values) do set(pkg,name,key,value) end
end
local mode = arg[1]
if mode == 'status' then
    local out={enabled=c:get('wireless','guest_2g','disabled')=='0' and c:get('wireless','guest_5g','disabled')=='0',
      ssid=c:get('wireless','guest_5g','ssid') or '',
      network_ok=c:get('wireless','guest_2g','network')=='vpn' and c:get('wireless','guest_5g','network')=='vpn' and c:get('wireless','guest_2g','bridge')=='br-vpn' and c:get('wireless','guest_5g','bridge')=='br-vpn',
      mesh=c:get('wireless','zte_mbb','mesh_onoff')~='0'}
    print(require('luci.jsonc').stringify(out)); return
elseif mode == 'apply' then
    assert(not c:get('network','vpn') and not c:get('network','br_vpn'), 'VPN network already exists')
    assert(not c:get('firewall','zte_vpn_zone') and not c:get('firewall','zte_vpn_rules'), 'VPN firewall already exists')
    local key = c:get('wireless','main_5g','key')
    assert(key and ((#key >= 8 and #key <= 63) or (#key == 64 and key:match('^[a-fA-F0-9]+$'))), 'Main Wi-Fi password unsupported')
    local encryption = c:get('wireless','main_5g','encryption')
    assert(encryption == 'sae-mixed' or encryption == 'sae' or encryption == 'psk2' or encryption == 'psk2+ccmp' or encryption == 'psk2+aes', 'Main Wi-Fi security unsupported')
    section('network','device','br_vpn',{name='br-vpn',type='bridge',ports={'wlan1','wlan3'},bridge_empty='1',ipv6='0'})
    section('network','interface','vpn',{device='br-vpn',type='bridge',ifname='wlan1 wlan3',bridge_empty='1',force_link='1',proto='static',ipaddr='192.168.50.1',netmask='255.255.255.0',delegate='0'})
    section('firewall','zone','zte_vpn_zone',{name='vpn',network={'vpn'},input='REJECT',output='ACCEPT',forward='REJECT'})
    section('firewall','include','zte_vpn_rules',{type='script',path=root..'/firewall.sh',reload='1',enabled='1'})
    for _,section in ipairs({'guest_2g','guest_5g'}) do
        assert(c:get('wireless',section) == 'wifi-iface', 'Guest section missing')
        set('wireless',section,'network','vpn'); set('wireless',section,'bridge','br-vpn')
        set('wireless',section,'ssid','ZTE-VPN'); set('wireless',section,'key',key)
        set('wireless',section,'encryption',encryption); set('wireless',section,'isolate','1')
        set('wireless',section,'ieee80211w',c:get('wireless','main_5g','ieee80211w') or '0')
        set('wireless',section,'sae',c:get('wireless','main_5g','sae') or '0')
        set('wireless',section,'wps_state','0'); set('wireless',section,'disabled','1')
    end
elseif mode == 'enable' or mode == 'disable' then
    for _,section in ipairs({'guest_2g','guest_5g'}) do
        set('wireless',section,'disabled',mode=='enable' and '0' or '1')
    end
elseif mode == 'restore' then
    local b = uci.cursor(root..'/backup',root..'/backup-deltas')
    for _,section in ipairs({'guest_2g','guest_5g'}) do
        for _,field in ipairs(fields) do
            local value = b:get('wireless',section,field)
            if value == nil then c:delete('wireless',section,field)
            else set('wireless',section,field,value) end
        end
    end
    c:delete('network','vpn'); c:delete('network','br_vpn')
    c:delete('firewall','zte_vpn_zone'); c:delete('firewall','zte_vpn_rules')
else error('Unknown mode') end
for _,pkg in ipairs({'network','firewall','wireless'}) do assert(c:save(pkg)); assert(c:commit(pkg)) end
print('UCI_'..mode..'=OK')
