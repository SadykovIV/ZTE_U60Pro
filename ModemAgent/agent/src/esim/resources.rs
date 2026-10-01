use super::{Error, Result};
use sha2::{Digest, Sha256};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const BRIDGE_HASH: &str = "d6c2b0b6946bafe0b89d5bf1f5a64069ea33cb34fd25625292cdbd287a137508";
pub const LPAC_HASH: &str = "92aaeb96bd02e8f3e7ab9847b15e3fae31795b244fcab92f70b595719b18718d";
const BRIDGE: &[u8] = include_bytes!("../../resources/esim/bridge");
const LPAC: &[u8] = include_bytes!("../../resources/esim/lpac");
const GSMA_ROOT: &[u8] = include_bytes!("../../resources/esim/gsma-rsp-roots.pem");
const GSMA_HASH: &str = "7364a2ac4d2b5f77c1b83ee7e1c535e8fc806c67ee42e73ad97c35464d203477";
const B31: &str = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn verify() -> Result<()> {
    if hash(BRIDGE) != BRIDGE_HASH || hash(LPAC) != LPAC_HASH || hash(GSMA_ROOT) != GSMA_HASH {
        return Err(Error::new("resource_integrity_failed"));
    }
    Ok(())
}
pub fn check_device() -> Result<()> {
    if !cfg!(all(target_os = "linux", target_arch = "aarch64")) || unsafe { libc::geteuid() } != 0 {
        return Err(Error::new("unsupported_device"));
    }
    let mut f = fs::File::open("/firmware/image/modem.b16")
        .map_err(|_| Error::new("firmware_check_failed"))?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = f
            .read(&mut buffer)
            .map_err(|_| Error::new("firmware_check_failed"))?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    if format!("{:x}", digest.finalize()) != B31 {
        return Err(Error::new("unsupported_firmware"));
    }
    Ok(())
}

pub struct Resources {
    dir: PathBuf,
    identity: (u64, u64),
    pub helper: PathBuf,
    pub lpac: PathBuf,
    pub gsma_root: PathBuf,
    removed: bool,
}
impl Resources {
    pub fn extract() -> Result<Self> {
        verify()?;
        let mut random = [0u8; 16];
        fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut random))
            .map_err(|_| Error::new("temporary_resource_failed"))?;
        let token: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let dir = Path::new("/tmp").join(format!("zte-agent-esim-{token}"));
        DirBuilder::new()
            .mode(0o700)
            .create(&dir)
            .map_err(|_| Error::new("temporary_resource_failed"))?;
        let m = fs::symlink_metadata(&dir).map_err(|_| Error::new("temporary_resource_failed"))?;
        let r = Self {
            helper: dir.join("bridge"),
            lpac: dir.join("lpac"),
            gsma_root: dir.join("gsma-root.pem"),
            dir,
            identity: (m.dev(), m.ino()),
            removed: false,
        };
        for (path, bytes, wanted) in [
            (&r.helper, BRIDGE, BRIDGE_HASH),
            (&r.lpac, LPAC, LPAC_HASH),
            (&r.gsma_root, GSMA_ROOT, GSMA_HASH),
        ] {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .map_err(|_| Error::new("temporary_resource_failed"))?;
            file.write_all(bytes)
                .and_then(|_| file.sync_all())
                .map_err(|_| Error::new("temporary_resource_failed"))?;
            let content = fs::read(path).map_err(|_| Error::new("resource_integrity_failed"))?;
            if hash(&content) != wanted {
                return Err(Error::new("resource_integrity_failed"));
            }
            file.set_permissions(fs::Permissions::from_mode(0o500))
                .map_err(|_| Error::new("temporary_resource_failed"))?;
        }
        Ok(r)
    }
    pub fn cleanup(&mut self) -> Result<()> {
        if self.removed {
            return Ok(());
        }
        let m =
            fs::symlink_metadata(&self.dir).map_err(|_| Error::new("resource_cleanup_failed"))?;
        if !m.is_dir() || (m.dev(), m.ino()) != self.identity {
            return Err(Error::new("resource_ownership_changed"));
        }
        for path in [&self.helper, &self.lpac, &self.gsma_root] {
            match fs::remove_file(path) {
                Ok(()) => (),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                Err(_) => return Err(Error::new("resource_cleanup_failed")),
            }
        }
        fs::remove_dir(&self.dir).map_err(|_| Error::new("resource_cleanup_failed"))?;
        self.removed = true;
        Ok(())
    }
}
impl Drop for Resources {
    fn drop(&mut self) {
        if !self.removed {
            let _ = self.cleanup();
        }
    }
}
