//! Discovery access does not authorise unverified device-specific operations.
use serde_json::{json, Value};
use tiny_http::Method;

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
        self == Self::Normal || matches!((method, path),
            (&Method::Post, "/api/auth/login") |
            (&Method::Get, "/api/health" | "/api/capabilities" | "/api/cpu" |
                "/api/memory" | "/api/system/top" | "/api/device/thermal/all"))
    }
    pub fn capabilities(self) -> Value {
        json!({"ok": true, "data": {
            "schema_version": 1, "mode": self.name(),
            "device_functions_assessed": false,
            "read_only": self == Self::Discovery,
            "safe_reads": ["health", "capabilities", "cpu", "memory", "system/top", "device/thermal/all"],
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
    fn unknown_mode_fails_closed() {
        assert_eq!(AgentMode::from_value(Some("typo")), AgentMode::Discovery);
        assert_eq!(AgentMode::from_value(Some("")), AgentMode::Discovery);
        assert_eq!(AgentMode::from_value(None), AgentMode::Normal);
    }
    #[test]
    fn discovery_denies_unverified_reads_and_all_hardware_writes() {
        for path in ["/api/dashboard", "/api/device", "/api/modem/capabilities", "/api/sim/imei", "/api/esim/profiles", "/api/router/lan/confirm", "/api/device/reboot", "/api/at"] {
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
