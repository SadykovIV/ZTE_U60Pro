use std::fs;

use serde_json::{json, Value};

use crate::handlers::AppState;
use crate::ubus;

#[path = "agent_restart.rs"]
mod agent_restart;

/// GET /api/device/thermal/all — identify sensors by type, not firmware-specific
/// zone indices. Named fields retain the web API while `zones` includes sensors
/// with no known display label.
pub fn device_thermal_all(_state: &AppState) -> (u16, Value) {
    let data = thermal_data(std::path::Path::new("/sys/class/thermal"));
    if data["available"] != true {
        return (503, json!({"ok": false, "error": "Thermal sensors are not available", "data": data}));
    }
    (200, json!({"ok": true, "data": data}))
}

fn thermal_data(root: &std::path::Path) -> Value {
    let mut data = serde_json::Map::new();
    let mut zones = Vec::new();
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.strip_prefix("thermal_zone").is_some_and(|value| !value.is_empty() && value.bytes().all(|c| c.is_ascii_digit())) { continue; }
            let read = |leaf: &str| -> Option<String> {
                use std::io::Read;
                let mut bytes = Vec::new();
                fs::File::open(entry.path().join(leaf)).ok()?.take(128).read_to_end(&mut bytes).ok()?;
                String::from_utf8(bytes).ok().map(|value| value.trim().to_string())
            };
            let kind = read("type").filter(|value| !value.is_empty() && value.len() <= 64 && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b)));
            let temperature = read("temp").and_then(|value| value.parse::<i64>().ok())
                .filter(|value| *value > -40_000 && *value < 150_000).map(|value| value as f64 / 1000.0);
            let label = match kind.as_deref() {
                Some("cpuss-0") => Some("cpu_0"), Some("cpuss-1") => Some("cpu_1"),
                Some("cpuss-2") => Some("cpu_2"), Some("cpuss-3") => Some("cpu_3"),
                Some("mdmq6-0") => Some("modem"), Some("mdmss-0") => Some("modem_ss0"),
                Some("mdmss-1") => Some("modem_ss1"), Some("mdmss-2") => Some("modem_ss2"),
                Some("ethphy-0") => Some("eth_phy"), Some("pmx75_tz") => Some("pmic"),
                Some("xo-therm") => Some("xo_therm"), Some("sdr0_pa") => Some("pa"),
                Some("sdr0") => Some("sdr"), Some("battery") => Some("battery"),
                Some("usb") => Some("usb"), _ => None,
            };
            if let (Some(label), Some(value)) = (label, temperature) { data.insert(label.into(), json!(value)); }
            zones.push(json!({"zone": name, "type": kind, "temperature_c": temperature}));
        }
    }
    zones.sort_by_key(|value| value["zone"].as_str().unwrap_or_default().to_string());
    data.insert("available".into(), json!(zones.iter().any(|zone| zone["temperature_c"].is_number())));
    data.insert("zones".into(), json!(zones));
    Value::Object(data)
}

/// GET /api/device/battery/detail — extended battery stats from sysfs
pub fn device_battery_detail(_state: &AppState) -> (u16, Value) {
    let read_sysfs = |name: &str| -> Option<String> {
        fs::read_to_string(format!("/sys/class/power_supply/battery/{name}"))
            .ok()
            .map(|s| s.trim().to_string())
    };
    let read_i64 = |name: &str| -> Option<i64> { read_sysfs(name)?.parse().ok() };

    let capacity = read_i64("capacity");
    let status = read_sysfs("status");
    let voltage_uv = read_i64("voltage_now");
    let voltage_max_uv = read_i64("voltage_max");
    let voltage_ocv_uv = read_i64("voltage_ocv");
    let current_ua = read_i64("current_now");
    // power_now sysfs is unreliable on PM7550B — compute from V * I instead
    let _ = read_i64("power_now"); // ignore sysfs value
    let temp_tenths = read_i64("temp");
    let charge_type = read_sysfs("charge_type");
    let health = read_sysfs("health");
    let cycle_count = read_i64("cycle_count");
    let charge_counter_uah = read_i64("charge_counter");
    let charge_full_uah = read_i64("charge_full");
    let charge_full_design_uah = read_i64("charge_full_design");
    let time_to_full = read_i64("time_to_full_avg").filter(|value| *value >= 0);
    let time_to_empty = read_i64("time_to_empty_avg").filter(|value| *value >= 0);

    // Compute power from voltage * current (more accurate than sysfs power_now)
    let power_mw = voltage_uv
        .zip(current_ua)
        .map(|(voltage, current)| (voltage as f64 * current as f64 / 1e9) as i64);
    let available = capacity.is_some() || status.is_some() || voltage_uv.is_some();

    (
        200,
        json!({"ok": true, "data": {
            "available": available,
            "capacity": capacity,
            "status": status,
            "voltage_mv": voltage_uv.map(|value| value / 1000),
            "voltage_max_mv": voltage_max_uv.map(|value| value / 1000),
            "voltage_ocv_mv": voltage_ocv_uv.map(|value| value / 1000),
            "current_ma": current_ua.map(|value| value / 1000),
            "power_mw": power_mw,
            "temperature_c": temp_tenths.map(|value| value as f64 / 10.0),
            "charge_type": charge_type,
            "health": health,
            "cycle_count": cycle_count,
            "charge_counter_mah": charge_counter_uah.map(|value| value / 1000),
            "charge_full_mah": charge_full_uah.map(|value| value / 1000),
            "charge_full_design_mah": charge_full_design_uah.map(|value| value / 1000),
            "time_to_full_secs": time_to_full,
            "time_to_empty_secs": time_to_empty,
        }}),
    )
}

pub fn device_charger(_state: &AppState) -> (u16, Value) {
    match ubus::call("zwrt_bsp.charger", "list", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn device_reboot(_state: &AppState) -> (u16, Value) {
    match ubus::call("system", "reboot", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn device_shutdown(_state: &AppState) -> (u16, Value) {
    match ubus::call(
        "zwrt_mc.device.manager",
        "device_poweroff",
        Some(r#"{"moduleName":"zte-agent"}"#),
    ) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn agent_restart(_state: &AppState) -> (u16, Value) {
    match agent_restart::schedule() {
        Ok(_) => (
            200,
            json!({"ok": true, "message": "Agent restarting in ~2 seconds"}),
        ),
        Err(code) => (
            409,
            json!({"ok": false, "code": code, "error": "Agent restart could not be safely prepared"}),
        ),
    }
}

/// GET /api/device/charge-control — charge stop state + limit enforcer config
pub fn charge_control_get(state: &AppState) -> (u16, Value) {
    let read_sysfs = |path: &str| -> Option<String> {
        fs::read_to_string(path)
            .ok()
            .map(|value| value.trim().to_string())
    };

    let battery_status = read_sysfs("/sys/class/power_supply/battery/status");
    let capacity: Option<i64> =
        read_sysfs("/sys/class/power_supply/battery/capacity").and_then(|value| value.parse().ok());

    // Inverted firmware semantics: direct_power_supply_mode "enable" = charging STOPPED
    let charging_stopped = ubus::call("zwrt_bsp.charger", "list", Some("{}"))
        .ok()
        .and_then(|v| {
            v["direct_power_supply_mode"]
                .as_str()
                .map(|s| s == "enable")
        });
    let battery_available = capacity.is_some() || battery_status.is_some();
    let charger_available = charging_stopped.is_some();

    let (limit_enabled, limit_pct, hysteresis, manual_override) = state.charge_limit.get();

    (
        200,
        json!({
            "ok": true,
            "data": {
                "available": battery_available || charger_available,
                "battery_available": battery_available,
                "charger_available": charger_available,
                "charging_stopped": charging_stopped,
                "battery_status": battery_status,
                "capacity": capacity,
                "charge_limit_enabled": limit_enabled,
                "charge_limit": limit_pct,
                "hysteresis": hysteresis,
                "manual_override": manual_override,
                "last_error": state.charge_limit.last_error(),
            }
        }),
    )
}

/// PUT /api/device/charge-control — manual charge stop/resume and limit config
pub fn charge_control_set(state: &AppState, body: &[u8]) -> (u16, Value) {
    let update: crate::charge_policy::ChargeUpdate = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(e) => {
            return (
                400,
                json!({"ok": false, "error": format!("invalid charge control: {e}")}),
            )
        }
    };
    if let Err(error) = state.charge_limit.update(update) {
        return (503, json!({"ok": false, "error": error}));
    }
    charge_control_get(state)
}

#[cfg(test)]
mod thermal_tests {
    use super::*;
    #[test]
    fn sensor_types_survive_reordered_zones_and_unknown_values_are_explicit() {
        let root = std::env::temp_dir().join(format!("zte-thermal-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        for (index, kind, temp) in [(1, "cpuss-0", "42000"), (16, "unknown-sensor", "37000"),
            (22, "mdmq6-0", "-273000"), (28, "pmx75_tz", "bad")] {
            let zone = root.join(format!("thermal_zone{index}"));
            fs::create_dir(&zone).unwrap();
            fs::write(zone.join("type"), kind).unwrap();
            fs::write(zone.join("temp"), temp).unwrap();
        }
        let value = thermal_data(&root);
        assert_eq!(value["cpu_0"], 42.0);
        assert!(value.get("modem").is_none());
        assert!(value.get("pmic").is_none());
        assert_eq!(value["zones"].as_array().unwrap().len(), 4);
        assert_eq!(value["available"], true);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn missing_thermal_source_is_unavailable() {
        let value = thermal_data(std::path::Path::new("/path-not-existing-zte-thermal"));
        assert_eq!(value["available"], false);
        assert_eq!(value["zones"], json!([]));
    }
}
