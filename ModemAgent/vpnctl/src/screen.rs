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
const PAGE_HEADER: &[u8] = b"ZTE_LAUNCHER_PAGES_V1\n";
fn parse_pages(bytes: &[u8]) -> Result<Vec<&'static str>> {
    if bytes.len()>128 || !bytes.starts_with(PAGE_HEADER) { return Err("VPN_LAUNCHER_PAGE_CONFIG_INVALID"); }
    let mut pages=Vec::new();
    let rest=&bytes[PAGE_HEADER.len()..];
    if !rest.is_empty() && !rest.ends_with(b"\n") { return Err("VPN_LAUNCHER_PAGE_CONFIG_INVALID"); }
    for line in rest.split_inclusive(|b| *b==b'\n') {
        let id=match line { b"info\n"=>"info", b"vpn\n"=>"vpn", b"esim\n"=>"esim", _=>return Err("VPN_LAUNCHER_PAGE_CONFIG_INVALID") };
        if pages.contains(&id) { return Err("VPN_LAUNCHER_PAGE_CONFIG_INVALID"); }
        pages.push(id);
    }
    Ok(pages)
}
fn configured_pages() -> Result<Vec<&'static str>> {
    let data=fs::symlink_metadata("/data").map_err(|_| "VPN_LAUNCHER_PAGE_CONFIG_INVALID")?;
    if !data.is_dir() || data.uid()!=0 || data.mode()&0o22!=0 || !owned(Path::new(ROOT)) { return Err("VPN_LAUNCHER_PAGE_CONFIG_INVALID"); }
    let path=Path::new(ROOT).join("page-layout.conf");
    match fs::symlink_metadata(&path) {
        Err(e) if e.kind()==std::io::ErrorKind::NotFound => Ok(vec!["info","vpn","esim"]),
        Ok(m) if m.is_file() && m.uid()==0 && m.mode()&0o7777==0o600 && m.nlink()==1 => parse_pages(&read(&path,128)?),
        _=>Err("VPN_LAUNCHER_PAGE_CONFIG_INVALID"),
    }
}
fn page_number(pages: &[&str], name: &str) -> Result<u8> {
    pages.iter().position(|p| *p==name).map(|i| (i+3) as u8).ok_or("VPN_LAUNCHER_PAGE_NOT_INSTALLED")
}
pub fn status() -> Value {
    let installed = installed();
    let error = read(&Path::new(ROOT).join("failed"), 128).ok().map(|b| String::from_utf8_lossy(&b).trim().to_owned()).unwrap_or_default();
    let pages=configured_pages();
    let config_error=pages.is_err() && installed;
    let pages=pages.unwrap_or_default();
    let active = installed && error.is_empty() && ready_pid().is_some();
    json!({"installed":installed,"integrated":true,"active":active,"ready":active,"page_count":2+pages.len(),"pages":pages,"page_config_valid":!config_error,"experimental":false,"last_error":error})
}
fn navigate(name: &str) -> Result<Value> {
    base()?;
    let _lock = Lock::new()?;
    if !installed() { return Err("VPN_LAUNCHER_NOT_INSTALLED"); }
    if Path::new(ROOT).join("failed").exists() || ready_pid().is_none() { return Err("VPN_LAUNCHER_NOT_READY"); }
    let page=if name=="home" { 1 } else { page_number(&configured_pages()?,name)? };
    atomic(&Path::new(STATE).join("page"), name.as_bytes())?;
    audit("screen_page", &page.to_string())?;
    Ok(json!({"schema_version":1,"screen":status(),"queued_page":page}))
}
pub fn open(page: &str) -> Result<Value> {
    let name=match page { "modem"=>"info", "vpn"=>"vpn", "esim"=>"esim", _=>return Err("VPN_INVALID_REQUEST") };
    navigate(name)
}
pub fn close() -> Result<Value> { navigate("home") }
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordered_page_subsets_and_unsafe_config() {
        for data in ["", "info\n", "esim\nvpn\n", "vpn\ninfo\nesim\n"] {
            let document=format!("ZTE_LAUNCHER_PAGES_V1\n{data}");
            let pages=parse_pages(document.as_bytes()).unwrap();
            for (i,p) in pages.iter().enumerate() { assert_eq!(page_number(&pages,p),Ok((i+3) as u8)); }
            for p in ["info","vpn","esim"] { if !pages.contains(&p) { assert_eq!(page_number(&pages,p),Err("VPN_LAUNCHER_PAGE_NOT_INSTALLED")); } }
        }
        for bytes in [b"".as_slice(),b"ZTE_LAUNCHER_PAGES_V1\ninfo",b"ZTE_LAUNCHER_PAGES_V1\ninfo\ninfo\n",b"ZTE_LAUNCHER_PAGES_V1\nesim\r\n",b"ZTE_LAUNCHER_PAGES_V1\n\n"] { assert!(parse_pages(bytes).is_err()); }
    }
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
