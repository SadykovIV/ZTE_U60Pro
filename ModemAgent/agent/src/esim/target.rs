//! Fixed hardware variant: a consumer eUICC wired to the embedded-SIM contacts.
//! Slot addressing and the stock network subscription selector are distinct.
use super::{Error, Result};
use serde_json::Value;

pub const NAME: &str = "internal-euicc-slot2";
pub const PHYSICAL_SLOT: u8 = 2;
pub const LOGICAL_SLOT: u8 = 2;

fn selected(value: &Value) -> Result<()> {
    // OEM releases have emitted numeric and string enums. Accept only the
    // exact documented scalar forms, never a truthy value or a nested fallback.
    let slot = match value.get("current_sim_slot") {
        Some(Value::Number(n)) => n.as_u64().filter(|n| *n <= 3),
        Some(Value::String(s)) => match s.as_str() {
            "0" => Some(0),
            "1" => Some(1),
            "2" => Some(2),
            "3" => Some(3),
            _ => None,
        },
        _ => None,
    }
    .ok_or(Error::new("radio_read_failed"))?;
    if slot != u64::from(LOGICAL_SLOT) {
        return Err(Error::new("esim_slot_not_selected"));
    }
    Ok(())
}

/// Require the user-selected embedded subscription before changing a profile
/// that needs a global radio cycle. Both physical rows may be active in QMI
/// while the external SIM supplies the network; GetSlotStatus alone cannot
/// establish this precondition. These fixed getters never switch subscriptions.
/// Failures and private response fields are discarded, not logged or returned.
pub fn require_network_selection() -> Result<()> {
    for method in ["get_sim_info", "zte_get_current_slot_info"] {
        let value = crate::ubus::call("zwrt_zte_mdm.api", method, Some("{}"))
            .map_err(|_| Error::new("radio_read_failed"))?;
        selected(&value)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::os::unix::process::ExitStatusExt;

    #[test]
    fn only_exact_internal_selector_is_accepted() {
        for value in [json!(2), json!("2")] {
            assert!(selected(&json!({"current_sim_slot":value,"iccid":"private-canary"})).is_ok());
        }
        for value in [
            json!(0),
            json!(1),
            json!(3),
            json!("0"),
            json!("1"),
            json!("3"),
        ] {
            assert_eq!(
                selected(&json!({"current_sim_slot":value}))
                    .unwrap_err()
                    .code,
                "esim_slot_not_selected"
            );
        }
        for value in [
            json!(null),
            json!(true),
            json!(2.0),
            json!(4),
            json!(-1),
            json!(" 2"),
            json!("02"),
            json!([2]),
            json!({"value":2}),
        ] {
            assert_eq!(
                selected(&json!({"current_sim_slot":value}))
                    .unwrap_err()
                    .code,
                "radio_read_failed"
            );
        }
        assert!(selected(&json!({"nested":{"current_sim_slot":2}})).is_err());
    }

    #[test]
    fn both_bounded_stock_getters_must_agree_and_raw_failures_never_escape() {
        for (second, expected) in [
            (json!(2), None),
            (json!("2"), None),
            (json!(1), Some("esim_slot_not_selected")),
            (json!(null), Some("radio_read_failed")),
        ] {
            let count = std::rc::Rc::new(std::cell::Cell::new(0));
            let seen = count.clone();
            crate::process::with_commands(
                move |cmd| {
                    let n = seen.get();
                    seen.set(n + 1);
                    assert_eq!(cmd.get_program(), "ubus");
                    assert_eq!(
                        cmd.get_args().collect::<Vec<_>>(),
                        [
                            "call",
                            "zwrt_zte_mdm.api",
                            ["get_sim_info", "zte_get_current_slot_info"][n],
                            "{}"
                        ]
                    );
                    Ok(std::process::Output { status: std::process::ExitStatus::from_raw(0), stdout: serde_json::to_vec(&json!({"current_sim_slot":if n == 0 {json!(2)} else {second.clone()}, "iccid":"private-canary"})).unwrap(), stderr: vec![] })
                },
                || assert_eq!(require_network_selection().err().map(|e| e.code), expected),
            );
            assert_eq!(count.get(), 2);
        }
        for failure in [false, true] {
            crate::process::with_commands(
                move |_| {
                    if failure {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "private-canary",
                        ));
                    }
                    Ok(std::process::Output {
                        status: std::process::ExitStatus::from_raw(256),
                        stdout: b"private-stdout".to_vec(),
                        stderr: b"private-stderr".to_vec(),
                    })
                },
                || {
                    assert_eq!(
                        require_network_selection().unwrap_err().code,
                        "radio_read_failed"
                    )
                },
            );
        }
    }
}
