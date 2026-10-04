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
const HELPER_SHA: &str = "7a12d8b869d064229270a264e8de9adf64f620337995fb186854c35cadbee068";

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
    format!("{:x}", Sha256::digest(bytes)) == HELPER_SHA
}
fn execute(body: &Value) -> (u16, Value) {
    if !verified() {
        return error(503, "VPN_NOT_INSTALLED");
    }
    let input = match serde_json::to_vec(body) {
        Ok(b) if b.len() <= 65536 => b,
        _ => return error(400, "VPN_INVALID_REQUEST"),
    };
    let output = match process_runner::output(
        Command::new(HELPER).arg("request"),
        Some(&input),
        Duration::from_secs(220),
        256 * 1024,
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
        .filter(|s| {
            s.starts_with("VPN_")
                && s.len() < 64
                && s.bytes().all(|b| b.is_ascii_uppercase() || b == b'_')
        })
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
    if bytes.len() > 65536 {
        return error(400, "VPN_INVALID_REQUEST");
    }
    let Ok(body) = serde_json::from_slice::<Value>(bytes) else {
        return error(400, "VPN_INVALID_REQUEST");
    };
    let Some(action) = body["action"].as_str() else {
        return error(400, "VPN_INVALID_REQUEST");
    };
    if ![
        "import",
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
    {
        return error(400, "VPN_INVALID_REQUEST");
    }
    execute(&body)
}

#[cfg(test)]
mod tests {
    use super::*;
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
