use super::{Error, Result};
use sha2::{Digest, Sha256};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const BRIDGE_HASH: &str = "420049450020763a2c969710b50e2b3b9f792ef190d60f680912af62f9df1530";
pub const LPAC_HASH: &str = "32e7ff567cc38ff3522a02f71c0b9d4df2d5c745dbe664ee94655d737fdef478";
const BRIDGE: &[u8] = include_bytes!("../../resources/esim/bridge");
const LPAC: &[u8] = include_bytes!("../../resources/esim/lpac");
const GSMA_ROOT: &[u8] = include_bytes!("../../resources/esim/gsma-rsp-roots.pem");
const GSMA_HASH: &str = "7364a2ac4d2b5f77c1b83ee7e1c535e8fc806c67ee42e73ad97c35464d203477";
const B31: &str = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
const B28_IMAGE: &str = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478";
const B28_MDM: &str = "5d140d3b31078607ecfc3333188289f12a9cdf285390448c5ae748bdf53f2995";
const B27_IMAGE: &str = "4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e";
const B27_MDM: &str = "00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d";
const B27_ROUTER: &str = "786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f";
const B04_IMAGE: &str = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
const B04_MDM: &str = "93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64";
const B04_ROUTER: &str = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f";

fn radio_profile_matches(image: Option<&str>, mdm: Option<&str>, router: Option<&str>, b04_versions: bool) -> bool {
    image == Some(B31)
        || (image == Some(B27_IMAGE) && mdm == Some(B27_MDM) && router == Some(B27_ROUTER))
        || (router == Some(B04_ROUTER)
        && ((image == Some(B04_IMAGE) && mdm == Some(B04_MDM))
            || (image.is_none() && mdm == Some(B04_MDM) && b04_versions)
            || (image == Some(B28_IMAGE) && mdm == Some(B28_MDM))))
}

fn b04_versions_match() -> Result<bool> {
    // Shared ubus runner bounds time/output; no identifiers or raw errors escape.
    let versions = crate::system::read_firmware_info()
        .map_err(|_| Error::new("firmware_check_failed"))?;
    Ok(versions.integrate_version.as_deref() == Some("XCBZ_HK_MU5250V1.0.0B04")
        && versions.wa_inner_version.as_deref() == Some("BD_XCBZHKMU5250V1.0.0B04"))
}

fn measured_component(path: &Path, allow_absent: bool) -> Result<Option<String>> {
    let failure = || Error::new("firmware_check_failed");
    let before = match fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(e) if allow_absent && e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(failure()),
    };
    if !before.is_file() || before.len() > 256 * 1024 * 1024 { return Err(failure()); }
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path).map_err(|_| failure())?;
    let key = |m: &fs::Metadata| (m.dev(), m.ino(), m.len(), m.mtime(), m.mtime_nsec(), m.ctime(), m.ctime_nsec());
    if key(&file.metadata().map_err(|_| failure())?) != key(&before) { return Err(failure()); }
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut read = 0u64;
    loop {
        let count = file.read(&mut buffer).map_err(|_| failure())?;
        if count == 0 { break; }
        read += count as u64;
        if read > before.len() { return Err(failure()); }
        digest.update(&buffer[..count]);
    }
    if read != before.len() || key(&file.metadata().map_err(|_| failure())?) != key(&before)
        || key(&fs::symlink_metadata(path).map_err(|_| failure())?) != key(&before) { return Err(failure()); }
    Ok(Some(format!("{:x}", digest.finalize())))
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
/// Radio reset uses measured B31/B27/B28/B04 component profiles. Each operation
/// requires a fresh operating-mode and physical-slot read before changing the
/// profile, then setter acknowledgements and readbacks. The B27 capture confirms
/// DMS mode/UIM slot-status reads; radio writes still require device validation.
/// This does not enable a built-in-card route or a private diag-router ABI.
/// APDU inventory and card operations use actual card/route checks.
pub fn check_radio_device() -> Result<()> {
    check_device()?;
    let image_path = Path::new("/firmware/image/modem.b16");
    let image = measured_component(image_path, true)?;
    if image.as_deref() == Some(B31) { return Ok(()); }
    if image.as_deref().is_some_and(|value| ![B04_IMAGE, B27_IMAGE, B28_IMAGE].contains(&value)) {
        return Err(Error::new("unsupported_firmware"));
    }
    let mdm = measured_component(Path::new("/usr/bin/zte_topsw_mdm"), false)?;
    let router = measured_component(Path::new("/usr/bin/diag-router"), false)?;
    let versions_match = image.is_none() && b04_versions_match()?;
    if !radio_profile_matches(image.as_deref(), mdm.as_deref(), router.as_deref(), versions_match) {
        return Err(Error::new("unsupported_firmware"));
    }
    if image.is_none() && measured_component(image_path, true)?.is_some() {
        return Err(Error::new("firmware_check_failed"));
    }
    Ok(())
}

#[cfg(test)]
mod radio_profile_tests {
    use super::*;
    #[test]
    fn b27_requires_the_complete_captured_triplet_without_name_fallback() {
        assert!(radio_profile_matches(Some(B27_IMAGE), Some(B27_MDM), Some(B27_ROUTER), false));
        // Never apply another build's radio transition policy to a mixed image.
        for image in [None, Some(B04_IMAGE), Some(B28_IMAGE), Some("BD_FLYMODEMMU5250V1.0.0B27")] {
            assert!(!radio_profile_matches(image, Some(B27_MDM), Some(B27_ROUTER), true));
        }
        for mdm in [None, Some(B04_MDM), Some(B28_MDM), Some("unknown")] {
            assert!(!radio_profile_matches(Some(B27_IMAGE), mdm, Some(B27_ROUTER), true));
        }
        for router in [None, Some(B04_ROUTER), Some("unknown")] {
            assert!(!radio_profile_matches(Some(B27_IMAGE), Some(B27_MDM), router, true));
        }
    }
    #[test]
    fn exact_profiles_do_not_infer_compatibility_from_version_names() {
        assert!(radio_profile_matches(Some(B31), None, None, false));
        assert!(radio_profile_matches(Some(B04_IMAGE), Some(B04_MDM), Some(B04_ROUTER), false));
        assert!(radio_profile_matches(Some(B28_IMAGE), Some(B28_MDM), Some(B04_ROUTER), false));
        assert!(radio_profile_matches(None, Some(B04_MDM), Some(B04_ROUTER), true));
        for image in [None, Some(B04_IMAGE), Some(B28_IMAGE)] {
            for (mdm, router) in [(None, Some(B04_ROUTER)), (Some("unknown"), Some(B04_ROUTER)), (Some(B04_MDM), None), (Some(B04_MDM), Some("unknown"))] {
                assert!(!radio_profile_matches(image, mdm, router, true));
            }
        }
        assert!(!radio_profile_matches(None, Some(B04_MDM), Some(B04_ROUTER), false));
        assert!(!radio_profile_matches(None, Some(B28_MDM), Some(B04_ROUTER), true));
        assert!(!radio_profile_matches(Some(B28_IMAGE), Some(B04_MDM), Some(B04_ROUTER), true));
        assert!(!radio_profile_matches(Some(B04_IMAGE), Some(B28_MDM), Some(B04_ROUTER), true));
        for image in ["absent", "BD_XCBZHKMU5250V1.0.0B04", "", "unknown"] {
            assert!(!radio_profile_matches(Some(image), Some(B04_MDM), Some(B04_ROUTER), true));
        }
    }
    #[test]
    fn absent_fallback_requires_both_fresh_public_versions_and_bounds_rpc() {
        use std::os::unix::process::ExitStatusExt;
        for (firmware, inner, expected) in [
            ("XCBZ_HK_MU5250V1.0.0B04", "BD_XCBZHKMU5250V1.0.0B04", true),
            ("XCBZ_HK_MU5250V1.0.0B04", "BD_CNMU5250V1.0.0B31", false),
            ("CN_ZTE_MU5250V1.0.0B31", "BD_XCBZHKMU5250V1.0.0B04", false),
            ("", "", false),
        ] {
            crate::process::with_commands(move |command| {
                assert_eq!(command.get_program(), "ubus");
                assert_eq!(command.get_args().map(|v| v.to_str().unwrap()).collect::<Vec<_>>(), ["call", "zwrt_web", "device_info", "{}"]);
                Ok(std::process::Output { status: std::process::ExitStatus::from_raw(0), stdout: serde_json::to_vec(&serde_json::json!({"integrate_version":firmware,"wa_inner_version":inner,"imei":"private-canary"})).unwrap(), stderr: vec![] })
            }, || assert_eq!(b04_versions_match().unwrap_or(false), expected));
        }
        crate::process::with_commands(|_| Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "private-canary")), || {
            assert_eq!(b04_versions_match().unwrap_err().code, "firmware_check_failed");
        });
    }
    #[test]
    fn only_missing_regular_image_can_select_absent_fallback() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("esim-radio-profile-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let image = root.join("image");
        assert_eq!(measured_component(&image, true).unwrap(), None);
        assert!(measured_component(&image, false).is_err());
        symlink(root.join("missing-target"), &image).unwrap();
        assert!(measured_component(&image, true).is_err());
        fs::remove_file(&image).unwrap();
        fs::create_dir(&image).unwrap();
        assert!(measured_component(&image, true).is_err());
        fs::remove_dir(&image).unwrap();
        fs::write(&image, b"synthetic firmware").unwrap();
        assert_eq!(measured_component(&image, true).unwrap(), Some(hash(b"synthetic firmware")));
        fs::remove_dir_all(root).unwrap();
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
