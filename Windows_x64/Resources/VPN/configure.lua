local uci = require('uci')
local root = '/data/zte-vpn'
local c = uci.cursor('/etc/config', root .. '/uci')
local fields = {'ssid','key','encryption','network','bridge','disabled','isolate','wps_state','ieee80211w','sae','guest_active_time','guest_remaining'}
local function set(pkg, section, key, value)
    assert(c:set(pkg,section,key,value), 'UCI set failed')
end
local function section(pkg, kind, name, values)
    assert(c:set(pkg,name,kind), 'UCI section creation failed')
    for key,value in pairs(values) do set(pkg,name,key,value) end
end
local function fail(code)
    io.stderr:write(code .. '\n'); os.exit(1)
end
local function guest_sections(owned)
    -- Validate both sections before changing either one.
    for _,name in ipairs({'guest_2g','guest_5g'}) do
        if c:get('wireless',name)~='wifi-iface' then fail('VPN_WIFI_CONFIGURATION_CHANGED') end
        if owned and (c:get('wireless',name,'network')~='vpn' or c:get('wireless',name,'bridge')~='br-vpn') then
            fail('VPN_WIFI_CONFIGURATION_CHANGED')
        end
    end
end
local function valid_password(key, ascii_only)
    local forbidden=ascii_only and '[%z\1-\31\127-\255]' or '[%z\1-\31\127]'
    return type(key)=='string' and ((#key >= 8 and #key <= 63 and not key:find(forbidden)) or (#key == 64 and key:match('^[a-fA-F0-9]+$')))
end
local function main_security()
    for _,name in ipairs({'main_5g','main_2g'}) do
        local key,encryption=c:get('wireless',name,'key'),c:get('wireless',name,'encryption')
        if valid_password(key) and (encryption=='sae-mixed' or encryption=='sae' or encryption=='psk2' or encryption=='psk2+ccmp' or encryption=='psk2+aes') then
            return {key=key,encryption=encryption,ieee80211w=c:get('wireless',name,'ieee80211w') or '0',sae=c:get('wireless',name,'sae') or '0',ssid=c:get('wireless',name,'ssid') or ''}
        end
    end
    return nil
end
local function settings()
    local result={ssid='ZTE-VPN',password_mode='main'}
    local file=io.open(root..'/wifi-settings.json','r')
    if file then
        local bytes=file:read(4097);file:close()
        if not bytes or #bytes>4096 then fail('VPN_INVALID_WIFI_SETTINGS') end
        result=require('luci.jsonc').parse(bytes)
    end
    if type(result)~='table' then fail('VPN_INVALID_WIFI_SETTINGS') end
    if type(result.ssid)~='string' or #result.ssid<1 or #result.ssid>32 or result.ssid:find('[%z\1-\31\127]') or not result.ssid:find('%S') then fail('VPN_INVALID_WIFI_SSID') end
    if result.password_mode=='custom' then
        if not valid_password(result.password,true) then fail('VPN_INVALID_WIFI_PASSWORD') end
    elseif result.password_mode~='main' and result.password_mode~='preserve' then fail('VPN_INVALID_WIFI_PASSWORD')
    elseif result.password~=nil then fail('VPN_INVALID_WIFI_PASSWORD') end
    return result
end
local function wifi_values(existing)
    local desired=settings()
    local security
    if desired.password_mode=='main' then
        security=main_security();if not security then fail('VPN_INVALID_WIFI_PASSWORD') end
    elseif desired.password_mode=='custom' then
        security={key=desired.password,encryption='psk2+ccmp',ieee80211w='0',sae='0'}
    elseif not existing then fail('VPN_WIFI_NOT_CONFIGURED') end
    return desired,security
end
local function change_names_and_security(desired,security)
    for _,name in ipairs({'guest_2g','guest_5g'}) do
        assert(c:get('wireless',name)=='wifi-iface','Guest section missing')
        set('wireless',name,'ssid',desired.ssid)
        if security then
            for _,key in ipairs({'key','encryption','ieee80211w','sae'}) do set('wireless',name,key,security[key]) end
        end
    end
end
local mode = arg[1]
if mode == 'status' then
    local ssid2g=c:get('wireless','guest_2g','ssid') or ''
    local ssid5g=c:get('wireless','guest_5g','ssid') or ''
    local main=main_security()
    local out={enabled=c:get('wireless','guest_2g','disabled')=='0' and c:get('wireless','guest_5g','disabled')=='0',
      any_enabled=c:get('wireless','guest_2g','disabled')~='1' or c:get('wireless','guest_5g','disabled')~='1',
      ssid=ssid5g~='' and ssid5g or ssid2g,ssid_2g=ssid2g,ssid_5g=ssid5g,main_ssid=main and main.ssid or '',
      network_ok=c:get('wireless','guest_2g','network')=='vpn' and c:get('wireless','guest_5g','network')=='vpn' and c:get('wireless','guest_2g','bridge')=='br-vpn' and c:get('wireless','guest_5g','bridge')=='br-vpn',
      mesh=c:get('wireless','zte_mbb','mesh_onoff')~='0'}
    print(require('luci.jsonc').stringify(out)); return
elseif mode == 'apply' then
    assert(not c:get('network','vpn') and not c:get('network','br_vpn'), 'VPN network already exists')
    assert(not c:get('firewall','zte_vpn_zone') and not c:get('firewall','zte_vpn_rules'), 'VPN firewall already exists')
    guest_sections(false)
    local desired,security=wifi_values(false)
    section('network','device','br_vpn',{name='br-vpn',type='bridge',ports={'wlan1','wlan3'},bridge_empty='1',ipv6='0'})
    section('network','interface','vpn',{device='br-vpn',type='bridge',ifname='wlan1 wlan3',bridge_empty='1',force_link='1',proto='static',ipaddr='192.168.50.1',netmask='255.255.255.0',delegate='0'})
    section('firewall','zone','zte_vpn_zone',{name='vpn',network={'vpn'},input='REJECT',output='ACCEPT',forward='REJECT'})
    section('firewall','include','zte_vpn_rules',{type='script',path=root..'/firewall.sh',reload='1',enabled='1'})
    for _,section in ipairs({'guest_2g','guest_5g'}) do
        assert(c:get('wireless',section) == 'wifi-iface', 'Guest section missing')
        set('wireless',section,'network','vpn'); set('wireless',section,'bridge','br-vpn')
        set('wireless',section,'isolate','1')
        set('wireless',section,'wps_state','0'); set('wireless',section,'disabled','1')
        -- Stock B31 "Free" maps to zero minutes. Leave the runtime countdown alone.
        set('wireless',section,'guest_active_time','0')
    end
    change_names_and_security(desired,security)
elseif mode == 'wifi-settings' then
    for _,name in ipairs({'guest_2g','guest_5g'}) do
        if c:get('wireless',name,'disabled')~='1' then fail('VPN_WIFI_SETTINGS_ENABLED') end
        if c:get('wireless',name,'network')~='vpn' or c:get('wireless',name,'bridge')~='br-vpn' then fail('VPN_WIFI_CONFIGURATION_CHANGED') end
    end
    local desired,security=wifi_values(true)
    change_names_and_security(desired,security)
    assert(c:save('wireless')); assert(c:commit('wireless'))
    print('UCI_wifi-settings=OK'); return
elseif mode == 'enable' or mode == 'disable' then
    if mode == 'enable' then
        local pending=io.open(root..'/wifi-settings.pending','r')
        if pending then pending:close();fail('VPN_WIFI_SETTINGS_PENDING') end
        guest_sections(true)
    end
    for _,section in ipairs({'guest_2g','guest_5g'}) do
        if mode == 'enable' then set('wireless',section,'guest_active_time','0') end
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
