//! Explicitly requested private provider fixtures; never included in the source tree.
#![allow(dead_code)]
#[path = "../src/awg.rs"] mod awg;
#[path = "../src/profile.rs"] mod profile;
#[path = "../src/subscription.rs"] mod subscription;
use std::{fs, os::unix::fs::OpenOptionsExt, io::Write};
#[test]
#[ignore = "requires private provider responses in ZTE_VPN_FIXTURES"]
fn private_provider_feeds() {
    let root = std::path::PathBuf::from(std::env::var_os("ZTE_VPN_FIXTURES").unwrap());
    for (n, expected) in [(1,14), (2,43), (3,9)] {
        let mut documents = vec![fs::read_to_string(root.join(format!("subscription-{n}-mihomo.private"))).unwrap()];
        documents.push(fs::read_to_string(root.join(format!("subscription-{n}.private"))).unwrap());
        let parsed = subscription::select(&documents).unwrap_or_else(|code| {
            use base64::Engine;
            if let Ok(data) = base64::engine::general_purpose::STANDARD.decode(documents[1].trim()) {
                for (index,line) in String::from_utf8_lossy(&data).lines().enumerate() {
                    if let Err(code) = profile::parse(line, None) { eprintln!("provider {n}, entry {}: {code}", index+1); }
                }
            }
            panic!("provider {n}: {code}");
        });
        assert_eq!(parsed.profiles.len(), expected, "provider {n}");
        assert!(parsed.skipped.is_empty(), "provider {n}: {} rejected entries", parsed.skipped.len());
        let output = root.join(format!("subscription-{n}-normalized.private.json"));
        let mut file = fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(output).unwrap();
        file.write_all(&serde_json::to_vec(&parsed.profiles).unwrap()).unwrap();
        println!("provider {n}: {} profiles, {} duplicates", parsed.profiles.len(), parsed.duplicates);
    }
}
