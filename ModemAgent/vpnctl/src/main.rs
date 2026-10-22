mod awg;
mod catalog;
mod ikev2;
mod profile;
mod screen;
mod subscription;
mod wifi;
use profile::Result;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, DirBuilder, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const ROOT: &str = "/data/zte-vpn";
const OWNER: &str = "zte-vpn-v1";
const CORE_SHA: &str = "1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3";
// Captured B31/B28 modem image identities. B04 also requires its
// userspace profile below uses the same measured network init and VPN UCI schema.
const FW_SHAS: &[&str] = &[
    "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263", // CN B31
    "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478", // FLY B28 / public B13
];
const B04_FW_SHA: &str = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
const B04_MDM_SHA: &str = "93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64";
const FILES: &[(&str, &[u8])] = &[
    (
        "manager.sh",
        include_bytes!("../../../MacIMEI/Resources/VPN/manager.sh"),
    ),
    (
        "firewall.sh",
        include_bytes!("../../../MacIMEI/Resources/VPN/firewall.sh"),
    ),
    (
        "configure.lua",
        include_bytes!("../../../MacIMEI/Resources/VPN/configure.lua"),
    ),
    (
        "nft-guard.nft",
        include_bytes!("../../../MacIMEI/Resources/VPN/nft-guard.nft"),
    ),
    (
        "dnsmasq.conf",
        include_bytes!("../../../MacIMEI/Resources/VPN/dnsmasq.conf"),
    ),
    (
        "service.sh",
        include_bytes!("../../../MacIMEI/Resources/VPN/service.sh"),
    ),
    ("ikev2.sh", include_bytes!("../../../MacIMEI/Resources/VPN/ikev2.sh")),
    ("ikev2-updown.sh", include_bytes!("../../../MacIMEI/Resources/VPN/ikev2-updown.sh")),
    ("nft-ikev2-guard.nft", include_bytes!("../../../MacIMEI/Resources/VPN/nft-ikev2-guard.nft")),
];
fn path(s: &str) -> PathBuf {
    Path::new(ROOT).join(s)
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn read(p: &Path, max: u64) -> Result<Vec<u8>> {
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(p)
        .map_err(|_| "VPN_FILE_UNAVAILABLE")?;
    let m = f.metadata().map_err(|_| "VPN_FILE_UNAVAILABLE")?;
    if !m.is_file()
        || m.uid() != unsafe { libc::geteuid() }
        || m.permissions().mode() & 0o022 != 0
        || m.len() > max
    {
        return Err("VPN_UNSAFE_FILE");
    }
    let mut b = Vec::new();
    std::io::Read::by_ref(&mut f)
        .take(max + 1)
        .read_to_end(&mut b)
        .map_err(|_| "VPN_FILE_UNAVAILABLE")?;
    if b.len() as u64 > max {
        return Err("VPN_UNSAFE_FILE");
    }
    Ok(b)
}
fn atomic(p: &Path, b: &[u8]) -> Result<()> {
    let tmp = p.with_extension(format!("tmp-{}", std::process::id()));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)
        .map_err(|_| "VPN_WRITE_FAILED")?;
    let result = (|| {
        f.write_all(b).map_err(|_| "VPN_WRITE_FAILED")?;
        f.sync_all().map_err(|_| "VPN_WRITE_FAILED")?;
        fs::rename(&tmp, p).map_err(|_| "VPN_WRITE_FAILED")?;
        File::open(p.parent().unwrap())
            .and_then(|f| f.sync_all())
            .map_err(|_| "VPN_WRITE_FAILED")
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}
fn write_json(p: &Path, v: &Value) -> Result<()> {
    atomic(p, &serde_json::to_vec(v).map_err(|_| "VPN_WRITE_FAILED")?)
}
fn json_file(p: &Path) -> Result<Value> {
    serde_json::from_slice(&read(p, 128 * 1024)?).map_err(|_| "VPN_INVALID_STATE")
}
fn base() -> Result<()> {
    let m = fs::symlink_metadata(ROOT).map_err(|_| "VPN_NOT_INSTALLED")?;
    if !m.is_dir()
        || m.uid() != 0
        || m.permissions().mode() & 0o777 != 0o700
        || read(&path("owner"), 64)? != OWNER.as_bytes()
    {
        return Err("VPN_INTEGRITY");
    }
    for (name, bytes) in FILES {
        if read(&path(name), 1024 * 1024)? != *bytes {
            return Err("VPN_INTEGRITY");
        }
    }
    let expected = read(&path("cid"), 64)?;
    let actual = fs::read("/sys/block/mmcblk0/device/cid").map_err(|_| "VPN_DEVICE_CHANGED")?;
    if expected != actual {
        return Err("VPN_DEVICE_CHANGED");
    }
    Ok(())
}
fn integrity() -> Result<()> {
    base()?;
    if hash(&read(&path("mihomo"), 200 * 1024 * 1024)?) != CORE_SHA {
        return Err("VPN_CORE_INTEGRITY");
    }
    let firmware = match fs::symlink_metadata("/firmware/image/modem.b16") {
        Ok(metadata) if metadata.is_file() => Some(hash(&fs::read("/firmware/image/modem.b16").map_err(|_| "VPN_UNSUPPORTED_FIRMWARE")?)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        _ => return Err("VPN_UNSUPPORTED_FIRMWARE"),
    };
    if let Some(image) = firmware.as_deref() {
        if verify_firmware_hash(image).is_ok() { return Ok(()); }
        if image != B04_FW_SHA { return Err("VPN_UNSUPPORTED_FIRMWARE"); }
    }
    let mdm = hash(&read(Path::new("/usr/bin/zte_topsw_mdm"), 1024 * 1024)?);
    let router = hash(&read(Path::new("/usr/bin/diag-router"), 1024 * 1024)?);
    verify_b04_profile(firmware.as_deref(), &mdm, &router)
}
// This path is also used before netifd/vendor RPC startup. Match measured
// binaries rather than adding a dependency on zwrt_web being available.
fn verify_b04_profile(firmware: Option<&str>, mdm: &str, router: &str) -> Result<()> {
    if (firmware.is_none() || firmware == Some(B04_FW_SHA)) && mdm == B04_MDM_SHA && router == "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f" {
        Ok(())
    } else { Err("VPN_UNSUPPORTED_FIRMWARE") }
}
fn verify_firmware_hash(firmware: &str) -> Result<()> {
    if FW_SHAS.contains(&firmware) { Ok(()) } else { Err("VPN_UNSUPPORTED_FIRMWARE") }
}
fn run(program: &str, args: &[&str], seconds: u64) -> Result<Vec<u8>> {
    let output = process_runner::output(
        Command::new(program).args(args),
        None,
        Duration::from_secs(seconds),
        128 * 1024,
    )
    .map_err(|_| "VPN_OPERATION_TIMEOUT")?;
    if !output.status.success() {
        let text = String::from_utf8_lossy(&output.stderr);
        for line in text.lines() {
            if ERRORS.contains(&line) {
                return Err(ERRORS.iter().copied().find(|s| *s == line).unwrap());
            }
        }
        return Err("VPN_OPERATION_FAILED");
    }
    Ok(output.stdout)
}
const ERRORS: &[&str] = &[
    "VPN_IKEV2_UNAVAILABLE",
    "VPN_IKEV2_CONFLICT",
    "VPN_IKEV2_NOT_READY",
    "VPN_IKEV2_ROUTE_CONFLICT",
    "VPN_IKEV2_LTE_UNAVAILABLE",
    "VPN_MESH_CONFLICT",
    "VPN_IPA_ENABLED",
    "VPN_IPA_UNSUPPORTED",
    "VPN_IPA_NOT_RUNNING",
    "VPN_IPA_PREPARE_FAILED",
    "VPN_IPA_RESTORE_FAILED",
    "VPN_IPA_STATE_INVALID",
    "VPN_GUEST_IN_USE",
    "VPN_OTHER_PROXY",
    "VPN_SUBNET_CONFLICT",
    "VPN_ROUTE_CONFLICT",
    "VPN_PENDING_CHANGES",
    "VPN_BRIDGE_NOT_READY",
    "VPN_CORE_NOT_READY",
    "VPN_DHCP_NOT_READY",
    "VPN_WIFI_NOT_READY",
    "VPN_CONFIGURATION_PENDING",
    "VPN_NO_ACTIVE_PROFILE",
    "VPN_WIFI_SETTINGS_ENABLED",
    "VPN_WIFI_NOT_CONFIGURED",
    "VPN_WIFI_CONFIGURATION_CHANGED",
    "VPN_INVALID_WIFI_SSID",
    "VPN_INVALID_WIFI_PASSWORD",
    "VPN_INVALID_WIFI_SETTINGS",
    "VPN_WIFI_SETTINGS_PENDING",
];
fn manager(action: &str) -> Result<()> {
    run("/bin/sh", &["/data/zte-vpn/manager.sh", action], 170).map(|_| ())
}
fn recover_runtime(stop_requested: bool, mut action: impl FnMut(&str) -> Result<()>) -> Result<()> {
    // A request to turn Wi-Fi OFF must take precedence over transaction repair.
    if stop_requested { action("disable")?; }
    action("recover")
}
fn connect_profile(mut action: impl FnMut(&str) -> Result<()>) -> Result<()> {
    // Activate is the explicit Connect action; profile saves are separate.
    let result = action("activate").and_then(|_| action("enable"));
    if let Err(error) = result {
        // Stop first, then restore the old profile without an automatic PUSH.
        // The durable runtime-disabled fence survives a failed UCI commit.
        let _ = action("disable");
        let _ = action("recover");
        return Err(error);
    }
    Ok(())
}
struct Lock {
    token: Vec<u8>,
    owned: bool,
}
impl Lock {
    fn check_transactions() -> Result<()> {
        Self::check_transactions_at(Path::new("/"))
    }
    fn check_transactions_at(root: &Path) -> Result<()> {
        // Current operations coordinate through the shared application lock.
        // A saved legacy SSH/agent deployment journal does not own VPN files.
        match fs::symlink_metadata(root.join("tmp/fota_install_processing")) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            _ => Err("VPN_OTHER_TRANSACTION"),
        }
    }
    fn borrowed(token: &str) -> Result<Self> {
        Self::check_transactions()?;
        Self::borrowed_at(Path::new("/tmp/zte-imei-app.lock"), token, 0)
    }
    fn borrowed_at(directory: &Path, token: &str, uid: u32) -> Result<Self> {
        if !profile::valid_id(token) {
            return Err("VPN_BUSY");
        }
        let owner_path = directory.join("owner");
        let root = fs::symlink_metadata(directory).map_err(|_| "VPN_BUSY")?;
        let owner = fs::symlink_metadata(&owner_path).map_err(|_| "VPN_BUSY")?;
        if !root.is_dir()
            || root.uid() != uid
            || root.mode() & 0o777 != 0o700
            || !owner.is_file()
            || owner.uid() != uid
            || owner.mode() & 0o777 != 0o600
            || owner.nlink() != 1
            || read(&owner_path, 64)? != token.as_bytes()
        {
            return Err("VPN_BUSY");
        }
        Ok(Self {
            token: token.as_bytes().to_vec(),
            owned: false,
        })
    }
    fn new() -> Result<Self> {
        Self::check_transactions()?;
        let token = fs::read("/proc/sys/kernel/random/uuid").map_err(|_| "VPN_BUSY")?;
        DirBuilder::new()
            .mode(0o700)
            .create("/tmp/zte-imei-app.lock")
            .map_err(|_| "VPN_BUSY")?;
        if atomic(Path::new("/tmp/zte-imei-app.lock/owner"), &token).is_err() {
            let _ = fs::remove_dir("/tmp/zte-imei-app.lock");
            return Err("VPN_BUSY");
        }
        Ok(Self { token, owned: true })
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        if !self.owned {
            return;
        }
        let p = Path::new("/tmp/zte-imei-app.lock/owner");
        if fs::read(p).ok().as_deref() == Some(&self.token) {
            let _ = fs::remove_file(p);
            let _ = fs::remove_dir("/tmp/zte-imei-app.lock");
        }
    }
}
fn active() -> Result<String> {
    active_at(&path("active"))
}
fn active_at(file: &Path) -> Result<String> {
    match fs::symlink_metadata(file) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
        Err(_) => return Err("VPN_INVALID_STATE"),
        Ok(_) => (),
    }
    let value = String::from_utf8(read(file, 64)?).map_err(|_| "VPN_INVALID_STATE")?;
    let value = value.trim();
    if !profile::valid_id(value) { return Err("VPN_INVALID_STATE"); }
    Ok(value.into())
}
fn legacy_profiles() -> Result<Vec<Value>> {
    let mut result = Vec::new();
    for entry in fs::read_dir(path("profiles")).map_err(|_| "VPN_INVALID_STATE")? {
        let entry = entry.map_err(|_| "VPN_INVALID_STATE")?;
        let p = entry.path();
        if p.extension().is_some_and(|s| s == "json") {
            let v = json_file(&p)?;
            result.push(v);
        }
        if result.len() > subscription::PROFILE_LIMIT {
            return Err("VPN_PROFILE_LIMIT");
        }
    }
    result.sort_by_key(|p| p["name"].as_str().unwrap_or("").to_lowercase());
    Ok(result)
}
fn catalog() -> Result<catalog::Catalog> {
    let value = match fs::symlink_metadata(path("catalog.json")) {
        Ok(_) => serde_json::from_slice(&read(&path("catalog.json"), 32 * 1024 * 1024)?)
            .map_err(|_| "VPN_INVALID_STATE")?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => catalog::Catalog::legacy(legacy_profiles()?),
        Err(_) => return Err("VPN_INVALID_STATE"),
    };
    value.check()?;
    Ok(value)
}
fn save_catalog(catalog: &catalog::Catalog) -> Result<()> {
    catalog.check()?;
    let data = serde_json::to_vec(catalog).map_err(|_| "VPN_WRITE_FAILED")?;
    if data.len() > 32 * 1024 * 1024 { return Err("VPN_PROFILE_LIMIT"); }
    atomic(&path("catalog.json"), &data)
}
fn new_id() -> Result<String> {
    let id = fs::read_to_string("/proc/sys/kernel/random/uuid").map_err(|_| "VPN_WRITE_FAILED")?;
    let id = id.trim();
    if !profile::valid_id(id) { return Err("VPN_WRITE_FAILED"); }
    Ok(id.into())
}
fn import_profile(mut p: Value) -> Result<()> {
    let mut catalog = catalog()?;
    if catalog.profiles.iter().any(|old| old["proxy"] == p["proxy"]) { return Err("VPN_PROFILE_EXISTS"); }
    if catalog.profiles.len() >= subscription::PROFILE_LIMIT { return Err("VPN_PROFILE_LIMIT"); }
    validate(p["proxy"].clone())?;
    let id = new_id()?; p["id"] = json!(id);
    audit("import", &id)?;
    catalog.profiles.push(p);
    save_catalog(&catalog)
}
fn live_proxy(config: &Value) -> Value {
    if config["backend"] == "ikev2" { config["ikev2"].clone() }
    else { config["proxies"][0].clone() }
}
fn runtime_config(proxy: &Value) -> Value {
    if ikev2::is_ikev2(proxy) { json!({"backend":"ikev2","ikev2":proxy}) }
    else { profile::config(proxy.clone(), false) }
}
fn backend() -> Result<&'static str> {
    if !path("config.json").exists() { return Ok("mihomo"); }
    let config = json_file(&path("config.json"))?;
    if config["backend"] == "ikev2" { Ok("ikev2") }
    else if config.get("backend").is_none() && config["proxies"].is_array() { Ok("mihomo") }
    else { Err("VPN_INVALID_STATE") }
}
fn prepare_ikev2() -> Result<()> {
    let config = json_file(&path("config.json"))?;
    if config["backend"] != "ikev2" { return Err("VPN_IKEV2_INVALID_PROFILE"); }
    let proxy = ikev2::validate(&config["ikev2"])?;
    ikev2::check_certificate(&proxy)?;
    let directory = Path::new(ikev2::DIRECTORY);
    match fs::symlink_metadata(directory) {
        Ok(m) if m.is_dir() && m.uid() == 0 && m.mode() & 0o777 == 0o700 => (),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            DirBuilder::new().mode(0o700).create(directory).map_err(|_| "VPN_WRITE_FAILED")?;
        }
        _ => return Err("VPN_UNSAFE_FILE"),
    }
    for (name, data) in ikev2::files(&proxy)? { atomic(&directory.join(name), data.as_bytes())?; }
    Ok(())
}
fn core_running() -> bool {
    if backend().ok() == Some("ikev2") {
        return run("/bin/sh", &["/data/zte-vpn/ikev2.sh", "running"], 5).is_ok();
    }
    let Some(pid) = fs::read_to_string(path("core.pid"))
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
    else {
        return false;
    };
    fs::read(format!("/proc/{pid}/cmdline"))
        .ok()
        .is_some_and(|b| {
            b.split(|x| *x == 0)
                .any(|arg| arg == b"/data/zte-vpn/mihomo")
        })
}
fn network_status() -> Result<Value> {
    serde_json::from_slice(&run("lua", &["/data/zte-vpn/configure.lua", "status"], 10)?)
        .map_err(|_| "VPN_INVALID_STATE")
}
fn wifi_settings() -> Result<Option<wifi::Settings>> {
    let file = path("wifi-settings.json");
    let metadata = match fs::symlink_metadata(&file) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("VPN_INVALID_WIFI_SETTINGS"),
    };
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
    {
        return Err("VPN_UNSAFE_FILE");
    }
    let settings: wifi::Settings =
        serde_json::from_slice(&read(&file, 4096)?).map_err(|_| "VPN_INVALID_WIFI_SETTINGS")?;
    settings.validate(path("configured").is_file())?;
    Ok(Some(settings))
}
fn configure_wifi(settings: wifi::Settings) -> Result<()> {
    let configured = path("configured").is_file();
    settings.validate(configured)?;
    let network = network_status()?;
    if configured {
        if network["any_enabled"] == true {
            return Err("VPN_WIFI_SETTINGS_ENABLED");
        }
        if network["network_ok"] != true {
            return Err("VPN_WIFI_CONFIGURATION_CHANGED");
        }
    }
    let previous = wifi_settings()?;
    persist_wifi_settings(
        Path::new(ROOT),
        &settings,
        previous.as_ref(),
        configured,
        || run("lua", &["/data/zte-vpn/configure.lua", "wifi-settings"], 10).map(|_| ()),
    )?;
    audit("wifi_settings_saved", "")
}
// The file transaction is separate from UCI so failures can be injected without
// accessing a modem or invoking network commands.
fn persist_wifi_settings(
    directory: &Path,
    settings: &wifi::Settings,
    previous: Option<&wifi::Settings>,
    configured: bool,
    apply: impl FnOnce() -> Result<()>,
) -> Result<()> {
    let preferences = directory.join("wifi-settings.json");
    let pending = directory.join("wifi-settings.pending");
    if configured {
        atomic(&pending, b"1")?;
    }
    write_json(
        &preferences,
        &serde_json::to_value(settings).map_err(|_| "VPN_INVALID_WIFI_SETTINGS")?,
    )?;
    if configured {
        if let Err(error) = apply() {
            if let Some(previous) = previous {
                write_json(
                    &preferences,
                    &serde_json::to_value(previous).map_err(|_| "VPN_INVALID_WIFI_SETTINGS")?,
                )?;
            } else {
                fs::remove_file(&preferences).map_err(|_| "VPN_WRITE_FAILED")?;
            }
            // UCI may have left partial saved deltas before reporting an error.
            // Keep activation blocked until an explicit settings save succeeds.
            return Err(error);
        }
        fs::remove_file(pending).map_err(|_| "VPN_WRITE_FAILED")?;
        File::open(directory)
            .and_then(|f| f.sync_all())
            .map_err(|_| "VPN_WRITE_FAILED")?;
    }
    Ok(())
}
fn status() -> Result<Value> {
    base()?;
    let network = network_status()?;
    let configured = path("configured").is_file();
    let settings = wifi_settings()?;
    let desired_ssid = settings
        .as_ref()
        .map(|s| s.ssid.as_str())
        .unwrap_or_else(|| {
            if configured {
                network["ssid"].as_str().unwrap_or("")
            } else {
                "ZTE-VPN"
            }
        });
    let password_mode = settings
        .as_ref()
        .map(|s| s.password_mode)
        .unwrap_or(if configured {
            wifi::PasswordMode::Preserve
        } else {
            wifi::PasswordMode::Main
        });
    let active = active()?;
    let mut list = Vec::new();
    let catalog = catalog()?;
    let live = json_file(&path("config.json")).ok();
    for p in &catalog.profiles {
        let selected = p["id"].as_str()==Some(&active);
        list.push(json!({"id":p["id"],"name":p["name"],"transport":p["proxy"]["network"].as_str().unwrap_or(""),"protocol":subscription::protocol(&p["proxy"]),"warnings":p["warnings"],"active":selected,"subscription_id":p["subscription_id"],"update_available":selected&&live.as_ref().is_some_and(|v| live_proxy(v)!=p["proxy"]),"removed_from_subscription":p["removed_from_subscription"]==true}));
    }
    list.sort_by_key(|p| p["name"].as_str().unwrap_or("").to_lowercase());
    let ike_active = live.as_ref().is_some_and(|v| v["backend"] == "ikev2");
    let ike_available = Path::new("/usr/lib/ipsec/charon").is_file() && Path::new("/usr/sbin/swanctl").is_file();
    let ike_connected = ike_active && run("/bin/sh", &["/data/zte-vpn/ikev2.sh", "connected"], 5).is_ok();
    let ike_state = if ike_connected { "connected" } else {
        match fs::read_to_string(path("ikev2/auth-state")).ok().as_deref().map(str::trim) {
            Some("waiting") | Some("connecting") if ike_active => "waiting",
            _ => "disconnected",
        }
    };
    let enabled = configured && network["enabled"] == true && !path("runtime-disabled").exists();
    let subscriptions: Vec<Value> = catalog.subscriptions.iter().map(|s| json!({"id":s["id"],"name":s["name"],"host":s["host"],"updated_at":s["updated_at"],"profile_count":catalog.profiles.iter().filter(|p|p["subscription_id"]==s["id"]).count()})).collect();
    Ok(
        json!({"schema_version":1,"installed":true,"version":env!("CARGO_PKG_VERSION"),"core_version":if ike_active {"strongSwan"} else {"1.19.31"},"core_available":if ike_active {ike_available} else {path("mihomo").is_file()},"backend":if ike_active {"ikev2"} else {"mihomo"},"ikev2_available":ike_available,"ikev2_connected":ike_connected,"ikev2_state":ike_state,"routing_mode":if ike_active {"private_vpn_public_lte"} else {"vpn"},"configured":configured,"enabled":enabled,"core_running":core_running(),"network_ok":configured&&network["network_ok"]==true,"mesh_conflict":network["mesh"],"ssid":network["ssid"],"ssid_2g":network["ssid_2g"],"ssid_5g":network["ssid_5g"],"main_ssid":network["main_ssid"],"desired_ssid":desired_ssid,"password_mode":password_mode,"wifi_settings_pending":!configured||path("wifi-settings.pending").exists(),"settings_supported":true,"profiles":list,"subscriptions":subscriptions,"active_profile":active,"screen":screen::status(),"recovery_pending":path("transaction").exists()}),
    )
}
fn validate(proxy: Value) -> Result<()> {
    if ikev2::is_ikev2(&proxy) {
        let p = ikev2::validate(&proxy)?;
        return ikev2::check_certificate(&p);
    }
    validate_config(profile::config(proxy, true))
}
fn validate_config(config: Value) -> Result<()> {
    let p = path("validate.json");
    write_json(&p, &config)?;
    let out = process_runner::output(
        Command::new(path("mihomo")).args(["-t", "-d", ROOT, "-f", p.to_str().unwrap()]),
        None,
        Duration::from_secs(30),
        128 * 1024,
    )
    .map_err(|_| "VPN_VALIDATION_FAILED");
    let _ = fs::remove_file(p);
    let out = out?;
    let mut logs = out.stdout;
    logs.extend(out.stderr);
    atomic(&path("last-validation.log"), &logs)?;
    if !out.status.success() {
        return Err("VPN_VALIDATION_FAILED");
    }
    Ok(())
}
fn audit(action: &str, id: &str) -> Result<()> {
    audit_event(action, id, None)
}
fn audit_event(action: &str, id: &str, code: Option<&str>) -> Result<()> {
    let mut f = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path("profile-actions.jsonl"))
        .map_err(|_| "VPN_AUDIT_FAILED")?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut event = json!({"time":now,"action":action,"profile_id":id});
    if let Some(code) = code { event["code"] = json!(code); }
    writeln!(f, "{}", event)
        .map_err(|_| "VPN_AUDIT_FAILED")?;
    f.sync_all().map_err(|_| "VPN_AUDIT_FAILED")
}
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Status,
    Import {
        uri: String,
        name: Option<String>,
    },
    ImportConfig { config: String, name: Option<String> },
    SaveIkev2 { id: Option<String>, name: String, ikev2: ikev2::Input },
    SubscriptionImport { url: String, name: Option<String>, documents: Option<Vec<String>> },
    SubscriptionUpdate { id: String, documents: Option<Vec<String>> },
    SubscriptionDelete { id: String },
    SubscriptionDetails { id: String },
    Activate {
        id: String,
    },
    Delete {
        id: String,
    },
    Rename {
        id: String,
        name: String,
    },
    Details {
        id: String,
    },
    SetEnabled {
        enabled: bool,
    },
    ConfigureWifi {
        ssid: String,
        password_mode: wifi::PasswordMode,
        password: Option<String>,
        lock_token: Option<String>,
    },
    Recover,
    ScreenOpen {
        page: String,
    },
    ScreenClose,
}
fn dispatch(req: Request) -> Result<Value> {
    let updating = match &req {
        Request::SubscriptionUpdate { id, .. } if profile::valid_id(id) => Some(id.clone()),
        _ => None,
    };
    let result = dispatch_inner(req);
    if let (Some(id), Err(code)) = (updating, &result) {
        if base().is_ok() {
            let _ = audit_event("subscription_update_failed", &id, Some(code));
        }
    }
    result
}
fn dispatch_inner(req: Request) -> Result<Value> {
    if matches!(req, Request::Status) {
        return status();
    }
    if let Request::Details { id } = req {
        base()?;
        let catalog = catalog()?;
        let p = catalog.profile(&id)?;
        return Ok(json!({"schema_version":1,"profile":ikev2::redacted(p),"active":active()?==id}));
    }
    if let Request::SubscriptionDetails { id } = req {
        base()?;
        let catalog = catalog()?;
        return Ok(json!({"schema_version":1,"subscription":catalog.subscription(&id)?}));
    }
    if let Request::ScreenOpen { page } = req {
        return screen::open(&page);
    }
    if matches!(req, Request::ScreenClose) {
        return screen::close();
    }
    integrity()?;
    let _ = wifi_settings()?;
    let _lock = match &req {
        Request::ConfigureWifi {
            lock_token: Some(token),
            ..
        } => Lock::borrowed(token)?,
        _ => Lock::new()?,
    };
    if path("transaction").exists()
        || path("transaction.preparing").exists()
        || path("transaction.done").exists()
    {
        recover_runtime(matches!(req, Request::SetEnabled { enabled: false }), manager)?;
    }
    let mut summary = None;
    match req {
        Request::ConfigureWifi {
            ssid,
            password_mode,
            password,
            ..
        } => {
            configure_wifi(wifi::Settings {
                ssid,
                password_mode,
                password,
            })?;
        }
        Request::Import { uri, name } => {
            let (name, proxy, warnings) = profile::parse(&uri, name.as_deref())?;
            import_profile(json!({"name":name,"protocol":subscription::protocol(&proxy),"proxy":proxy,"warnings":warnings,"source_uri":uri}))?;
        }
        Request::SaveIkev2 { id, name, ikev2 } => {
            let name = profile::name(&name)?;
            let mut catalog = catalog()?;
            let previous = id.as_ref().map(|id| catalog.profile(id)).transpose()?;
            if previous.is_some_and(|p| !crate::ikev2::is_ikev2(&p["proxy"])) {
                return Err("VPN_IKEV2_INVALID_PROFILE");
            }
            let proxy = ikev2.into_proxy(previous.map(|p| &p["proxy"]))?;
            validate(proxy.clone())?;
            if let Some(id) = id {
                audit("ikev2_saved", &id)?;
                *catalog.profiles.iter_mut().find(|p| p["id"] == id).unwrap() =
                    json!({"id":id,"name":name,"protocol":"ikev2","proxy":proxy,"warnings":[]});
                save_catalog(&catalog)?;
            } else {
                import_profile(json!({"name":name,"protocol":"ikev2","proxy":proxy,"warnings":[]}))?;
            }
        }
        Request::ImportConfig { config, name } => {
            let parsed = awg::parse(&config)?;
            let name = profile::name(name.as_deref().unwrap_or(parsed.protocol))?;
            import_profile(json!({"name":name,"protocol":parsed.protocol,"proxy":parsed.proxy,"warnings":parsed.warnings,"source_config":config}))?;
        }
        Request::SubscriptionImport { url, name, documents } => {
            let host = subscription::host(&url)?;
            let mut catalog = catalog()?;
            if catalog.subscriptions.iter().any(|s| s["url"] == url) { return Err("VPN_SUBSCRIPTION_EXISTS"); }
            let name = profile::name(name.as_deref().unwrap_or(&host))?;
            let id = new_id()?;
            let parsed = subscription_input(&url, documents)?;
            summary = Some(catalog.update(json!({"id":id,"url":url,"host":host,"name":name,"updated_at":timestamp()}), parsed, &active()?, new_id)?);
            audit("subscription_import", &id)?;
            save_catalog(&catalog)?;
        }
        Request::SubscriptionUpdate { id, documents } => {
            let mut catalog = catalog()?;
            let mut sub = catalog.subscription(&id)?.clone();
            let url = sub["url"].as_str().ok_or("VPN_INVALID_STATE")?;
            let parsed = subscription_input(url, documents)?;
            sub["updated_at"] = json!(timestamp());
            summary = Some(catalog.update(sub, parsed, &active()?, new_id)?);
            audit("subscription_update", &id)?;
            save_catalog(&catalog)?;
        }
        Request::SubscriptionDelete { id } => {
            let mut catalog = catalog()?;
            catalog.detach(&id)?;
            audit("subscription_delete", &id)?;
            save_catalog(&catalog)?;
        }
        Request::Rename { id, name } => {
            let mut catalog = catalog()?;
            let mut p = catalog.profile(&id)?.clone();
            profile::rename(&mut p, &name)?;
            p["custom_name"] = json!(true);
            audit("rename", &id)?;
            *catalog.profiles.iter_mut().find(|old| old["id"] == id).unwrap() = p;
            save_catalog(&catalog)?;
        }
        Request::Delete { id } => {
            if active()? == id {
                return Err("VPN_ACTIVE_PROFILE_DELETE");
            }
            let mut catalog = catalog()?;
            catalog.profile(&id)?;
            audit("delete", &id)?;
            catalog.profiles.retain(|p| p["id"] != id);
            save_catalog(&catalog)?;
        }
        Request::Activate { id } => {
            let catalog = catalog()?;
            let p = catalog.profile(&id)?;
            validate(p["proxy"].clone())?;
            if ikev2::is_ikev2(&p["proxy"]) {
                run("/bin/sh", &["/data/zte-vpn/ikev2.sh", "check"], 10)?;
            }
            audit("activate_requested", &id)?;
            // Publish a complete rollback snapshot before changing either live file.
            DirBuilder::new()
                .mode(0o700)
                .create(path("transaction.preparing"))
                .map_err(|_| "VPN_WRITE_FAILED")?;
            for file in ["config.json", "active"] {
                if path(file).exists() {
                    atomic(
                        &path(&format!("transaction.preparing/{file}")),
                        &read(&path(file), 128 * 1024)?,
                    )?;
                }
            }
            fs::rename(path("transaction.preparing"), path("transaction"))
                .map_err(|_| "VPN_WRITE_FAILED")?;
            File::open(ROOT)
                .and_then(|f| f.sync_all())
                .map_err(|_| "VPN_WRITE_FAILED")?;
            write_json(
                &path("config.json"),
                &runtime_config(&p["proxy"]),
            )?;
            connect_profile(manager)?;
            atomic(&path("active"), id.as_bytes())?;
            // One durable rename commits the pair. Interrupted cleanup cannot trigger rollback.
            fs::rename(path("transaction"), path("transaction.done"))
                .map_err(|_| "VPN_WRITE_FAILED")?;
            File::open(ROOT)
                .and_then(|f| f.sync_all())
                .map_err(|_| "VPN_WRITE_FAILED")?;
            fs::remove_dir_all(path("transaction.done")).map_err(|_| "VPN_WRITE_FAILED")?;
            audit("activated", &id)?;
        }
        Request::SetEnabled { enabled } => {
            if enabled && path("wifi-settings.pending").exists() {
                return Err("VPN_WIFI_SETTINGS_PENDING");
            }
            audit(if enabled { "enable" } else { "disable" }, &active()?)?;
            manager(if enabled { "enable" } else { "disable" })?;
        }
        Request::Recover => {
            manager("recover")?;
        }
        Request::Status
        | Request::Details { .. }
        | Request::SubscriptionDetails { .. }
        | Request::ScreenOpen { .. }
        | Request::ScreenClose => unreachable!(),
    }
    let mut status = status()?;
    if let Some(summary) = summary { status["last_import"] = summary; }
    Ok(status)
}

fn timestamp() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()
}
fn subscription_input(url: &str, documents: Option<Vec<String>>) -> Result<subscription::Parsed> {
    let parsed = if let Some(documents) = documents { subscription::select(&documents)? } else { subscription::fetch(url)? };
    // One parser-only core invocation checks an entire feed without connecting.
    let mut config = profile::config(parsed.profiles[0]["proxy"].clone(), true);
    config["proxies"] = Value::Array(parsed.profiles.iter().enumerate().map(|(i,p)| {
        let mut proxy = p["proxy"].clone(); if i != 0 { proxy["name"] = json!(format!("Node-{i}")); } proxy
    }).collect());
    // Do not multiply a failed 30-second validation by the number of nodes.
    // Any core rejection leaves the entire existing catalog unchanged.
    validate_config(config)?;
    Ok(parsed)
}

fn hook_network() -> Result<()> {
    base()?;
    let p = Path::new("/etc/init.d/network");
    let original = include_bytes!("../../../MacIMEI/Resources/VPN/network.stock");
    let current = read(p, 128 * 1024)?;
    if current != original {
        return Err("VPN_NETWORK_INIT_CHANGED");
    }
    let manager_hash = hash(FILES[0].1);
    let helper_hash = hash(&read(&path("vpnctl"), 16 * 1024 * 1024)?);
    let block = format!(
        r#"
    # BEGIN zte-vpn-v1: guard before the existing queued S11 network service.
    if [ -f /data/zte-vpn/configured ]; then
        if [ "$(sha256sum /data/zte-vpn/manager.sh 2>/dev/null | awk '{{print $1}}')" = {manager_hash} ] &&
           [ "$(sha256sum /data/zte-vpn/vpnctl 2>/dev/null | awk '{{print $1}}')" = {helper_hash} ] &&
           /bin/sh /data/zte-vpn/manager.sh early; then :; else
            uci -q set wireless.guest_2g.disabled=1
            uci -q set wireless.guest_5g.disabled=1
            uci -q commit wireless
        fi
    fi
    # END zte-vpn-v1
"#
    );
    let text = String::from_utf8(current).map_err(|_| "VPN_NETWORK_INIT_CHANGED")?;
    if text.matches("start_service() {").count() != 1 {
        return Err("VPN_NETWORK_INIT_CHANGED");
    }
    let patched = text.replacen(
        "start_service() {",
        &format!("start_service() {{{block}"),
        1,
    );
    atomic(p, patched.as_bytes())?;
    fs::set_permissions(p, fs::Permissions::from_mode(0o755)).map_err(|_| "VPN_WRITE_FAILED")?;
    atomic(
        &path("network-init.sha256"),
        hash(patched.as_bytes()).as_bytes(),
    )
}
fn main() {
    unsafe {
        libc::umask(0o077);
    }
    let result = (|| -> Result<Value> {
        if unsafe { libc::geteuid() } != 0 {
            return Err("VPN_ROOT_REQUIRED");
        }
        match std::env::args().nth(1).as_deref() {
            Some("integrity") => {
                integrity()?;
                Ok(json!({"verified":true}))
            }
            Some("backend") => {
                base()?;
                println!("{}", backend()?);
                std::process::exit(0);
            }
            Some("prepare-ikev2") => {
                integrity()?;
                prepare_ikev2()?;
                Ok(json!({"prepared":true}))
            }
            Some("hook-network") => {
                hook_network()?;
                Ok(json!({"installed":true}))
            }
            Some("request") => {
                let mut input = Vec::new();
                std::io::stdin()
                    .take(subscription::REQUEST_LIMIT as u64 + 1)
                    .read_to_end(&mut input)
                    .map_err(|_| "VPN_INVALID_REQUEST")?;
                if input.len() > subscription::REQUEST_LIMIT {
                    return Err("VPN_REQUEST_TOO_LARGE");
                }
                let req: Request =
                    serde_json::from_slice(&input).map_err(|_| "VPN_INVALID_REQUEST")?;
                dispatch(req)
            }
            _ => Err("VPN_INVALID_REQUEST"),
        }
    })();
    match result {
        Ok(data) => println!("{}", json!({"ok":true,"data":data})),
        Err(code) => {
            println!("{}", json!({"ok":false,"code":code}));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod wifi_request_tests {
    use super::*;
    #[test]
    fn explicit_connect_enables_previously_disabled_wifi_once() {
        let mut enabled = false;
        let mut connections = 0;
        connect_profile(|action| {
            match action {
                "activate" => assert!(!enabled),
                "enable" => { enabled = true; connections += 1; }
                _ => panic!("unexpected recovery on successful Connect"),
            }
            Ok(())
        }).unwrap();
        assert!(enabled);
        assert_eq!(connections, 1);
    }
    #[test]
    fn failed_connect_restores_profile_only_after_stopping_runtime() {
        for failed_action in ["activate", "enable"] {
            let mut enabled = true;
            let mut restored = false;
            let error = connect_profile(|action| {
                if action == failed_action { return Err("VPN_CORE_NOT_READY"); }
                match action {
                    "disable" => enabled = false,
                    "recover" => { assert!(!enabled, "rollback must not issue a PUSH"); restored = true; }
                    _ => (),
                }
                Ok(())
            });
            assert_eq!(error, Err("VPN_CORE_NOT_READY"));
            assert!(!enabled);
            assert!(restored);
        }
    }
    #[test]
    fn off_request_dominates_pending_profile_recovery() {
        let mut enabled = true;
        let mut restored = false;
        recover_runtime(true, |action| {
            match action {
                "disable" => enabled = false,
                "recover" => { assert!(!enabled); restored = true; }
                _ => unreachable!(),
            }
            Ok(())
        }).unwrap();
        assert!(restored);
        assert_eq!(recover_runtime(true, |action| {
            assert_eq!(action, "disable", "failed OFF must not proceed to recovery");
            Err("VPN_OPERATION_FAILED")
        }), Err("VPN_OPERATION_FAILED"));
    }
    #[test]
    fn legacy_deployment_journals_do_not_block_vpn_but_firmware_update_does() {
        let root = std::env::temp_dir().join(format!("zte-vpn-transactions-{}", std::process::id()));
        fs::create_dir_all(root.join("tmp")).unwrap();
        for legacy in ["data/local/tmp/zte-imei-installations", "data/local/tmp/open-u60-transactions"] {
            fs::create_dir_all(root.join(legacy)).unwrap();
            fs::write(root.join(legacy).join("active"), b"saved-deployment").unwrap();
        }
        assert!(Lock::check_transactions_at(&root).is_ok());
        let fota = root.join("tmp/fota_install_processing");
        fs::write(&fota, b"active").unwrap();
        assert_eq!(Lock::check_transactions_at(&root), Err("VPN_OTHER_TRANSACTION"));
        fs::remove_file(&fota).unwrap();
        std::os::unix::fs::symlink("missing-update-state", &fota).unwrap();
        assert_eq!(Lock::check_transactions_at(&root), Err("VPN_OTHER_TRANSACTION"));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn unreadable_or_corrupt_active_profile_is_not_treated_as_missing() {
        let root = std::env::temp_dir().join(format!("zte-vpn-active-{}", std::process::id()));
        DirBuilder::new().mode(0o700).create(&root).unwrap();
        let file = root.join("active");
        assert_eq!(active_at(&file).unwrap(), "");
        for bytes in [b"".as_slice(), b"invalid", &[255,254]] {
            atomic(&file,bytes).unwrap(); assert!(active_at(&file).is_err());
        }
        atomic(&file,b"20000000-0000-0000-0000-000000000000\n").unwrap();
        assert_eq!(active_at(&file).unwrap(), "20000000-0000-0000-0000-000000000000");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(active_at(&file).is_err());
        fs::remove_file(&file).unwrap();
        std::os::unix::fs::symlink("missing", &file).unwrap();
        assert!(active_at(&file).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn captured_b04_requires_both_userspace_binaries() {
        let router = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f";
        assert!(verify_b04_profile(None, B04_MDM_SHA, router).is_ok());
        assert!(verify_b04_profile(Some(B04_FW_SHA), B04_MDM_SHA, router).is_ok());
        assert!(verify_b04_profile(Some(B04_FW_SHA), &"0".repeat(64), router).is_err());
        assert!(verify_b04_profile(Some(B04_FW_SHA), B04_MDM_SHA, &"0".repeat(64)).is_err());
        assert!(verify_b04_profile(Some(&"0".repeat(64)), B04_MDM_SHA, router).is_err());
        assert!(verify_firmware_hash(B04_FW_SHA).is_err()); // Image alone is not the B04 profile.
        assert!(verify_b04_profile(None, &"0".repeat(64), router).is_err());
        assert!(verify_b04_profile(None, B04_MDM_SHA, &"0".repeat(64)).is_err());
        assert!(verify_b04_profile(None, "BD_XCBZHKMU5250V1.0.0B04", router).is_err());
    }
    #[test]
    fn captured_b28_and_b31_firmware_are_supported_but_unknown_is_not() {
        for firmware in [
            "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478",
            "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263",
        ] { assert!(verify_firmware_hash(firmware).is_ok()); }
        for firmware in ["", "B28", "B31", &"f".repeat(64)] {
            assert_eq!(verify_firmware_hash(firmware), Err("VPN_UNSUPPORTED_FIRMWARE"));
        }
    }
    #[test]
    fn strict_wifi_request_accepts_explicit_modes_without_revealing_password() {
        let req: Request = serde_json::from_str(
            r#"{"action":"configure_wifi","ssid":"ZTE-VPN","password_mode":"main"}"#,
        )
        .unwrap();
        assert!(matches!(
            req,
            Request::ConfigureWifi {
                password_mode: wifi::PasswordMode::Main,
                password: None,
                lock_token: None,
                ..
            }
        ));
        for bad in [
            r#"{"action":"configure_wifi","ssid":"ZTE-VPN","password_mode":"unknown"}"#,
            r#"{"action":"configure_wifi","ssid":"ZTE-VPN","password_mode":"main","shell":"run"}"#,
            r#"{"action":"configure_wifi","ssid":"ZTE-VPN","use_main_password":true}"#,
        ] {
            assert!(serde_json::from_str::<Request>(bad).is_err());
        }
    }
    #[test]
    fn borrowed_lock_requires_exact_private_metadata_and_never_removes_owner() {
        let base = std::env::temp_dir().join(format!("zte-vpn-borrow-lock-{}", std::process::id()));
        DirBuilder::new().mode(0o700).create(&base).unwrap();
        let token = "01234567-89ab-cdef-0123-456789abcdef";
        let owner = base.join("owner");
        atomic(&owner, token.as_bytes()).unwrap();
        let uid = unsafe { libc::geteuid() };
        let borrowed = Lock::borrowed_at(&base, token, uid).unwrap();
        drop(borrowed);
        assert!(owner.exists());
        assert!(Lock::borrowed_at(&base, "11234567-89ab-cdef-0123-456789abcdef", uid).is_err());
        assert!(Lock::borrowed_at(&base, "invalid", uid).is_err());
        fs::set_permissions(&owner, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Lock::borrowed_at(&base, token, uid).is_err());
        fs::set_permissions(&owner, fs::Permissions::from_mode(0o600)).unwrap();
        fs::hard_link(&owner, base.join("extra")).unwrap();
        assert!(Lock::borrowed_at(&base, token, uid).is_err());
        fs::remove_file(base.join("extra")).unwrap();
        fs::rename(&owner, base.join("real-owner")).unwrap();
        std::os::unix::fs::symlink("real-owner", &owner).unwrap();
        assert!(Lock::borrowed_at(&base, token, uid).is_err());
        fs::remove_file(&owner).unwrap();
        fs::rename(base.join("real-owner"), &owner).unwrap();
        fs::set_permissions(&base, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(Lock::borrowed_at(&base, token, uid).is_err());
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
        fs::remove_dir_all(base).unwrap();
    }
    #[test]
    fn wifi_file_transaction_retains_failure_guard_until_explicit_success() {
        let directory =
            std::env::temp_dir().join(format!("zte-wifi-transaction-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        DirBuilder::new().mode(0o700).create(&directory).unwrap();
        let old = wifi::Settings {
            ssid: "Existing".into(),
            password_mode: wifi::PasswordMode::Preserve,
            password: None,
        };
        let desired = wifi::Settings::default();
        let preferences = directory.join("wifi-settings.json");
        let pending = directory.join("wifi-settings.pending");
        assert_eq!(
            persist_wifi_settings(&directory, &desired, Some(&old), true, || {
                assert!(pending.exists());
                assert_eq!(
                    serde_json::from_slice::<Value>(&fs::read(&preferences).unwrap()).unwrap()
                        ["ssid"],
                    "ZTE-VPN"
                );
                Err("VPN_OPERATION_FAILED")
            }),
            Err("VPN_OPERATION_FAILED")
        );
        assert!(pending.exists());
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(&preferences).unwrap()).unwrap()["ssid"],
            "Existing"
        );
        assert!(persist_wifi_settings(&directory, &desired, Some(&old), true, || Ok(())).is_ok());
        assert!(!pending.exists());
        assert_eq!(fs::metadata(&preferences).unwrap().mode() & 0o777, 0o600);
        assert_eq!(
            persist_wifi_settings(&directory, &desired, None, true, || Err(
                "VPN_INVALID_WIFI_PASSWORD"
            )),
            Err("VPN_INVALID_WIFI_PASSWORD")
        );
        assert!(pending.exists());
        assert!(!preferences.exists());
        assert!(persist_wifi_settings(&directory, &desired, None, true, || Ok(())).is_ok());
        assert!(!pending.exists());
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn new_wifi_preferences_do_not_apply_network_settings() {
        let directory = std::env::temp_dir().join(format!("zte-wifi-new-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        DirBuilder::new().mode(0o700).create(&directory).unwrap();
        assert!(persist_wifi_settings(
            &directory,
            &wifi::Settings::default(),
            None,
            false,
            || panic!("must not configure network")
        )
        .is_ok());
        assert!(!directory.join("wifi-settings.pending").exists());
        assert!(directory.join("wifi-settings.json").exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
