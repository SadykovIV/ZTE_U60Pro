use super::{Error, Result};
use sha2::{Digest, Sha256};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const BRIDGE_HASH: &str = "67d5f32928c5279db50d390ce51322e2602bb68a158ed1fbf0cfe3f831e6e12e";
pub const LPAC_HASH: &str = "92aaeb96bd02e8f3e7ab9847b15e3fae31795b244fcab92f70b595719b18718d";
const BRIDGE: &[u8] = include_bytes!("../../resources/esim/bridge");
const LPAC: &[u8] = include_bytes!("../../resources/esim/lpac");
const GSMA_ROOT: &[u8] = include_bytes!("../../resources/esim/gsma-rsp-roots.pem");
const GSMA_HASH: &str = "7364a2ac4d2b5f77c1b83ee7e1c535e8fc806c67ee42e73ad97c35464d203477";
const B31: &str = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
const B28_IMAGE: &str = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478";
const B28_MDM: &str = "5d140d3b31078607ecfc3333188289f12a9cdf285390448c5ae748bdf53f2995";
const B04_IMAGE: &str = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
const B04_MDM: &str = "93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64";
const B04_ROUTER: &str = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f";

fn radio_profile_matches(image: &str, mdm: Option<&str>, router: Option<&str>) -> bool {
    image == B31 || (router == Some(B04_ROUTER)
        && ((image == B04_IMAGE && mdm == Some(B04_MDM))
            || (image == B28_IMAGE && mdm == Some(B28_MDM))))
}


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
    Ok(())
}
/// Radio reset uses measured B31/B28/B04 component profiles. Each operation
/// requires a fresh operating-mode and physical-slot read before changing the
/// profile, then setter acknowledgements and readbacks. B28's live QMI route
/// remains an owner-validation item. This does not enable a built-in-card route.
/// APDU inventory and card operations use actual card/route checks.
pub fn check_radio_device() -> Result<()> {
    check_device()?;
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
    let image = format!("{:x}", digest.finalize());
    if image == B31 { return Ok(()); }
    if image != B04_IMAGE && image != B28_IMAGE { return Err(Error::new("unsupported_firmware")); }
    let mdm = fs::read("/usr/bin/zte_topsw_mdm").map_err(|_| Error::new("firmware_check_failed"))?;
    let router = fs::read("/usr/bin/diag-router").map_err(|_| Error::new("firmware_check_failed"))?;
    if !radio_profile_matches(&image, Some(&hash(&mdm)), Some(&hash(&router))) {
        return Err(Error::new("unsupported_firmware"));
    }
    Ok(())
}

#[cfg(test)]
mod radio_profile_tests {
    use super::*;
    #[test]
    fn b31_is_unchanged_and_b28_b04_require_their_captured_components() {
        assert!(radio_profile_matches(B31, None, None));
        assert!(radio_profile_matches(B04_IMAGE, Some(B04_MDM), Some(B04_ROUTER)));
        assert!(radio_profile_matches(B28_IMAGE, Some(B28_MDM), Some(B04_ROUTER)));
        assert!(!radio_profile_matches(B28_IMAGE, Some(B04_MDM), Some(B04_ROUTER)));
        assert!(!radio_profile_matches(B04_IMAGE, Some(B28_MDM), Some(B04_ROUTER)));
        assert!(!radio_profile_matches(B28_IMAGE, None, Some(B04_ROUTER)));
        assert!(!radio_profile_matches(B28_IMAGE, Some(B28_MDM), None));
        for image in ["absent", "BD_XCBZHKMU5250V1.0.0B04", "", "unknown"] {
            assert!(!radio_profile_matches(image, Some(B04_MDM), Some(B04_ROUTER)));
        }
        assert!(!radio_profile_matches(B04_IMAGE, None, Some(B04_ROUTER)));
        assert!(!radio_profile_matches(B04_IMAGE, Some("unknown"), Some(B04_ROUTER)));
        assert!(!radio_profile_matches(B04_IMAGE, Some(B04_MDM), None));
        assert!(!radio_profile_matches(B04_IMAGE, Some(B04_MDM), Some("unknown")));
    }
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
        Self::extract_for(false)
    }
    /// Listing needs only the card helper; operator TLS and lpac are unrelated.
    pub fn extract_for(read_only: bool) -> Result<Self> {
        if read_only {
            if hash(BRIDGE) != BRIDGE_HASH {
                return Err(Error::new("resource_integrity_failed"));
            }
        } else {
            verify()?;
        }
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
            if read_only && path != &r.helper {
                continue;
            }
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
