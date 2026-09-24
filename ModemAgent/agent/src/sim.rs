use serde_json::{json, Value};

use crate::handlers::AppState;
use crate::ubus;

pub fn sim_info(_state: &AppState) -> (u16, Value) {
    match ubus::call("zwrt_zte_mdm.api", "get_sim_info", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sim_imei(_state: &AppState) -> (u16, Value) {
    match ubus::call("zwrt_zte_mdm.api", "get_imei", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}
