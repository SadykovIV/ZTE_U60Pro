//! Adapter to the same pinned IPv4 TTL manager used by the native application.
//! This module never creates firewall rules, modifies IPv6 or executes legacy
//! start_ttl.sh. The manager alone owns profile checks, rules and persistence.
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::Duration;

const ROOT: &str = "/data/zte-imei-ttl";
const MANAGER: &str = "/data/zte-imei-ttl/manager.sh";
const MANAGER_SHA: &str = "b6588072c82ddd7678093a29b983ec4417c6807562819e3bda69cd6534637b7c";
const DEVICE_CID: &str = "/sys/block/mmcblk0/device/cid";
const APP_LOCK: &str = "/tmp/zte-imei-app.lock";
const TIMEOUT: Duration = Duration::from_secs(90);
const OUTPUT_LIMIT: usize = 16 * 1024;
const PENDING: &[&str] = &[
    "/data/local/tmp/zte-imei-installations/active",
    "/data/local/tmp/open-u60-transactions/active",
    "/tmp/fota_install_processing",
];

type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
struct Error {
    status: u16,
    code: &'static str,
    message: &'static str,
    manager_code: Option<String>,
}
impl Error {
    fn new(status: u16, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
            manager_code: None,
        }
    }
    fn response(self) -> (u16, Value) {
        let mut body = json!({"ok": false, "error": self.message, "code": self.code});
        if let Some(code) = self.manager_code {
            body["manager_code"] = json!(code);
        }
        (self.status, body)
    }
}

fn invalid_configuration() -> Error {
    Error::new(
        400,
        "TTL_INVALID_CONFIGURATION",
        "Both TTL directions must be null or an integer from 1 to 255.",
    )
}
fn invalid_status() -> Error {
    Error::new(
        502,
        "TTL_INVALID_STATUS",
        "The TTL manager returned an invalid status. Refresh the status before retrying.",
    )
}
fn integrity() -> Error {
    Error::new(
        503,
        "TTL_MANAGER_INTEGRITY",
        "The installed TTL manager is incompatible or failed its integrity check.",
    )
}

// deserialize_with deliberately makes both nullable fields REQUIRED. An omitted
// direction must not silently disable a previously configured direction.
fn direction<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<u8>, D::Error> {
    let value = Option::<u8>::deserialize(deserializer)?;
    if value == Some(0) {
        return Err(serde::de::Error::custom("TTL must be 1-255"));
    }
    Ok(value)
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Configuration {
    schema_version: u8,
    #[serde(deserialize_with = "direction")]
    outbound: Option<u8>,
    #[serde(deserialize_with = "direction")]
    inbound_inc: Option<u8>,
}
impl Configuration {
    fn disabled() -> Self {
        Self {
            schema_version: 2,
            outbound: None,
            inbound_inc: None,
        }
    }
    fn parse(body: &[u8]) -> Result<Self> {
        if body.len() > 1024 {
            return Err(invalid_configuration());
        }
        let value: Value = serde_json::from_slice(body).map_err(|_| invalid_configuration())?;
        if value.get("schema_version").and_then(Value::as_u64) != Some(2) {
            return Err(Error::new(
                409,
                "TTL_SCHEMA_UPGRADE_REQUIRED",
                "This TTL API has changed. Reload the dashboard before changing TTL.",
            ));
        }
        // Parsing directly from bytes additionally rejects duplicate JSON keys.
        serde_json::from_slice(body).map_err(|_| invalid_configuration())
    }
    fn arguments(&self, cid: &str) -> Vec<String> {
        if self.outbound.is_none() && self.inbound_inc.is_none() {
            vec!["disable".into(), cid.into()]
        } else {
            vec![
                "apply".into(),
                cid.into(),
                arg(self.outbound),
                arg(self.inbound_inc),
            ]
        }
    }
}
fn arg(value: Option<u8>) -> String {
    value.map_or_else(|| "off".into(), |value| value.to_string())
}

#[derive(Debug, serde::Serialize, PartialEq, Eq)]
struct Status {
    schema_version: u8,
    state: String,
    outbound: Option<u8>,
    inbound_inc: Option<u8>,
    capability: String,
    verification: String,
    persistence: String,
}
impl Status {
    fn parse(bytes: &[u8]) -> Result<Self> {
        let text = std::str::from_utf8(bytes).map_err(|_| invalid_status())?;
        let text = text.strip_suffix('\n').unwrap_or(text);
        if text.contains(['\n', '\r', '\t']) || text.len() > 512 {
            return Err(invalid_status());
        }
        let mut parts = text.split(' ');
        if parts.next() != Some("TTL_STATUS") {
            return Err(invalid_status());
        }
        let mut values = HashMap::new();
        for part in parts {
            let (key, value) = part.split_once('=').ok_or_else(invalid_status)?;
            if values.insert(key, value).is_some() {
                return Err(invalid_status());
            }
        }
        let expected = [
            "state",
            "outbound",
            "inbound_inc",
            "capability",
            "verification",
            "persistence",
        ];
        if values.len() != expected.len() || expected.iter().any(|key| !values.contains_key(key)) {
            return Err(invalid_status());
        }
        let value = |key| -> Result<Option<u8>> {
            let raw = values[key];
            if raw == "off" {
                return Ok(None);
            }
            if raw.is_empty() || raw.starts_with('0') || !raw.bytes().all(|b| b.is_ascii_digit()) {
                return Err(invalid_status());
            }
            raw.parse::<u8>()
                .ok()
                .filter(|n| *n > 0)
                .map(Some)
                .ok_or_else(invalid_status)
        };
        let status = Self {
            schema_version: 2,
            state: values["state"].into(),
            outbound: value("outbound")?,
            inbound_inc: value("inbound_inc")?,
            capability: values["capability"].into(),
            verification: values["verification"].into(),
            persistence: values["persistence"].into(),
        };
        if !["configured", "disabled", "error", "unsupported"].contains(&status.state.as_str())
            || !["supported", "unsupported", "unknown"].contains(&status.capability.as_str())
            || !["unverified", "not-applicable"].contains(&status.verification.as_str())
            || !["boot", "none"].contains(&status.persistence.as_str())
        {
            return Err(invalid_status());
        }
        let disabled = status.outbound.is_none() && status.inbound_inc.is_none();
        let coherent = match status.state.as_str() {
            "configured" => {
                !disabled
                    && status.capability == "supported"
                    && status.verification == "unverified"
                    && status.persistence == "boot"
            }
            "disabled" => disabled && status.verification == "not-applicable",
            "unsupported" => {
                disabled
                    && status.capability == "unsupported"
                    && status.verification == "not-applicable"
                    && status.persistence == "none"
            }
            "error" => true, // Retain requested values so the UI can explain a partial failure.
            _ => false,
        };
        if !coherent {
            return Err(invalid_status());
        }
        Ok(status)
    }
    fn confirms(&self, requested: &Configuration) -> bool {
        self.outbound == requested.outbound
            && self.inbound_inc == requested.inbound_inc
            && if requested.outbound.is_none() && requested.inbound_inc.is_none() {
                self.state == "disabled"
            } else {
                self.state == "configured" && self.persistence == "boot"
            }
    }
}

fn safe_directory(path: &Path, uid: u32) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| integrity())?;
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o022 != 0 {
        return Err(integrity());
    }
    Ok(())
}
fn checked_file(path: &Path, uid: u32, limit: u64) -> Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| integrity())?;
    let metadata = file.metadata().map_err(|_| integrity())?;
    if !metadata.is_file() || metadata.uid() != uid || metadata.mode() & 0o022 != 0 {
        return Err(integrity());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| integrity())?;
    if bytes.len() as u64 > limit {
        return Err(integrity());
    }
    Ok(bytes)
}
fn check_manager(path: &Path, uid: u32, expected_hash: &str) -> Result<()> {
    let bytes = checked_file(path, uid, 128 * 1024)?;
    if format!("{:x}", Sha256::digest(&bytes)) != expected_hash {
        return Err(integrity());
    }
    Ok(())
}
fn valid_cid(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn cid() -> Result<String> {
    let bytes = checked_file(Path::new(DEVICE_CID), 0, 128)?;
    let device = std::str::from_utf8(&bytes).map_err(|_| integrity())?.trim();
    if !valid_cid(device) {
        return Err(integrity());
    }
    let stored = checked_file(&Path::new(ROOT).join("cid"), 0, 128)?;
    if std::str::from_utf8(&stored)
        .map_err(|_| integrity())?
        .trim()
        != device
    {
        return Err(integrity());
    }
    Ok(device.into())
}
fn pending(paths: &[&Path]) -> Result<()> {
    for path in paths {
        match fs::symlink_metadata(path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            _ => return Err(Error::new(
                409,
                "TTL_OTHER_TRANSACTION",
                "Finish the current modem update or configuration operation before changing TTL.",
            )),
        }
    }
    Ok(())
}

// The native app takes this mkdir lock before device writes. Never remove or
// reclaim an existing lock, including a stale lock from a different owner.
struct AppLock {
    path: PathBuf,
    token: String,
    inode: u64,
    device: u64,
}
impl AppLock {
    fn acquire(path: &Path, token: String) -> Result<Self> {
        let busy = || {
            Error::new(
                409,
                "TTL_BUSY",
                "Another modem operation is in progress. Try again when it finishes.",
            )
        };
        DirBuilder::new()
            .mode(0o700)
            .create(path)
            .map_err(|_| busy())?;
        let metadata = fs::symlink_metadata(path).map_err(|_| busy())?;
        let lock = Self {
            path: path.into(),
            token,
            inode: metadata.ino(),
            device: metadata.dev(),
        };
        let write = (|| -> io::Result<()> {
            let mut owner = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(path.join("owner"))?;
            owner.write_all(lock.token.as_bytes())
        })();
        if write.is_err() {
            // Remove only the directory we created if it is still empty. An
            // unknown owner entry is deliberately retained for diagnosis.
            let _ = fs::remove_dir(path);
            return Err(busy());
        }
        Ok(lock)
    }
}
impl Drop for AppLock {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path) {
            if metadata.is_dir() && metadata.ino() == self.inode && metadata.dev() == self.device {
                if let Ok(bytes) =
                    checked_file(&self.path.join("owner"), unsafe { libc::geteuid() }, 256)
                {
                    if bytes == self.token.as_bytes() {
                        let _ = fs::remove_file(self.path.join("owner"));
                        let _ = fs::remove_dir(&self.path);
                    }
                }
            }
        }
    }
}
fn lock_token() -> Result<String> {
    // A fresh kernel-generated UUID matches the native application's lock owner
    // format without storing credentials or accepting a caller-supplied token.
    let mut bytes = String::new();
    File::open("/proc/sys/kernel/random/uuid")
        .and_then(|file| file.take(128).read_to_string(&mut bytes))
        .map_err(|_| integrity())?;
    let token = bytes.trim();
    if token.len() != 36
        || !token.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
    {
        return Err(integrity());
    }
    Ok(token.into())
}

fn interpret(output: io::Result<Output>, requested: Option<&Configuration>) -> Result<Status> {
    let output = output.map_err(|error| {
        if error.kind() == io::ErrorKind::TimedOut {
            Error::new(504, "TTL_TIMEOUT", "The TTL operation timed out. Refresh its status before retrying.")
        } else {
            Error::new(502, "TTL_MANAGER_IO", "The TTL manager could not be run or exceeded its output limit. Refresh its status before retrying.")
        }
    })?;
    if !output.status.success() {
        let mut error = Error::new(
            500,
            "TTL_MANAGER_FAILED",
            "The TTL operation did not complete. Refresh its status before retrying.",
        );
        // Only a bounded machine code is exposed, never arbitrary process output.
        let manager_code = std::str::from_utf8(&output.stderr).ok().and_then(|text| {
            text.lines().find_map(|line| {
                line.strip_prefix("TTL_ERROR ").filter(|code| {
                    !code.is_empty()
                        && code.len() <= 64
                        && code.bytes().all(|b| b.is_ascii_uppercase() || b == b'_')
                })
            })
        });
        if let Some(code) = manager_code {
            match code {
                "BUSY" => {
                    error.status = 409;
                    error.code = "TTL_BUSY";
                }
                "OTHER_TRANSACTION" => {
                    error.status = 409;
                    error.code = "TTL_OTHER_TRANSACTION";
                }
                "UNSUPPORTED_PROFILE"
                | "ACCELERATION_UNVERIFIED"
                | "ACCELERATION_OR_PROFILE_UNSUPPORTED" => {
                    error.status = 503;
                    error.code = "TTL_UNSUPPORTED_PROFILE";
                }
                "CID_MISMATCH" | "LAYOUT" | "INSTALLATION_INTEGRITY" | "UNKNOWN_INSTALLATION" => {
                    error.status = 503;
                    error.code = "TTL_MANAGER_INTEGRITY";
                }
                _ => {}
            }
            error.manager_code = Some(code.into());
        }
        return Err(error);
    }
    let status = Status::parse(&output.stdout)?;
    if requested.is_some_and(|requested| !status.confirms(requested)) {
        return Err(Error::new(502, "TTL_APPLY_UNCONFIRMED", "The modem did not confirm the requested TTL settings. Refresh its status before retrying."));
    }
    Ok(status)
}

fn execute(configuration: Option<&Configuration>) -> Result<Status> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(integrity());
    }
    if matches!(fs::symlink_metadata(ROOT), Err(error) if error.kind() == io::ErrorKind::NotFound) {
        return Err(Error::new(
            503,
            "TTL_MANAGER_UNAVAILABLE",
            "Install the shared TTL manager from the native application before using this feature.",
        ));
    }
    let _lock = if configuration.is_some() {
        Some(AppLock::acquire(Path::new(APP_LOCK), lock_token()?)?)
    } else {
        None
    };
    if configuration.is_some() {
        pending(&PENDING.iter().map(Path::new).collect::<Vec<_>>())?;
    }
    safe_directory(Path::new("/data"), 0)?;
    safe_directory(Path::new(ROOT), 0)?;
    check_manager(Path::new(MANAGER), 0, MANAGER_SHA)?;
    let cid = cid()?;
    let arguments = configuration.map_or_else(
        || vec!["status".into(), cid.clone()],
        |config| config.arguments(&cid),
    );
    let mut command = Command::new("/bin/sh");
    // No -c, no interpolation and no untrusted environment affecting sh/tools.
    command
        .arg(MANAGER)
        .args(&arguments)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .current_dir("/");
    interpret(
        process_runner::output(&mut command, None, TIMEOUT, OUTPUT_LIMIT),
        configuration,
    )
}
fn response(result: Result<Status>) -> (u16, Value) {
    match result {
        Ok(status) => (200, json!({"ok": true, "data": status})),
        Err(error) => error.response(),
    }
}
pub fn status() -> (u16, Value) {
    response(execute(None))
}
pub fn set(body: &[u8]) -> (u16, Value) {
    response(Configuration::parse(body).and_then(|configuration| execute(Some(&configuration))))
}
pub fn clear() -> (u16, Value) {
    response(execute(Some(&Configuration::disabled())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::os::unix::process::ExitStatusExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
    const CONFIGURED: &str = "TTL_STATUS state=configured outbound=64 inbound_inc=1 capability=supported verification=unverified persistence=boot\n";
    const DISABLED: &str = "TTL_STATUS state=disabled outbound=off inbound_inc=off capability=supported verification=not-applicable persistence=boot\n";
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "zte-agent-ttl-test-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn output(status: i32, stdout: &str, stderr: &str) -> io::Result<Output> {
        Ok(Output {
            status: std::process::ExitStatus::from_raw(status << 8),
            stdout: stdout.as_bytes().into(),
            stderr: stderr.as_bytes().into(),
        })
    }
    #[test]
    fn schema_requires_both_nullable_integer_directions() {
        assert_eq!(
            Configuration::parse(br#"{"schema_version":2,"outbound":64,"inbound_inc":1}"#).unwrap(),
            Configuration {
                schema_version: 2,
                outbound: Some(64),
                inbound_inc: Some(1)
            }
        );
        assert_eq!(
            Configuration::parse(br#"{"schema_version":2,"outbound":null,"inbound_inc":null}"#)
                .unwrap(),
            Configuration::disabled()
        );
        for bad in [
            r#"{"schema_version":2,"outbound":64}"#,
            r#"{"schema_version":2,"inbound_inc":1}"#,
            r#"{"schema_version":2,"outbound":0,"inbound_inc":1}"#,
            r#"{"schema_version":2,"outbound":256,"inbound_inc":1}"#,
            r#"{"schema_version":2,"outbound":64.0,"inbound_inc":1}"#,
            r#"{"schema_version":2,"outbound":"64","inbound_inc":1}"#,
            r#"{"schema_version":2,"outbound":64,"inbound_inc":-1}"#,
            r#"{"schema_version":2,"outbound":64,"inbound_inc":1,"ttl":65}"#,
            r#"{"schema_version":2,"outbound":64,"outbound":63,"inbound_inc":1}"#,
            r#"{"schema_version":2,"outbound":true,"inbound_inc":1}"#,
        ] {
            assert_eq!(
                Configuration::parse(bad.as_bytes()).unwrap_err().code,
                "TTL_INVALID_CONFIGURATION",
                "{bad}"
            );
        }
    }
    #[test]
    fn stale_clients_cannot_change_semantics() {
        for body in [
            r#"{"ttl":65}"#,
            r#"{"schema_version":1,"outbound":64,"inbound_inc":1}"#,
            r#"{"schema_version":"2","outbound":64,"inbound_inc":1}"#,
        ] {
            let (status, body) = set(body.as_bytes());
            assert_eq!(status, 409);
            assert_eq!(body["code"], "TTL_SCHEMA_UPGRADE_REQUIRED");
        }
    }
    #[test]
    fn independent_directions_produce_only_fixed_arguments() {
        let config = Configuration {
            schema_version: 2,
            outbound: None,
            inbound_inc: Some(255),
        };
        assert_eq!(config.arguments("0123"), ["apply", "0123", "off", "255"]);
        let config = Configuration {
            schema_version: 2,
            outbound: Some(1),
            inbound_inc: None,
        };
        assert_eq!(config.arguments("0123"), ["apply", "0123", "1", "off"]);
        assert_eq!(
            Configuration::disabled().arguments("0123"),
            ["disable", "0123"]
        );
    }
    #[test]
    fn status_preserves_configured_but_never_claims_wire_verification() {
        let status = Status::parse(CONFIGURED.as_bytes()).unwrap();
        assert_eq!(status.outbound, Some(64));
        assert_eq!(status.inbound_inc, Some(1));
        assert_eq!(status.verification, "unverified");
        assert_eq!(Status::parse(DISABLED.as_bytes()).unwrap().outbound, None);
        assert!(Status::parse(
            CONFIGURED
                .replace("state=configured", "state=verified")
                .as_bytes()
        )
        .is_err());
        assert!(Status::parse(
            CONFIGURED
                .replace("verification=unverified", "verification=verified")
                .as_bytes()
        )
        .is_err());
    }
    #[test]
    fn malformed_ambiguous_and_incoherent_statuses_are_rejected() {
        for text in [
            format!("{CONFIGURED}{CONFIGURED}"),
            format!("{} extra=1\n", CONFIGURED.trim()),
            CONFIGURED.replace("outbound=64", "outbound=064"),
            CONFIGURED.replace("inbound_inc=1", "inbound_inc=0"),
            CONFIGURED.replace("inbound_inc=1", "inbound_inc=256"),
            CONFIGURED.replace("inbound_inc=1", "outbound=1"),
            CONFIGURED.replace("capability=supported ", ""),
            CONFIGURED.replace("state=configured", "state=disabled"),
            CONFIGURED.replace("capability=supported", "capability=unsupported"),
            CONFIGURED.replace("persistence=boot", "persistence=none"),
            CONFIGURED.replace("TTL_STATUS", "OTHER"),
            format!("\n{CONFIGURED}"),
        ] {
            assert!(Status::parse(text.as_bytes()).is_err(), "{text}");
        }
    }
    #[test]
    fn partial_failure_never_returns_successful_apply() {
        let requested = Configuration {
            schema_version: 2,
            outbound: Some(64),
            inbound_inc: Some(1),
        };
        assert!(interpret(output(0, CONFIGURED, ""), Some(&requested)).is_ok());
        assert_eq!(
            interpret(
                output(0, &CONFIGURED.replace("outbound=64", "outbound=63"), ""),
                Some(&requested)
            )
            .unwrap_err()
            .code,
            "TTL_APPLY_UNCONFIRMED"
        );
        assert_eq!(
            interpret(
                output(
                    0,
                    &CONFIGURED.replace("state=configured", "state=error"),
                    ""
                ),
                Some(&requested)
            )
            .unwrap_err()
            .code,
            "TTL_APPLY_UNCONFIRMED"
        );
        let error = interpret(
            output(
                1,
                CONFIGURED,
                "TTL_ERROR RULE_APPLY\nsecret arbitrary output\n",
            ),
            Some(&requested),
        )
        .unwrap_err();
        let (_, body) = error.response();
        assert_eq!(body["manager_code"], "RULE_APPLY");
        assert!(!body.to_string().contains("secret"));
    }
    #[test]
    fn manager_errors_and_timeouts_are_explicit() {
        for (source, code) in [
            ("BUSY", "TTL_BUSY"),
            ("OTHER_TRANSACTION", "TTL_OTHER_TRANSACTION"),
            ("CID_MISMATCH", "TTL_MANAGER_INTEGRITY"),
            ("UNSUPPORTED_PROFILE", "TTL_UNSUPPORTED_PROFILE"),
        ] {
            assert_eq!(
                interpret(output(1, "", &format!("TTL_ERROR {source}\n")), None)
                    .unwrap_err()
                    .code,
                code
            );
        }
        assert_eq!(
            interpret(Err(io::Error::from(io::ErrorKind::TimedOut)), None)
                .unwrap_err()
                .code,
            "TTL_TIMEOUT"
        );
        assert_eq!(
            interpret(output(0, "garbage", ""), None).unwrap_err().code,
            "TTL_INVALID_STATUS"
        );
    }
    #[test]
    fn real_subprocess_deadline_and_output_limit_are_bounded() {
        let result = process_runner::output(
            Command::new("/bin/sh").args(["-c", "sleep 5"]),
            None,
            Duration::from_millis(50),
            64,
        );
        assert_eq!(interpret(result, None).unwrap_err().code, "TTL_TIMEOUT");
        let result = process_runner::output(
            Command::new("/bin/sh").args(["-c", "printf '%0100d' 0"]),
            None,
            Duration::from_secs(2),
            64,
        );
        assert_eq!(interpret(result, None).unwrap_err().code, "TTL_MANAGER_IO");
    }
    #[test]
    fn trust_checks_reject_modified_writable_or_linked_manager() {
        let temp = Temp::new();
        let uid = unsafe { libc::geteuid() };
        let path = temp.0.join("manager.sh");
        fs::write(&path, b"trusted").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let hash = format!("{:x}", Sha256::digest(b"trusted"));
        assert!(safe_directory(&temp.0, uid).is_ok());
        assert!(check_manager(&path, uid, &hash).is_ok());
        assert!(check_manager(&path, uid, "incorrect").is_err());
        let link = temp.0.join("link");
        symlink(&path, &link).unwrap();
        assert!(check_manager(&link, uid, &hash).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(check_manager(&path, uid, &hash).is_err());
        fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(safe_directory(&temp.0, uid).is_err());
    }
    #[test]
    fn native_lock_is_exclusive_and_does_not_remove_foreign_owner() {
        let temp = Temp::new();
        let path = temp.0.join("lock");
        let first = AppLock::acquire(&path, "first".into()).unwrap();
        assert_eq!(
            AppLock::acquire(&path, "second".into()).err().unwrap().code,
            "TTL_BUSY"
        );
        drop(first);
        assert!(!path.exists());
        let lock = AppLock::acquire(&path, "ours".into()).unwrap();
        fs::write(path.join("owner"), "foreign").unwrap();
        drop(lock);
        assert_eq!(fs::read_to_string(path.join("owner")).unwrap(), "foreign");
    }
    #[test]
    fn pending_guards_include_dangling_symlinks() {
        let temp = Temp::new();
        let path = temp.0.join("pending");
        assert!(pending(&[&path]).is_ok());
        symlink(temp.0.join("absent"), &path).unwrap();
        assert_eq!(pending(&[&path]).unwrap_err().code, "TTL_OTHER_TRANSACTION");
    }
    #[test]
    fn cid_has_only_fixed_length_lowercase_hex() {
        assert!(valid_cid("ec010053463030383010620fa3d93d00"));
        for bad in [
            "",
            "ec010053463030383010620fa3d93d0",
            "EC010053463030383010620fa3d93d00",
            "ec010053463030383010620fa3d93d0;",
            "$(touch /tmp/injected)",
        ] {
            assert!(!valid_cid(bad));
        }
    }
}
