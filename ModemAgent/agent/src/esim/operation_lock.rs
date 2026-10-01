//! One cross-process lease for the complete eSIM operation, including radio
//! recovery. The bridge retains its independent card-channel ownership lock.
use super::{Error, Result};
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub struct OperationLock(File);
impl OperationLock {
    pub fn acquire() -> Result<Self> {
        Self::at(Path::new("/tmp/zte-esim-operation.lock"), 0)
    }
    fn at(path: &Path, owner: u32) -> Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| Error::new("operation_lock_failed"))?;
        let m = file
            .metadata()
            .map_err(|_| Error::new("operation_lock_failed"))?;
        if !m.is_file()
            || m.uid() != owner
            || m.mode() & 0o777 != 0o600
            || m.nlink() != 1
            || m.len() != 0
        {
            return Err(Error::new("operation_lock_failed"));
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(Error::new("esim_busy"));
        }
        // Never unlink: unlinking a locked inode would allow a second lease
        // on a replacement file. Closing the fd releases this process's lease.
        Ok(Self(file))
    }
}
impl Drop for OperationLock {
    fn drop(&mut self) {
        let _ = unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lease_covers_other_openers_and_releases_without_unlink() {
        let path = std::env::temp_dir().join(format!("zte-esim-lock-test-{}", std::process::id()));
        let owner = unsafe { libc::geteuid() };
        let first = OperationLock::at(&path, owner).unwrap();
        assert_eq!(
            OperationLock::at(&path, owner).err().unwrap().code,
            "esim_busy"
        );
        drop(first);
        assert!(path.is_file());
        drop(OperationLock::at(&path, owner).unwrap());
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn refuses_symlinks_nonempty_and_weak_mode() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let dir = std::env::temp_dir().join(format!("zte-esim-lock-bad-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let target = dir.join("target");
        let link = dir.join("link");
        std::fs::write(&target, b"").unwrap();
        symlink(&target, &link).unwrap();
        let owner = unsafe { libc::geteuid() };
        assert!(OperationLock::at(&link, owner).is_err());
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(OperationLock::at(&target, owner).is_err());
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&target, b"unexpected").unwrap();
        assert!(OperationLock::at(&target, owner).is_err());
        std::fs::remove_file(link).unwrap();
        std::fs::remove_file(target).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
