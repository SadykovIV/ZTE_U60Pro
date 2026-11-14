//! One compatibility policy for installation, integrity and IPA operations.
//! Firmware selects a measured family; vendor controls are verified separately
//! by their actual bytes. A new image never authorizes an unknown IPA daemon.
use crate::{hash, profile::Result};
use serde::Serialize;
use std::{fs, io::Read, os::unix::fs::{MetadataExt, OpenOptionsExt}, path::Path};

pub const B29_IMAGE: &str = "33c09756e2b27511d0d36ffef6aeeb72732de756935e067d4571dfb8de8c3636";
const B31_IMAGE: &str = "604e22f213e1bef241296e5aae161991989fd8df790057935c07d45101ae4263";
const B28_IMAGE: &str = "5a4489882538b5ab1d3e0049371f1b620d28d262a429923299b4f2626d40d478";
const B27_IMAGE: &str = "4b1c67e73b94b889adc831168040d40ec368083dfbcec7ae747a2f4f86c66f3e";
const B04_IMAGE: &str = "c57e063d390983229dfc53aa87380b3d4655ee8daa1c748e1a032ac90cd0df81";
const B27_MDM: &str = "00a647cb46fa82a78969b3708c1429d91b37ef99c2c00835ac57ca53c126f25d";
const B27_ROUTER: &str = "786ba99f5d506d01bbe72d9effa90d1a46f5929370f24ccabf6bab291e5a317f";
const B04_MDM: &str = "93a346e7d69024503caf9ad42f14c97e1514dd7d04c7b5ebef4e30473b5d5c64";
const B04_ROUTER: &str = "55c54f74aaa427940254a2f16c36771e675a80a002363e4f10b0dfcb604d9c6f";
const IPA_SWITCH: &str = "8947eee9c554453dc8eeb77df933cd12899f447c8c03df3505c57c7b526d22b9";
struct Profile {
    id: &'static str,
    image: &'static str,
    image_may_be_absent: bool,
    native: Option<(&'static str, &'static str)>,
    ipa_daemon: &'static str,
}
const CN_IPA: &str = "95385816da7b2edb9a977cee328c091753463fcd4a70a67fa1676e8b335c11c0";
const B28_IPA: &str = "a8a90ee631a3e8de3266d1d4231e455c34fd0b0d1ad570e7c4d0dcd09eea1c54";
const B27_IPA: &str = "a843789933a0b5747927583021c1480957ea942626cab17cb13ad415d1dfd3ae";
const PROFILES: &[Profile] = &[
    Profile { id: "cn-b31", image: B31_IMAGE, image_may_be_absent: false, native: None, ipa_daemon: CN_IPA },
    Profile { id: "fly-b28", image: B28_IMAGE, image_may_be_absent: false, native: None, ipa_daemon: B28_IPA },
    Profile { id: "fly-b27", image: B27_IMAGE, image_may_be_absent: false, native: Some((B27_MDM, B27_ROUTER)), ipa_daemon: B27_IPA },
    Profile { id: "hk-b04", image: B04_IMAGE, image_may_be_absent: true, native: Some((B04_MDM, B04_ROUTER)), ipa_daemon: CN_IPA },
    // The complete B14/B29 capture independently matches the CN IPA switch,
    // daemon and stock network hook. Keep the component checks on the device.
    Profile { id: "cn-b29", image: B29_IMAGE, image_may_be_absent: false, native: None, ipa_daemon: CN_IPA },
];

#[derive(Serialize, Debug)]
pub struct Compatibility {
    pub profile: &'static str,
    pub network_adapter: &'static str,
    pub ipa_adapter: &'static str,
}

fn family(image: Option<&str>) -> Result<&'static Profile> {
    PROFILES.iter().find(|profile| image == Some(profile.image) || (image.is_none() && profile.image_may_be_absent))
        .ok_or("VPN_UNSUPPORTED_FIRMWARE")
}

fn ipa(switch: &str, daemon: &str, expected: &str) -> Result<&'static str> {
    if switch == IPA_SWITCH && daemon == expected {
        Ok("qualcomm-ipa-usr1-v1")
    } else { Err("VPN_IPA_UNSUPPORTED") }
}

// Never execute these files to identify them. Reject symlinks, devices and
// unsafe ownership before a bounded read. Stock group-root writable files are
// permitted; unprivileged writers are not.
fn system_hash(path: &Path) -> Result<Option<String>> {
    let mut file = match fs::OpenOptions::new().read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A dangling symlink must not become proof of an absent B04 image.
            if fs::symlink_metadata(path).is_ok() { return Err("VPN_UNSAFE_FILE"); }
            return Ok(None);
        }
        Err(_) => return Err("VPN_UNSAFE_FILE"),
    };
    let metadata = file.metadata().map_err(|_| "VPN_UNSAFE_FILE")?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.nlink() != 1
        || metadata.mode() & 0o002 != 0 || (metadata.mode() & 0o020 != 0 && metadata.gid() != 0)
        || metadata.len() > 32 * 1024 * 1024 { return Err("VPN_UNSAFE_FILE"); }
    let mut bytes = Vec::new();
    (&mut file).take(32 * 1024 * 1024 + 1).read_to_end(&mut bytes).map_err(|_| "VPN_FILE_UNAVAILABLE")?;
    if bytes.len() as u64 != metadata.len() { return Err("VPN_FILE_UNAVAILABLE"); }
    Ok(Some(hash(&bytes)))
}

fn verify_with(mut measure: impl FnMut(&str) -> Result<Option<String>>) -> Result<Compatibility> {
    let image = measure("/firmware/image/modem.b16")?;
    let profile = family(image.as_deref())?;
    if let Some((expected_mdm, expected_router)) = profile.native {
        let mdm = measure("/usr/bin/zte_topsw_mdm")?;
        let router = measure("/usr/bin/diag-router")?;
        if mdm.as_deref() != Some(expected_mdm) || router.as_deref() != Some(expected_router) {
            return Err("VPN_UNSUPPORTED_FIRMWARE");
        }
    }
    let switch = measure("/sbin/ipacm_switch.sh")?.ok_or("VPN_IPA_UNSUPPORTED")?;
    let daemon = measure("/usr/bin/ipacm")?.ok_or("VPN_IPA_UNSUPPORTED")?;
    Ok(Compatibility { profile: profile.id, network_adapter: "zte-netifd-guest-v1", ipa_adapter: ipa(&switch, &daemon, profile.ipa_daemon)? })
}

pub fn verify() -> Result<Compatibility> {
    // The production artifact is built only for Linux/aarch64; a host build is
    // useful for offline tests but must never certify a modem platform.
    if !cfg!(all(target_os = "linux", target_arch = "aarch64")) { return Err("VPN_UNSUPPORTED_PLATFORM"); }
    verify_with(|path| system_hash(Path::new(path)))
}

pub fn stock_network() -> Result<()> {
    if system_hash(Path::new("/etc/init.d/network"))?.as_deref()
        == Some(hash(include_bytes!("../../../MacIMEI/Resources/VPN/network.stock")).as_str()) {
        Ok(())
    } else { Err("VPN_NETWORK_INIT_CHANGED") }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn observed(image: Option<&str>, daemon: Option<&str>, switch: Option<&str>, mdm: Option<&str>, router: Option<&str>) -> Result<Compatibility> {
        verify_with(|path| Ok(match path {
            "/firmware/image/modem.b16" => image, "/usr/bin/ipacm" => daemon,
            "/sbin/ipacm_switch.sh" => switch, "/usr/bin/zte_topsw_mdm" => mdm,
            "/usr/bin/diag-router" => router, _ => panic!("unexpected dependency"),
        }.map(str::to_string)))
    }
    #[test]
    fn measured_families_keep_exact_component_combinations() {
        for profile in PROFILES {
            let (mdm, router) = profile.native.map(|(a,b)| (Some(a),Some(b))).unwrap_or((None,None));
            assert!(observed(Some(profile.image), Some(profile.ipa_daemon), Some(IPA_SWITCH), mdm, router).is_ok());
            for daemon in [CN_IPA,B27_IPA,B28_IPA] {
                if daemon != profile.ipa_daemon {
                    assert!(observed(Some(profile.image), Some(daemon), Some(IPA_SWITCH), mdm, router).is_err());
                }
            }
        }
    }
    #[test]
    fn b29_image_alone_never_authorizes_vendor_controls() {
        for daemon in [None, Some("unknown"), Some("")] {
            assert_eq!(observed(Some(B29_IMAGE), daemon, Some(IPA_SWITCH), None, None).unwrap_err(), "VPN_IPA_UNSUPPORTED");
        }
        for switch in [None, Some("unknown")] {
            assert_eq!(observed(Some(B29_IMAGE), Some(CN_IPA), switch, None, None).unwrap_err(), "VPN_IPA_UNSUPPORTED");
        }
    }
    #[test]
    fn native_requirements_and_unknown_firmware_remain_closed() {
        assert!(observed(Some(B27_IMAGE), Some(B27_IPA), Some(IPA_SWITCH), Some(B27_MDM), Some(B27_ROUTER)).is_ok());
        for image in [None, Some(B04_IMAGE)] {
            assert!(observed(image, Some(CN_IPA), Some(IPA_SWITCH), Some(B04_MDM), Some(B04_ROUTER)).is_ok());
            assert!(observed(image, Some(CN_IPA), Some(IPA_SWITCH), None, Some(B04_ROUTER)).is_err());
        }
        assert!(observed(Some(B27_IMAGE), Some(B27_IPA), Some(IPA_SWITCH), Some(B04_MDM), Some(B27_ROUTER)).is_err());
        assert!(observed(Some("unknown"), Some(CN_IPA), Some(IPA_SWITCH), Some(B04_MDM), Some(B04_ROUTER)).is_err());
    }
    #[test]
    fn read_failure_never_becomes_missing_image() {
        assert_eq!(verify_with(|_| Err("VPN_UNSAFE_FILE")).unwrap_err(), "VPN_UNSAFE_FILE");
    }
    #[test]
    fn host_binary_cannot_certify_a_linux_modem() {
        if !cfg!(all(target_os = "linux", target_arch = "aarch64")) {
            assert_eq!(verify().unwrap_err(), "VPN_UNSUPPORTED_PLATFORM");
        }
    }
}
