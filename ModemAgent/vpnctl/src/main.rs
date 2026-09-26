mod profile;
mod screen;
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
const FW_SHA: &str = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
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
    if hash(&fs::read("/firmware/image/modem.b16").map_err(|_| "VPN_UNSUPPORTED_FIRMWARE")?)
        != FW_SHA
    {
        return Err("VPN_UNSUPPORTED_FIRMWARE");
    }
    Ok(())
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
    "VPN_MESH_CONFLICT",
    "VPN_IPA_ENABLED",
    "VPN_GUEST_IN_USE",
    "VPN_OTHER_PROXY",
    "VPN_SUBNET_CONFLICT",
    "VPN_ROUTE_CONFLICT",
    "VPN_PENDING_CHANGES",
    "VPN_BRIDGE_NOT_READY",
    "VPN_CORE_NOT_READY",
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
struct Lock {
    token: Vec<u8>,
    owned: bool,
}
impl Lock {
    fn check_transactions() -> Result<()> {
        for p in [
            "/data/local/tmp/zte-imei-installations/active",
            "/data/local/tmp/open-u60-transactions/active",
            "/tmp/fota_install_processing",
        ] {
            if fs::symlink_metadata(p).is_ok() {
                return Err("VPN_OTHER_TRANSACTION");
            }
        }
        Ok(())
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
fn active() -> String {
    String::from_utf8(read(&path("active"), 64).unwrap_or_default())
        .unwrap_or_default()
        .trim()
        .into()
}
fn profiles() -> Result<Vec<Value>> {
    let mut result = Vec::new();
    for entry in fs::read_dir(path("profiles")).map_err(|_| "VPN_INVALID_STATE")? {
        let entry = entry.map_err(|_| "VPN_INVALID_STATE")?;
        let p = entry.path();
        if p.extension().is_some_and(|s| s == "json") {
            let v = json_file(&p)?;
            result.push(v);
        }
        if result.len() > 32 {
            return Err("VPN_PROFILE_LIMIT");
        }
    }
    result.sort_by_key(|p| p["name"].as_str().unwrap_or("").to_lowercase());
    Ok(result)
}
fn core_running() -> bool {
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
    let active = active();
    let mut list = Vec::new();
    for p in profiles()? {
        list.push(json!({"id":p["id"],"name":p["name"],"transport":p["proxy"]["network"],"warnings":p["warnings"],"active":p["id"].as_str()==Some(&active)}));
    }
    Ok(
        json!({"schema_version":1,"installed":true,"version":env!("CARGO_PKG_VERSION"),"core_version":"1.19.31","core_available":path("mihomo").is_file(),"configured":configured,"enabled":configured&&network["enabled"]==true,"core_running":core_running(),"network_ok":configured&&network["network_ok"]==true,"mesh_conflict":network["mesh"],"ssid":network["ssid"],"ssid_2g":network["ssid_2g"],"ssid_5g":network["ssid_5g"],"main_ssid":network["main_ssid"],"desired_ssid":desired_ssid,"password_mode":password_mode,"wifi_settings_pending":!configured||path("wifi-settings.pending").exists(),"settings_supported":true,"profiles":list,"active_profile":active,"screen":screen::status(),"recovery_pending":path("transaction").exists()}),
    )
}
fn profile_path(id: &str) -> Result<PathBuf> {
    if !profile::valid_id(id) {
        return Err("VPN_INVALID_PROFILE_ID");
    }
    Ok(path(&format!("profiles/{id}.json")))
}
fn validate(proxy: Value) -> Result<()> {
    let p = path("validate.json");
    write_json(&p, &profile::config(proxy, true))?;
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
    writeln!(f, "{}", json!({"time":now,"action":action,"profile_id":id}))
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
    if matches!(req, Request::Status) {
        return status();
    }
    if let Request::Details { id } = req {
        base()?;
        let p = json_file(&profile_path(&id)?)?;
        return Ok(json!({"schema_version":1,"profile":p,"active":active()==id}));
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
        manager("recover")?;
    }
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
            let existing = profiles()?;
            if existing.iter().any(|p| p["proxy"] == proxy) {
                return Err("VPN_PROFILE_EXISTS");
            }
            if existing.len() >= 32 {
                return Err("VPN_PROFILE_LIMIT");
            }
            validate(proxy.clone())?;
            let id = String::from_utf8(
                fs::read("/proc/sys/kernel/random/uuid").map_err(|_| "VPN_WRITE_FAILED")?,
            )
            .map_err(|_| "VPN_WRITE_FAILED")?
            .trim()
            .to_string();
            audit("import", &id)?;
            write_json(
                &profile_path(&id)?,
                &json!({"id":id,"name":name,"proxy":proxy,"warnings":warnings,"source_uri":uri}),
            )?;
        }
        Request::Rename { id, name } => {
            let path = profile_path(&id)?;
            let mut p = json_file(&path)?;
            profile::rename(&mut p, &name)?;
            audit("rename", &id)?;
            write_json(&path, &p)?;
        }
        Request::Delete { id } => {
            if active() == id {
                return Err("VPN_ACTIVE_PROFILE_DELETE");
            }
            let p = profile_path(&id)?;
            let _ = json_file(&p)?;
            audit("delete", &id)?;
            fs::remove_file(p).map_err(|_| "VPN_WRITE_FAILED")?;
        }
        Request::Activate { id } => {
            let p = json_file(&profile_path(&id)?)?;
            validate(p["proxy"].clone())?;
            let first = !path("configured").exists();
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
                &profile::config(p["proxy"].clone(), false),
            )?;
            let applied =
                manager("activate").and_then(|_| if first { manager("enable") } else { Ok(()) });
            if let Err(e) = applied {
                let _ = manager("recover");
                return Err(e);
            }
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
            audit(if enabled { "enable" } else { "disable" }, &active())?;
            manager(if enabled { "enable" } else { "disable" })?;
        }
        Request::Recover => {
            manager("recover")?;
        }
        Request::Status
        | Request::Details { .. }
        | Request::ScreenOpen { .. }
        | Request::ScreenClose => unreachable!(),
    }
    status()
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
            Some("hook-network") => {
                hook_network()?;
                Ok(json!({"installed":true}))
            }
            Some("request") => {
                let mut input = Vec::new();
                std::io::stdin()
                    .take(65537)
                    .read_to_end(&mut input)
                    .map_err(|_| "VPN_INVALID_REQUEST")?;
                if input.len() > 65536 {
                    return Err("VPN_PROFILE_TOO_LARGE");
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
