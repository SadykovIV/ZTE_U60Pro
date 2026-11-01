//! Invalid protocol input must stop before the card lock or QRTR connection.
use std::io::Write;
use std::process::{Command, Stdio};

#[test]
fn invalid_header_is_rejected_before_device_setup_in_both_modes() {
    for mode in ["snapshot", "bridge"] {
        for (input, expected) in [
            ("", "missing_header"),
            ("{}\n", "invalid_header"),
            ("{\"expected_eid\":\"11111111111111111111111111111111\"}\n", "invalid_header"),
            ("{\"protocol\":1,\"target\":\"internal-euicc-slot2\"}\n", "invalid_header"),
            ("{\"protocol\":2,\"target\":\"auto\"}\n", "invalid_header"),
            ("{\"protocol\":2,\"target\":\"removable-euicc-slot2\"}\n", "invalid_header"),
        ] {
            let mut child = Command::new(env!("CARGO_BIN_EXE_zte-removable-euicc"))
                .arg(mode)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(!output.status.success());
            assert!(output.stdout.is_empty());
            let event: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
            assert_eq!(event, serde_json::json!({"event":"error","code":expected}));
        }
    }
}
