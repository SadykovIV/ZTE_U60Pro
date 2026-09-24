//! Navigate the added pages inside the stock launcher. Never own DRM or stop it.
use super::*;
const ROOT: &str = "/data/zte-launcher";
const STATE: &str = "/tmp/zte-launcher";
const LIBRARY_SHA: &str = include_str!("launcher.sha256");
fn owned(dir: &Path) -> bool {
    fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir() && m.uid() == 0 && m.mode() & 0o777 == 0o700)
}
fn installed() -> bool {
    let root = Path::new(ROOT);
    owned(root)
        && read(&root.join("owner"), 64).is_ok_and(|b| b == b"zte-native-launcher-v1\n")
        && read(&root.join("launcher.so"), 1024 * 1024).is_ok_and(|b| hash(&b) == LIBRARY_SHA.trim())
        && read(&root.join("cid"), 64).ok() == fs::read("/sys/block/mmcblk0/device/cid").ok()
}
fn ready_pid() -> Option<u32> {
    if !owned(Path::new(STATE)) { return None; }
    let bytes = read(&Path::new(STATE).join("ready"), 32).ok()?;
    let pid = std::str::from_utf8(&bytes).ok()?.trim().parse::<u32>().ok()?;
    if pid < 2 { return None; }
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let maps = fs::read_to_string(format!("/proc/{pid}/maps")).ok()?;
    (exe == Path::new("/usr/bin/zte_topsw_devui") && maps.lines().any(|line| line.ends_with("/data/zte-launcher/launcher.so"))).then_some(pid)
}
pub fn status() -> Value {
    let installed = installed();
    let error = read(&Path::new(ROOT).join("failed"), 128).ok().map(|b| String::from_utf8_lossy(&b).trim().to_owned()).unwrap_or_default();
    let active = installed && error.is_empty() && ready_pid().is_some();
    json!({"installed":installed,"integrated":true,"active":active,"ready":active,"page_count":4,"experimental":false,"last_error":error})
}
fn navigate(page: u8) -> Result<Value> {
    base()?;
    let _lock = Lock::new()?;
    if !installed() { return Err("VPN_LAUNCHER_NOT_INSTALLED"); }
    if Path::new(ROOT).join("failed").exists() || ready_pid().is_none() { return Err("VPN_LAUNCHER_NOT_READY"); }
    atomic(&Path::new(STATE).join("page"), &[b'0' + page])?;
    audit("screen_page", &page.to_string())?;
    Ok(json!({"schema_version":1,"screen":status(),"queued_page":page}))
}
pub fn open(page: &str) -> Result<Value> {
    match page {
        "modem" => navigate(3),
        "vpn" => navigate(4),
        _ => Err("VPN_INVALID_REQUEST"),
    }
}
pub fn close() -> Result<Value> { navigate(1) }
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unknown_page_never_touches_device() {
        assert_eq!(open("../../proc"), Err("VPN_INVALID_REQUEST"));
        assert_eq!(open("home"), Err("VPN_INVALID_REQUEST"));
    }
    #[test]
    fn absent_launcher_is_unavailable() {
        if !Path::new(ROOT).exists() {
            assert_eq!(status()["installed"], false);
            assert_eq!(status()["active"], false);
        }
    }
}
