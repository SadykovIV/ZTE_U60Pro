//! Explicit immutable card routes; discovery never changes provisioning or mapping.
use super::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum Target {
    #[serde(rename = "removable-euicc-slot1")]
    Removable,
    #[serde(rename = "internal-euicc-slot2")]
    Internal,
}
pub const TARGETS: [Target; 2] = [Target::Removable, Target::Internal];
impl Target {
    pub fn slot(self) -> u8 {
        match self {
            Self::Removable => 1,
            Self::Internal => 2,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Availability {
    Available,
    Absent,
    Unavailable,
}
#[derive(Clone, Debug, Serialize)]
pub struct Access {
    pub operations: Vec<&'static str>,
    pub network_selected: Option<bool>,
}
impl Access {
    pub fn card_only(confirmed: bool) -> Self {
        Self {
            operations: if confirmed {
                vec!["list", "download", "delete", "rename"]
            } else {
                vec![]
            },
            network_selected: None,
        }
    }
}
fn scalar(value: &Value) -> Result<u64> {
    match value.get("current_sim_slot") {
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
    .ok_or(Error::new("radio_read_failed"))
}
fn b31_selected(sim: &Value, zte: &Value) -> Result<Target> {
    match (scalar(sim)?, scalar(zte)?) {
        // B31's second getter translates selected pSIM1 to0.
        (1, 0) => Ok(Target::Removable),
        (2, 2) => Ok(Target::Internal),
        _ => Err(Error::new("target_selection_unknown")),
    }
}
pub fn network_selected(target: Target) -> Result<bool> {
    let inventory = super::radio_qmi::inventory()?;
    if !inventory
        .iter()
        .any(|(t, state)| *t == target && *state == Availability::Available)
    {
        return Err(Error::new("target_unavailable"));
    }
    if super::resources::b31_selector_supported()? {
        let sim = crate::ubus::call("zwrt_zte_mdm.api", "get_sim_info", Some("{}"))
            .map_err(|_| Error::new("radio_read_failed"))?;
        let zte = crate::ubus::call("zwrt_zte_mdm.api", "zte_get_current_slot_info", Some("{}"))
            .map_err(|_| Error::new("radio_read_failed"))?;
        return Ok(b31_selected(&sim, &zte)? == target);
    }
    // No firmware-name inference. A complete QMI observation must prove this
    // is the sole present card with no other provisioned subscription. Dual-card selectors need an adapter.
    if super::radio_qmi::sole_subscription(target)? {
        Ok(true)
    } else {
        Err(Error::new("target_selection_unknown"))
    }
}
pub fn require_network_selection(target: Target) -> Result<()> {
    if network_selected(target)? {
        Ok(())
    } else {
        Err(Error::new("esim_slot_not_selected"))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn exact_targets_and_b31_selector_translation() {
        for t in TARGETS {
            assert_eq!(
                serde_json::from_value::<Target>(serde_json::to_value(t).unwrap()).unwrap(),
                t
            );
        }
        for bad in [
            json!("slot1"),
            json!(1),
            json!("internal-euicc-slot2 "),
            json!({"physical_slot":1}),
        ] {
            assert!(serde_json::from_value::<Target>(bad).is_err());
        }
        for (a, b, t) in [
            (json!(1), json!(0), Target::Removable),
            (json!("2"), json!("2"), Target::Internal),
        ] {
            assert_eq!(
                b31_selected(
                    &json!({"current_sim_slot":a}),
                    &json!({"current_sim_slot":b})
                )
                .unwrap(),
                t
            );
        }
        for (a, b) in [
            (json!(1), json!(1)),
            (json!(2), json!(0)),
            (json!(0), json!(0)),
            (json!("02"), json!(2)),
            (json!(2.0), json!(2)),
            (json!(null), json!(2)),
        ] {
            assert!(b31_selected(
                &json!({"current_sim_slot":a}),
                &json!({"current_sim_slot":b})
            )
            .is_err());
        }
    }
}
