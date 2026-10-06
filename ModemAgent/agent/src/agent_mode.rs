//! Discovery access does not authorise unverified device-specific operations.
use serde_json::{json, Value};
use tiny_http::Method;

pub const SAFE_READS: &[&str] = &[
    "health", "capabilities", "cpu", "memory", "system/top", "device/thermal/all",
    "dashboard", "device", "device/battery-info", "device/battery/detail",
    "device/charger", "device/charge-control", "network/clients", "wifi/status",
    "sim/info", "sim/imei", "router/dns", "router/lan", "router/apn/mode",
    "router/apn/profiles", "usb/status",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentMode {
    Normal,
    Discovery,
}
impl AgentMode {
    pub fn from_value(value: Option<&str>) -> Self {
        match value {
            None | Some("normal") => Self::Normal,
            _ => Self::Discovery,
        }
    }
    pub fn name(self) -> &'static str {
        match self { Self::Normal => "normal", Self::Discovery => "discovery" }
    }
    pub fn permits(self, method: &Method, path: &str) -> bool {
        self == Self::Normal || (method == &Method::Post && matches!(path, "/api/auth/login" | "/api/system/restart-agent"))
            || (method == &Method::Get && path.strip_prefix("/api/").is_some_and(|p| SAFE_READS.contains(&p)))
    }
    pub fn capabilities(self) -> Value {
        json!({"ok": true, "data": {
            "schema_version": 1, "mode": self.name(),
            "device_functions_assessed": false,
            "read_only": false,
            "hardware_read_only": self == Self::Discovery,
            "software_controls": ["system/restart-agent"],
            "safe_reads": SAFE_READS,
            "read_capabilities": SAFE_READS.iter().map(|path| json!({
                "path": format!("/api/{path}"), "method": "GET", "permitted": true,
                "source_availability": "assessed-on-request"
            })).collect::<Vec<_>>(),
            "hardware_controls": "not-assessed",
            "reason": "Hardware functions require their own device compatibility checks."
        }})
    }
}
pub fn denied() -> (u16, Value) {
    (403, json!({"ok": false, "code": "CAPABILITY_NOT_ASSESSED", "mode": "discovery",
        "error": "This device function has not been assessed. Run device inspection and use a verified adapter."}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_explicit_reads_do_not_authorize_same_path_writes() {
        for path in ["/api/health", "/api/capabilities", "/api/cpu", "/api/memory", "/api/system/top",
            "/api/device/thermal/all", "/api/dashboard", "/api/device", "/api/device/battery-info",
            "/api/device/battery/detail", "/api/device/charger", "/api/device/charge-control",
            "/api/network/clients", "/api/wifi/status", "/api/sim/info", "/api/sim/imei",
            "/api/router/dns", "/api/router/lan", "/api/router/apn/mode", "/api/router/apn/profiles", "/api/usb/status"] {
            assert!(AgentMode::Discovery.permits(&Method::Get, path), "{path}");
            for method in [Method::Post, Method::Put, Method::Delete, Method::Patch, Method::Head] {
                assert!(!AgentMode::Discovery.permits(&method, path), "{method} {path}");
            }
        }
        let body = AgentMode::Discovery.capabilities();
        assert_eq!(body["data"]["safe_reads"].as_array().unwrap().len(), 21);
        assert_eq!(body["data"]["hardware_controls"], "not-assessed");
        assert_eq!(body["data"]["device_functions_assessed"], false);
    }
    #[test]
    fn discovery_can_restart_only_its_own_agent_without_enabling_hardware_controls() {
        assert!(AgentMode::Discovery.permits(&Method::Post, "/api/system/restart-agent"));
        for method in [Method::Get, Method::Put, Method::Delete, Method::Patch, Method::Head] {
            assert!(!AgentMode::Discovery.permits(&method, "/api/system/restart-agent"));
        }
        for path in ["/api/device/reboot", "/api/device/shutdown", "/api/system/kill-bloat", "/api/router/lan/confirm", "/api/usb/mode"] {
            assert!(!AgentMode::Discovery.permits(&Method::Post, path));
        }
        let body = AgentMode::Discovery.capabilities();
        assert_eq!(body["data"]["hardware_read_only"], true);
        assert_eq!(body["data"]["read_only"], false);
        assert_eq!(body["data"]["software_controls"], json!(["system/restart-agent"]));
    }
    #[test]
    fn unknown_mode_fails_closed() {
        assert_eq!(AgentMode::from_value(Some("typo")), AgentMode::Discovery);
        assert_eq!(AgentMode::from_value(Some("")), AgentMode::Discovery);
        assert_eq!(AgentMode::from_value(None), AgentMode::Normal);
    }
    #[test]
    fn discovery_denies_unverified_reads_and_all_hardware_writes() {
        for path in ["/api/modem/capabilities", "/api/esim/profiles", "/api/router/lan/confirm", "/api/device/reboot", "/api/at", "/api/at/port", "/api/sms/capabilities", "/api/vpn/status", "/api/ttl/status"] {
            for method in [Method::Get,Method::Post,Method::Put,Method::Delete] {
                assert!(!AgentMode::Discovery.permits(&method,path), "{method} {path}");
            }
        }
        assert!(AgentMode::Discovery.permits(&Method::Post,"/api/auth/login"));
        assert!(AgentMode::Discovery.permits(&Method::Get,"/api/health"));
        assert!(!AgentMode::Discovery.permits(&Method::Post,"/api/health"));
        assert!(AgentMode::Normal.permits(&Method::Post,"/api/device/reboot"));
    }
}
