use crate::adapter::{CardIo, Device, Result};
use crate::euicc::es10;
use crate::qmi::uim::{OpenChannelError, UimClient};
use serde_json::Value;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub struct RealDevice;
impl Device for RealDevice {
    type Card = UimClient;
    fn guard(&mut self) -> Result<()> {
        selection_guard()
    }
    fn connect(&mut self) -> Result<UimClient> {
        UimClient::connect().map_err(|_| "qmi_connect_error")
    }
}
impl CardIo for UimClient {
    fn open(&mut self) -> std::result::Result<u8, OpenChannelError> {
        self.open_logical_channel(&es10::ISD_R_AID)
    }
    fn close(&mut self, channel: u8) -> Result<()> {
        self.close_logical_channel(channel)
            .map_err(|_| "qmi_close_error")
    }
    fn transmit(&mut self, channel: u8, command: &[u8]) -> Result<Vec<u8>> {
        self.send_apdu(channel, command)
            .map_err(|_| "qmi_transmit_error")
    }
}

fn output(program: &str, args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| "selection_read_failed")?;
    if !out.status.success() || out.stdout.len() > 262_144 {
        return Err("selection_read_failed");
    }
    Ok(out.stdout)
}
fn cache(key: &str) -> Result<()> {
    let bytes = output("uci", &["-q", "get", key])?;
    let text = std::str::from_utf8(&bytes).map_err(|_| "selection_read_failed")?;
    if text.trim() != "1" {
        return Err("selection_mismatch");
    }
    Ok(())
}
pub fn slot_value(v: &Value, want: u64) -> bool {
    v.as_u64() == Some(want) || v.as_str() == Some(if want == 0 { "0" } else { "1" })
}
fn getter(method: &str, want: u64) -> Result<()> {
    let data = output(
        "ubus",
        &["-t", "10", "call", "zwrt_zte_mdm.api", method, "{}"],
    )?;
    let value: Value = serde_json::from_slice(&data).map_err(|_| "selection_read_failed")?;
    if !slot_value(&value["current_sim_slot"], want) {
        return Err("selection_mismatch");
    }
    Ok(())
}
pub fn selection_guard() -> Result<()> {
    const ACTIVE: &str = "zwrt_zte_mdm.sim_info.sim_active_card_id";
    const TEMP: &str = "zwrt_zte_mdm.sim_info.simcard_active_slot_temp";
    cache(ACTIVE)?;
    cache(TEMP)?;
    getter("get_sim_info", 1)?;
    getter("zte_get_current_slot_info", 0)?;
    cache(ACTIVE)?;
    cache(TEMP)?;
    Ok(())
}

/// Cross-process lock shared with MacIMEI. Existing locks are never reclaimed.
pub struct AppLock {
    path: PathBuf,
    token: Vec<u8>,
    dev: u64,
    ino: u64,
    retain: bool,
    released: bool,
}
impl AppLock {
    pub fn acquire() -> Result<Self> {
        Self::at(Path::new("/tmp/zte-imei-app.lock"))
    }
    fn at(path: &Path) -> Result<Self> {
        let mut random = [0u8; 16];
        fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut random))
            .map_err(|_| "lock_random_failed")?;
        let token = format!("euicc-{}-{}", std::process::id(), es10::hex(&random)).into_bytes();
        DirBuilder::new()
            .mode(0o700)
            .create(path)
            .map_err(|_| "lock_unavailable")?;
        let owner = path.join("owner");
        if OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&owner)
            .and_then(|mut f| f.write_all(&token))
            .is_err()
        {
            // Only the directory just created by this call is eligible here.
            let _ = fs::remove_file(&owner);
            let _ = fs::remove_dir(path);
            return Err("lock_owner_failed");
        }
        let m = fs::symlink_metadata(path).map_err(|_| "lock_metadata_failed")?;
        Ok(Self {
            path: path.to_owned(),
            token,
            dev: m.dev(),
            ino: m.ino(),
            retain: false,
            released: false,
        })
    }
    pub fn retain(&mut self) {
        self.retain = true;
    }
    pub fn release(&mut self) -> Result<()> {
        if self.released {
            return Ok(());
        }
        if self.retain {
            return Err("lock_retained");
        }
        let m = fs::symlink_metadata(&self.path).map_err(|_| "lock_release_failed")?;
        if !m.is_dir()
            || m.dev() != self.dev
            || m.ino() != self.ino
            || fs::read(self.path.join("owner")).ok().as_deref() != Some(&self.token)
        {
            return Err("lock_ownership_changed");
        }
        fs::remove_file(self.path.join("owner")).map_err(|_| "lock_release_failed")?;
        fs::remove_dir(&self.path).map_err(|_| "lock_release_failed")?;
        self.released = true;
        Ok(())
    }
}
impl Drop for AppLock {
    fn drop(&mut self) {
        if !self.retain && !std::thread::panicking() {
            let _ = self.release();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn selected_slot_numbers_are_exact() {
        assert!(slot_value(&json!(1), 1));
        assert!(slot_value(&json!("0"), 0));
        for v in [json!(true), json!(null), json!("01"), json!(2), json!(1.0)] {
            assert!(!slot_value(&v, 1));
        }
    }
    #[test]
    fn lock_refuses_existing_and_releases_only_own() {
        let p = std::env::temp_dir().join(format!("euicc-test-{}", std::process::id()));
        let mut l = AppLock::at(&p).unwrap();
        assert!(AppLock::at(&p).is_err());
        l.release().unwrap();
        assert!(!p.exists());
    }
}
