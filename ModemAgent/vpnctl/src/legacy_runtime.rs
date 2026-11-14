//! Exact previously shipped payloads, recorded from local release resources.
//! This separates package integrity from an older controller's firmware policy.
//! Unknown controllers and altered/missing files never receive this migration.
use crate::profile::Result;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Registry {
    schema: u32,
    controllers: BTreeMap<String, BTreeMap<String, String>>,
}

fn registry() -> Result<Registry> {
    let value: Registry = serde_json::from_str(include_str!("../legacy-runtime.json")).map_err(|_| "VPN_INTEGRITY")?;
    if value.schema != 1 { return Err("VPN_INTEGRITY"); }
    Ok(value)
}

pub fn verify(controller: &str, mut measure: impl FnMut(&str) -> Result<String>) -> Result<()> {
    let registry = registry()?;
    let files = registry.controllers.get(controller).ok_or("VPN_INTEGRITY")?;
    // These releases all contain this exact runtime set; registry entries cannot
    // introduce paths or selectively omit a damaged component.
    if files.len() != crate::FILES.len() || crate::FILES.iter().any(|(name, _)| !files.contains_key(*name)) {
        return Err("VPN_INTEGRITY");
    }
    for (name, expected) in files {
        if measure(name)? != *expected { return Err("VPN_INTEGRITY"); }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn previous_release_requires_every_exact_file() {
        for (controller, files) in registry().unwrap().controllers {
            assert!(verify(&controller, |name| Ok(files[name].clone())).is_ok());
            for changed in files.keys() {
                assert!(verify(&controller, |name| Ok(if name == changed { "altered".into() } else { files[name].clone() })).is_err());
                assert!(verify(&controller, |name| if name == changed { Err("VPN_FILE_UNAVAILABLE") } else { Ok(files[name].clone()) }).is_err());
            }
        }
    }
    #[test]
    fn unknown_controller_cannot_use_matching_runtime_to_gain_trust() {
        assert!(verify(&"0".repeat(64), |_| panic!("unknown controller must fail before file probes")).is_err());
    }
}
