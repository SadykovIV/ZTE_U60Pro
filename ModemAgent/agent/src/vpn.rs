//! The authenticated API delegates VPN changes to the same pinned controller
//! used over SSH by the desktop. Credentials travel through stdin only.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    process::Command,
    time::Duration,
};
const HELPER: &str = "/data/zte-vpn/vpnctl";
pub const REQUEST_LIMIT: usize = 32 * 1024 * 1024;
const HELPER_SHA: &str = "46257e8e24397f097b3ce3e53067ad59b265803f66aeb2da6d216b05dd2e5db7";

// Keep reviewed controllers usable when only the agent is updated. The build
// retains the previous source pin here; no device-provided hash is accepted.
const PREVIOUS_HELPER_SHAS: &[&str] = &[
    "f5e1c9e627e3e978ff535de79b95ff920d7318e7ea3ce713e5b174efe313ca0c",
    "cf15a6290316dd6832873e35972831a590d70cf0734eb93dbcd96aab87fab6f1",
    "b2c3fcfafeccd50fa3000ad5f8f66f1e42ff157b295cdda11dddd31571612af7",
    "fe1f6d535ccee6ec0f9333c01108b00f35006209850ed641023dbb937dd30b48",
    "82a8b6655ff6cd43938ffe3735e8841599ef6116bf33079d8d203db9415ca3f2",
    "b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a",
    "e00749ed2a6273c95a4b0563212313c81e54928f6564fdbd8f9616d12a4df6ba",
    "8aaece533e2503c7a501497bb1bf191f37a0ffbba067e7a7ff3a4c6f9623673f",
    "3b572cf943d16a66dae1d62515b216eceaf77d397035320eb3c08a5db0e21fc4",
    "a35d788005d4150cd909f85afc667073a03febd24b50a708facf506b051c8a65",
    "ff5859edb44d83fad9723ccdc142f28ce918b02fae3da929667726d32746986c",
    "4e8b92cc5089200f3fced24130e47e0918bf8931989af034f709344a42cd5b0d",
    "61ccaf5fa0361178dd6fe4a0104d964168f4f79a8453a8617a80a7403240d393",
];
fn supported_helper(hash: &str) -> bool {
    hash == HELPER_SHA || PREVIOUS_HELPER_SHAS.contains(&hash)
}

fn error(status: u16, code: &str) -> (u16, Value) {
    (
        status,
        json!({"ok":false,"code":code,"error":"VPN settings could not be updated. Refresh the status before retrying."}),
    )
}
fn verified() -> bool {
    let Ok(root) = fs::symlink_metadata("/data/zte-vpn") else {
        return false;
    };
    if !root.is_dir() || root.uid() != 0 || root.mode() & 0o777 != 0o700 {
        return false;
    }
    let Ok(mut f) = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(HELPER)
    else {
        return false;
    };
    let Ok(m) = f.metadata() else { return false };
    if !m.is_file() || m.uid() != 0 || m.mode() & 0o022 != 0 || m.len() > 16 * 1024 * 1024 {
        return false;
    }
    let mut bytes = Vec::new();
    if f.by_ref()
        .take(16 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .is_err()
    {
        return false;
    }
    supported_helper(&format!("{:x}", Sha256::digest(bytes)))
}
fn execute(body: &Value) -> (u16, Value) {
    if !verified() {
        return error(503, "VPN_NOT_INSTALLED");
    }
    let input = match serde_json::to_vec(body) {
        Ok(b) if b.len() <= REQUEST_LIMIT => b,
        _ => return error(400, "VPN_INVALID_REQUEST"),
    };
    let output = match process_runner::output(
        Command::new(HELPER).arg("request"),
        Some(&input),
        Duration::from_secs(220),
        2 * 1024 * 1024,
    ) {
        Ok(o) => o,
        Err(_) => return error(504, "VPN_OPERATION_TIMEOUT"),
    };
    let Ok(reply) = serde_json::from_slice::<Value>(&output.stdout) else {
        return error(502, "VPN_INVALID_RESPONSE");
    };
    if output.status.success() && reply["ok"] == true && reply["data"]["schema_version"] == 1 {
        return (200, reply);
    }
    let code = reply["code"]
        .as_str()
        .filter(|s| public_error_code(s))
        .unwrap_or("VPN_OPERATION_FAILED");
    error(
        if code == "VPN_BUSY" || code == "VPN_OTHER_TRANSACTION" {
            409
        } else {
            400
        },
        code,
    )
}
fn public_error_code(code: &str) -> bool {
    code.starts_with("VPN_") && code.len() < 64
        && code.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
}
pub fn status() -> (u16, Value) {
    if matches!(fs::symlink_metadata("/data/zte-vpn"),Err(e) if e.kind()==std::io::ErrorKind::NotFound)
    {
        return (
            200,
            json!({"ok":true,"data":{"schema_version":1,"installed":false,"profiles":[]}}),
        );
    }
    execute(&json!({"action":"status"}))
}
pub fn request(bytes: &[u8]) -> (u16, Value) {
    if bytes.len() > REQUEST_LIMIT {
        return error(400, "VPN_INVALID_REQUEST");
    }
    let Ok(body) = serde_json::from_slice::<Value>(bytes) else {
        return error(400, "VPN_INVALID_REQUEST");
    };
    let Some(action) = body["action"].as_str() else {
        return error(400, "VPN_INVALID_REQUEST");
    };
    if !public_action(action) {
        return error(400, "VPN_INVALID_REQUEST");
    }
    execute(&body)
}
fn public_action(action: &str) -> bool {
    [
        "import",
        "import_config",
        "save_ikev2",
        "subscription_import",
        "subscription_update",
        "subscription_delete",
        "subscription_details",
        "activate",
        "delete",
        "rename",
        "details",
        "screen_open",
        "screen_close",
        "set_enabled",
        "configure_wifi",
        "recover",
    ]
    .contains(&action)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn structured_ikev2_save_is_a_public_action() {
        assert!(public_action("save_ikev2"));
        assert!(!public_action("ipsec"));
        assert!(!public_action("shell"));
        assert!(public_error_code("VPN_IKEV2_INVALID_CERTIFICATE"));
        assert!(!public_error_code("VPN_IKEV2_error: password"));
    }
    #[test]
    fn previous_b31_controller_remains_supported_after_agent_update() {
        assert!(supported_helper(HELPER_SHA));
        for previous in PREVIOUS_HELPER_SHAS {
            assert!(supported_helper(previous));
        }
        // Agent-only upgrades must retain the delivered 1.24.22 controller and
        // the first reviewed 1.25 candidate already installed on the test modem.
        assert!(supported_helper("b5f581427afd423be3931473db2ce4b496a387b685ab3c48adf26cc597000f9a"));
        assert!(supported_helper("e00749ed2a6273c95a4b0563212313c81e54928f6564fdbd8f9616d12a4df6ba"));
        assert!(!supported_helper(&"f".repeat(64)));
        assert!(!supported_helper(""));
        assert!(!supported_helper(&HELPER_SHA.to_uppercase()));
    }
    #[test]
    fn rejects_internal_commands_before_execution() {
        for action in ["integrity", "hook-network", "shell", ""] {
            let (s, b) = request(&serde_json::to_vec(&json!({"action":action})).unwrap());
            assert_eq!(s, 400);
            assert_eq!(b["code"], "VPN_INVALID_REQUEST");
        }
    }
    #[test]
    fn public_error_never_contains_profile() {
        let (_, b) = error(400, "VPN_INVALID_KEY");
        assert!(!b.to_string().contains("vless://"));
    }
}
