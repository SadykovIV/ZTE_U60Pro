use crate::adapter::{CardIo, Device, Result};
use crate::qmi::uim::{OpenChannelError, UimClient};
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub struct RealDevice;
impl Device for RealDevice {
    type Card = UimClient;
    fn connect(&mut self) -> Result<UimClient> {
        UimClient::connect().map_err(|_| "qmi_connect_error")
    }
}
impl CardIo for UimClient {
    fn guard(&mut self) -> Result<()> {
        self.selected_physical_slot1()
            .map_err(|_| "selection_mismatch")
    }
    fn open(&mut self) -> std::result::Result<u8, OpenChannelError> {
        self.open_logical_channel()
    }
    fn ordinary_ready(&mut self) -> Result<bool> {
        self.slot1_ready().map_err(|_| "card_not_ready")
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

/// Serializes card sessions only. The kernel releases this lease on process
/// exit, including failure/crash. An unknown card outcome remains an error;
/// it never becomes a permanent lock on unrelated modem operations.
pub struct CardLock(File);
impl CardLock {
    pub fn acquire() -> Result<Self> {
        Self::at(Path::new("/tmp/zte-euicc-card.lock"), 0)
    }
    fn at(path: &Path, owner: u32) -> Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| "lock_unavailable")?;
        let m = file.metadata().map_err(|_| "lock_metadata_failed")?;
        if !m.is_file()
            || m.uid() != owner
            || m.mode() & 0o777 != 0o600
            || m.nlink() != 1
            || m.len() != 0
        {
            return Err("lock_metadata_failed");
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("lock_unavailable");
        }
        Ok(Self(file))
    }
}
impl Drop for CardLock {
    fn drop(&mut self) {
        // Do not unlink: a second inode would defeat serialization.
        let _ = unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn card_lease_releases_after_failed_scope_and_never_touches_shared_directory() {
        let dir = std::env::temp_dir().join(format!("euicc-flock-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let common = dir.join("zte-imei-app.lock");
        std::fs::create_dir(&common).unwrap();
        std::fs::write(common.join("owner"), b"old-unrelated-owner").unwrap();
        let path = dir.join("card.lock");
        let uid = unsafe { libc::geteuid() };
        let failed = (|| -> Result<()> {
            let _lock = CardLock::at(&path, uid)?;
            assert!(CardLock::at(&path, uid).is_err());
            Err("qmi_open_unknown")
        })();
        assert_eq!(failed, Err("qmi_open_unknown"));
        drop(CardLock::at(&path, uid).unwrap());
        assert!(path.is_file());
        assert_eq!(
            std::fs::read(common.join("owner")).unwrap(),
            b"old-unrelated-owner"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn card_lease_refuses_symlink_weak_mode_and_nonempty_file() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let dir = std::env::temp_dir().join(format!("euicc-flock-bad-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let p = dir.join("lock");
        let link = dir.join("link");
        std::fs::write(&p, b"").unwrap();
        symlink(&p, &link).unwrap();
        let uid = unsafe { libc::geteuid() };
        assert!(CardLock::at(&link, uid).is_err());
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(CardLock::at(&p, uid).is_err());
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&p, b"unexpected").unwrap();
        assert!(CardLock::at(&p, uid).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn child_lock_fixture() {
        let Ok(path) = std::env::var("ZTE_CARD_FLOCK_FIXTURE") else {
            return;
        };
        let _lease = CardLock::at(Path::new(&path), unsafe { libc::geteuid() }).unwrap();
        use std::io::Write;
        println!("CARD_LEASE_READY");
        std::io::stdout().flush().unwrap();
        std::thread::sleep(std::time::Duration::from_secs(30));
    }
    #[test]
    fn kernel_releases_card_lease_when_owner_process_dies() {
        use std::io::BufRead;
        use std::process::{Command, Stdio};
        let path = std::env::temp_dir().join(format!("euicc-death-{}", std::process::id()));
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "platform::tests::child_lock_fixture",
                "--nocapture",
            ])
            .env("ZTE_CARD_FLOCK_FIXTURE", &path)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut output = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        loop {
            line.clear();
            assert_ne!(output.read_line(&mut line).unwrap(), 0);
            if line.trim() == "CARD_LEASE_READY" {
                break;
            }
        }
        let uid = unsafe { libc::geteuid() };
        assert!(CardLock::at(&path, uid).is_err());
        child.kill().unwrap();
        child.wait().unwrap();
        drop(CardLock::at(&path, uid).unwrap());
        std::fs::remove_file(path).unwrap();
    }
}
