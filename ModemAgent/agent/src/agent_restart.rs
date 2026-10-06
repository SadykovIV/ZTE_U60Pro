//! Restart only this executable, using a verified generated startup's settings.
//! Startup bytes (including the password) remain in memory and are never logged.
use sha2::{Digest, Sha256};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

static RESTARTING: AtomicBool = AtomicBool::new(false);
const MAX_STARTUP: u64 = 16 * 1024;
const MAX_BINARY: u64 = 64 * 1024 * 1024;
const LAUNCH: &str = "nohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &";

#[derive(PartialEq, Eq)]
struct Settings {
    password: String,
    discovery: bool,
    bind: Option<String>,
}

// This is the same single-quoted form emitted by Onboarding.agentStartup.
// Parse it as data; never evaluate a startup file or interpolate a secret in argv.
fn quoted(value: &str) -> Result<String, ()> {
    let bytes = value.as_bytes();
    if bytes.len() < 3 || bytes.first() != Some(&b'\'') || bytes.last() != Some(&b'\'') {
        return Err(());
    }
    let mut result = Vec::new();
    let mut at = 1;
    while at < bytes.len() - 1 {
        if bytes[at] == b'\'' {
            if bytes.get(at..at + 4) != Some(b"'\\''") || at + 4 >= bytes.len() {
                return Err(());
            }
            result.push(b'\'');
            at += 4;
        } else {
            if bytes[at] < 32 || bytes[at] == 127 { return Err(()); }
            result.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8(result).map_err(|_| ())
}

fn settings(bytes: &[u8]) -> Result<Settings, ()> {
    let text = std::str::from_utf8(bytes).map_err(|_| ())?;
    if text.contains('\0') || text.contains('\r') { return Err(()); }
    let lines: Vec<_> = text.lines()
        .filter(|line| !line.trim_matches([' ', '\t']).is_empty() && !line.starts_with('#'))
        .collect();
    if lines.len() != 4 && lines.len() != 6 { return Err(()); }
    let password = quoted(lines[0].strip_prefix("export ZTE_AGENT_PASSWORD=").ok_or(())?)?;
    let discovery = lines.len() == 6;
    let mut bind = None;
    if discovery {
        if lines[1] != "export ZTE_AGENT_MODE='discovery'" { return Err(()); }
        let address = quoted(lines[2].strip_prefix("export ZTE_AGENT_BIND=").ok_or(())?)?;
        let ip = address.strip_suffix(":9090").ok_or(())?;
        let parsed: std::net::Ipv4Addr = ip.parse().map_err(|_| ())?;
        if parsed.to_string() != ip { return Err(()); }
        bind = Some(address);
    }
    let rest = &lines[if discovery { 3 } else { 1 }..];
    if rest != ["unset ZTE_AGENT_PIN", "trap '' HUP", LAUNCH] { return Err(()); }
    Ok(Settings { password, discovery, bind })
}

struct Paths {
    data: PathBuf,
    anchor: PathBuf,
    legacy_local: PathBuf,
    legacy_tmp: PathBuf,
    binary: PathBuf,
    mapped: PathBuf,
    pending: Vec<PathBuf>,
}
impl Paths {
    fn system() -> Self {
        Self {
            data: "/data".into(), anchor: "/data/zte-imei-studio".into(),
            legacy_local: "/data/local".into(), legacy_tmp: "/data/local/tmp".into(),
            binary: "/data/zte-agent".into(), mapped: "/proc/self/exe".into(),
            pending: ["/tmp/zte-imei-app.lock", "/data/zte-agent-installer/pending",
                "/data/zte-imei-studio/installations/active", "/data/local/tmp/zte-imei-installations/active",
                "/data/local/tmp/open-u60-transactions/active", "/data/zte-vpn/controller-upgrade"]
                .into_iter().map(PathBuf::from).collect(),
        }
    }
}

#[derive(PartialEq, Eq)]
struct Stamp { dev: u64, ino: u64, uid: u32, mode: u32, links: u64, size: u64, modified: (i64, i64), changed: (i64, i64) }
fn stamp(m: &Metadata) -> Stamp {
    Stamp { dev: m.dev(), ino: m.ino(), uid: m.uid(), mode: m.mode(), links: m.nlink(), size: m.len(),
        modified: (m.mtime(), m.mtime_nsec()), changed: (m.ctime(), m.ctime_nsec()) }
}
fn directory(path: &Path, uid: u32, private: bool, allow_shared: bool) -> Result<(), ()> {
    let m = fs::symlink_metadata(path).map_err(|_| ())?;
    if !m.is_dir() || m.uid() != uid || private && m.mode() & 0o7777 != 0o700
        || !allow_shared && m.mode() & 0o022 != 0 { return Err(()); }
    Ok(())
}
fn absent(path: &Path) -> Result<bool, ()> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(false),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(_) => Err(()),
    }
}
fn read_regular(path: &Path, uid: u32, startup: bool) -> Result<(Vec<u8>, Stamp), ()> {
    let before = fs::symlink_metadata(path).map_err(|_| ())?;
    let mode = before.mode() & 0o7777;
    if !before.is_file() || before.uid() != uid || before.nlink() != 1
        || if startup { !matches!(mode, 0o600 | 0o700) } else { mode & 0o022 != 0 || mode & 0o111 == 0 }
    { return Err(()); }
    let max = if startup { MAX_STARTUP } else { MAX_BINARY };
    if before.len() == 0 || before.len() > max { return Err(()); }
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path).map_err(|_| ())?;
    if stamp(&file.metadata().map_err(|_| ())?) != stamp(&before) { return Err(()); }
    let mut bytes = Vec::new();
    (&mut file).take(max + 1).read_to_end(&mut bytes).map_err(|_| ())?;
    if bytes.len() as u64 != before.len() || stamp(&file.metadata().map_err(|_| ())?) != stamp(&before)
        || stamp(&fs::symlink_metadata(path).map_err(|_| ())?) != stamp(&before) { return Err(()); }
    Ok((bytes, stamp(&before)))
}

#[derive(PartialEq, Eq)]
struct Proof { startup: PathBuf, startup_stamp: Stamp, startup_hash: [u8; 32], binary_stamp: Stamp, binary_hash: [u8; 32], settings: Settings }
fn proof(paths: &Paths, uid: u32, discovery: bool) -> Result<Proof, ()> {
    directory(&paths.data, uid, false, false)?;
    for path in &paths.pending { if !absent(path)? { return Err(()); } }
    let current = paths.anchor.join("start_zte_agent.sh");
    let startup = if !absent(&current)? {
        directory(&paths.anchor, uid, true, false)?;
        current
    } else {
        // Existing unsafe current metadata must not silently select legacy.
        if !absent(&paths.anchor)? { directory(&paths.anchor, uid, true, false)?; }
        directory(&paths.legacy_local, uid, false, true)?;
        directory(&paths.legacy_tmp, uid, false, true)?;
        paths.legacy_tmp.join("start_zte_agent.sh")
    };
    let (body, startup_stamp) = read_regular(&startup, uid, true)?;
    let settings = settings(&body)?;
    if settings.discovery != discovery { return Err(()); }
    if fs::read_link(&paths.mapped).map_err(|_| ())? != paths.binary { return Err(()); }
    let (binary, binary_stamp) = read_regular(&paths.binary, uid, false)?;
    let binary_hash: [u8; 32] = Sha256::digest(&binary).into();
    let mut mapped = File::open(&paths.mapped).map_err(|_| ())?;
    if stamp(&mapped.metadata().map_err(|_| ())?) != binary_stamp { return Err(()); }
    let mut mapped_bytes = Vec::new();
    (&mut mapped).take(MAX_BINARY + 1).read_to_end(&mut mapped_bytes).map_err(|_| ())?;
    if <[u8; 32]>::from(Sha256::digest(&mapped_bytes)) != binary_hash
        || stamp(&mapped.metadata().map_err(|_| ())?) != binary_stamp { return Err(()); }
    Ok(Proof { startup, startup_stamp, startup_hash: Sha256::digest(&body).into(), binary_stamp, binary_hash, settings })
}

fn restart_command(executable: &Path, settings: &Settings) -> Command {
    let mut command = Command::new(executable);
    command.env("ZTE_AGENT_PASSWORD", &settings.password).env_remove("ZTE_AGENT_PIN")
        .env("ZTE_AGENT_MODE", if settings.discovery { "discovery" } else { "normal" });
    if let Some(bind) = &settings.bind { command.env("ZTE_AGENT_BIND", bind); }
    command
}

pub(super) fn schedule(discovery: bool) -> Result<(), &'static str> {
    if !cfg!(target_os = "linux") || unsafe { libc::geteuid() } != 0 { return Err("AGENT_RESTART_PLATFORM"); }
    if RESTARTING.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() { return Err("AGENT_RESTART_BUSY"); }
    let paths = Paths::system();
    let original = match proof(&paths, 0, discovery) {
        Ok(value) => value,
        Err(_) => { RESTARTING.store(false, Ordering::Release); return Err("AGENT_RESTART_UNSAFE"); }
    };
    let spawned = std::thread::Builder::new().name("agent-restart".into()).spawn(move || {
        // Keep the HTTP response-before-restart contract. Recheck everything
        // after the delay; changed/pending state leaves this process running.
        std::thread::sleep(std::time::Duration::from_secs(1));
        if proof(&paths, 0, discovery).is_ok_and(|current| current == original) {
            let mut command = restart_command(Path::new("/proc/self/exe"), &original.settings);
            // Replace our own image/PID, preserving stdout/logger and inherited
            // descriptors. No name-based kill, PID-reuse race or shell eval.
            let _ = command.exec();
        }
        eprintln!("[WARN] AGENT_RESTART_NOT_COMPLETED");
        RESTARTING.store(false, Ordering::Release);
    });
    if spawned.is_err() { RESTARTING.store(false, Ordering::Release); return Err("AGENT_RESTART_UNAVAILABLE"); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    struct Fixture { root: PathBuf, paths: Paths, uid: u32 }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("zte-restart-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            fs::create_dir(&root).unwrap();
            let data = root.join("data"); let anchor = data.join("zte-imei-studio");
            let legacy_local = data.join("local"); let legacy_tmp = legacy_local.join("tmp");
            fs::create_dir_all(&anchor).unwrap(); fs::create_dir_all(&legacy_tmp).unwrap();
            for p in [&data, &anchor, &legacy_local, &legacy_tmp] { fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap(); }
            let binary = data.join("zte-agent"); fs::write(&binary, b"synthetic executable bytes, never executed").unwrap();
            fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
            let mapped = root.join("mapped-exe"); symlink(&binary, &mapped).unwrap();
            let pending = vec![root.join("pending")];
            let this = Self { root, paths: Paths { data, anchor, legacy_local, legacy_tmp, binary, mapped, pending }, uid: unsafe { libc::geteuid() } };
            this.startup(false, normal()); this
        }
        fn startup(&self, legacy: bool, body: String) {
            let p = if legacy { &self.paths.legacy_tmp } else { &self.paths.anchor }.join("start_zte_agent.sh");
            fs::write(&p, body).unwrap(); fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
        }
        fn current(&self) -> PathBuf { self.paths.anchor.join("start_zte_agent.sh") }
        fn valid(&self) -> Result<Proof, ()> { proof(&self.paths, self.uid, false) }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); } }
    fn normal() -> String { format!("#!/bin/sh\nexport ZTE_AGENT_PASSWORD='synthetic$literal'\nunset ZTE_AGENT_PIN\ntrap '' HUP\n{LAUNCH}\n") }

    #[test]
    fn accepts_generated_normal_and_discovery_without_evaluating_secret() {
        let a = settings(normal().as_bytes()).unwrap();
        assert_eq!(a.password, "synthetic$literal"); assert!(!a.discovery);
        let body = normal().replace("unset ZTE_AGENT_PIN", "export ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND='192.168.0.1:9090'\nunset ZTE_AGENT_PIN");
        let a = settings(body.as_bytes()).unwrap(); assert!(a.discovery); assert_eq!(a.bind.as_deref(), Some("192.168.0.1:9090"));
        assert_eq!(quoted("'literal'\\''quote$(ignored)'"), Ok("literal'quote$(ignored)".into()));
        assert_eq!(quoted("'a'\\'''"), Ok("a'".into()));
    }
    #[test]
    fn restart_environment_uses_literal_settings_and_keeps_other_environment() {
        let settings = Settings { password: "synthetic'$(never-execute)".into(), discovery: true,
            bind: Some("192.168.0.1:9090".into()) };
        let mut command = restart_command(Path::new("/bin/sh"), &settings);
        assert_eq!(command.get_program(), "/bin/sh");
        assert_eq!(command.get_args().count(), 0);
        let env: std::collections::HashMap<_, _> = command.get_envs().collect();
        assert_eq!(env.get(std::ffi::OsStr::new("ZTE_AGENT_PIN")), Some(&None));
        assert!(!env.contains_key(std::ffi::OsStr::new("PATH")));
        // Execute only the host shell, never an agent or startup. Its stdout
        // and inherited environment remain available; secret text is data.
        let output = command.args(["-c", "test -n \"$PATH\" && test \"$ZTE_AGENT_MODE\" = discovery && test \"$ZTE_AGENT_BIND\" = 192.168.0.1:9090 && test -z \"${ZTE_AGENT_PIN+x}\" && printf '%s' \"$ZTE_AGENT_PASSWORD\""]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, settings.password.as_bytes());
        assert!(output.stderr.is_empty());
        let normal = super::settings(normal().as_bytes()).unwrap();
        let command = restart_command(Path::new("/bin/sh"), &normal);
        assert!(!command.get_envs().any(|(key,_)| key == "ZTE_AGENT_BIND"));
    }
    #[test]
    fn refuses_malformed_ambiguous_or_executable_startup_additions() {
        for text in [
            normal().replace("'synthetic$literal'", "\"synthetic\""),
            normal().replace("'synthetic$literal'", "'abc'; touch /tmp/never"),
            normal().replace("'synthetic$literal'", "'abc' 'def'"),
            normal().replace("'synthetic$literal'", "''"),
            normal().replace("unset ZTE_AGENT_PIN", "export ZTE_AGENT_PASSWORD='second'"),
            normal().replace("trap '' HUP", "eval 'anything'"),
            normal().replace(LAUNCH, "nohup /data/other-agent &"),
            format!("{}\necho appended\n", normal()),
            normal().replace('\n', "\r\n"),
            normal().replace("unset", "\0unset"),
            normal().replace("unset", "\u{a0}unset"),
        ] { assert!(settings(text.as_bytes()).is_err()); }
    }
    #[test]
    fn refuses_discovery_mode_bind_variants_and_duplicates() {
        let body = normal().replace("unset ZTE_AGENT_PIN", "export ZTE_AGENT_MODE='discovery'\nexport ZTE_AGENT_BIND='192.168.0.1:9090'\nunset ZTE_AGENT_PIN");
        for bad in [body.replace("discovery", "normal"), body.replace(":9090", ":8080"), body.replace("192.168.0.1", "192.168.000.1"), body.replace("192.168.0.1", "256.1.2.3"), format!("{body}export ZTE_AGENT_MODE='discovery'\n")] { assert!(settings(bad.as_bytes()).is_err()); }
    }
    #[test]
    fn current_anchor_is_selected_and_legacy_is_only_absence_fallback() {
        let f = Fixture::new(); f.startup(true, normal().replace("synthetic$literal", "legacy-literal"));
        assert!(f.valid().unwrap().startup == f.current());
        fs::remove_file(f.current()).unwrap();
        for p in [&f.paths.legacy_local, &f.paths.legacy_tmp] { fs::set_permissions(p, fs::Permissions::from_mode(0o777)).unwrap(); }
        assert!(f.valid().unwrap().startup == f.paths.legacy_tmp.join("start_zte_agent.sh"));
        f.startup(false, "broken current".into()); assert!(f.valid().is_err());
    }
    #[test]
    fn unsafe_current_does_not_fall_back_to_valid_legacy() {
        let f = Fixture::new(); f.startup(true, normal());
        fs::set_permissions(f.current(), fs::Permissions::from_mode(0o777)).unwrap(); assert!(f.valid().is_err());
        fs::remove_file(f.current()).unwrap(); symlink(f.paths.legacy_tmp.join("start_zte_agent.sh"), f.current()).unwrap(); assert!(f.valid().is_err());
        fs::remove_file(f.current()).unwrap(); symlink(f.root.join("missing"), f.current()).unwrap(); assert!(f.valid().is_err());
    }
    #[test]
    fn private_anchor_and_root_owner_are_required() {
        let f = Fixture::new(); assert!(proof(&f.paths, f.uid.wrapping_add(1), false).is_err());
        fs::set_permissions(&f.paths.anchor, fs::Permissions::from_mode(0o755)).unwrap(); assert!(f.valid().is_err());
        fs::set_permissions(&f.paths.anchor, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&f.paths.data, fs::Permissions::from_mode(0o777)).unwrap(); assert!(f.valid().is_err());
    }
    #[test]
    fn startup_hardlinks_oversize_and_foreign_binary_are_refused() {
        let f = Fixture::new(); let link = f.root.join("extra"); fs::hard_link(f.current(), &link).unwrap(); assert!(f.valid().is_err());
        fs::remove_file(link).unwrap(); f.startup(false, "#".repeat(MAX_STARTUP as usize + 1)); assert!(f.valid().is_err());
        f.startup(false, normal()); fs::set_permissions(&f.paths.binary, fs::Permissions::from_mode(0o777)).unwrap(); assert!(f.valid().is_err());
    }
    #[test]
    fn mapped_image_must_be_the_installed_executable_not_same_named_or_deleted() {
        let f = Fixture::new(); fs::remove_file(&f.paths.mapped).unwrap();
        let other = f.root.join("other-image"); fs::copy(&f.paths.binary, &other).unwrap(); symlink(other, &f.paths.mapped).unwrap(); assert!(f.valid().is_err());
        fs::remove_file(&f.paths.mapped).unwrap(); symlink(format!("{} (deleted)", f.paths.binary.display()), &f.paths.mapped).unwrap(); assert!(f.valid().is_err());
    }
    #[test]
    fn changed_startup_or_binary_invalidates_delayed_proof() {
        let f = Fixture::new(); let before = f.valid().unwrap();
        f.startup(false, normal().replace("synthetic$literal", "new-literal")); assert!(f.valid().is_ok_and(|v| v != before));
        f.startup(false, normal()); let before = f.valid().unwrap(); fs::write(&f.paths.binary, b"different synthetic bytes").unwrap();
        assert!(f.valid().is_ok_and(|v| v != before));
    }
    #[test]
    fn pending_or_dangling_intents_and_mode_change_refuse_restart() {
        let f = Fixture::new(); fs::write(&f.paths.pending[0], b"pending").unwrap(); assert!(f.valid().is_err());
        fs::remove_file(&f.paths.pending[0]).unwrap(); symlink(f.root.join("missing"), &f.paths.pending[0]).unwrap(); assert!(f.valid().is_err());
        fs::remove_file(&f.paths.pending[0]).unwrap(); assert!(proof(&f.paths, f.uid, true).is_err());
    }
}
