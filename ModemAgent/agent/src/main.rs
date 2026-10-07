use crate::process::BoundedCommand;
mod at_cmd;
mod auth;
mod cache;
mod cell;
mod charge_policy;
mod connection_logger;
mod csv_utils;
mod device_ext;
mod event_bus;
mod handlers;
mod lan;
mod logging;
mod network_ext;
mod process;
mod router;
mod server;
mod signal_logger;
mod sim;
mod sms;
mod storage;
mod system;
mod ttl;
mod ubus;
mod uci_transaction;
mod usb;
mod util;
mod validate;
mod wifi;
mod vpn;
#[cfg(feature = "esim")]
mod esim;

#[cfg(feature = "esim")]
const AGENT_VERSION: &str = "2.9.0-esim.6";
#[cfg(not(feature = "esim"))]
const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");

use std::sync::Arc;

use event_bus::EventBus;
use handlers::AppState;

const DEFAULT_THREADS: usize = 4;
const STARTUP_SCRIPT: &str = "/data/local/tmp/start_zte_agent.sh";

fn main() {
    #[cfg(feature = "esim")]
    if let Some(code) = esim::early_entry() {
        std::process::exit(code);
    }

    let threads: usize = std::env::var("ZTE_AGENT_THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_THREADS);

    migrate_drop_removed_features();
    let state = Arc::new(AppState::new());

    // Set password from environment if provided
    if let Ok(pw) = std::env::var("ZTE_AGENT_PASSWORD") {
        state.auth.set_password(&pw);
    } else if let Some(pw) = read_startup_export("ZTE_AGENT_PASSWORD") {
        // Fallback: try reading from the startup script if executed manually
        state.auth.set_password(&pw);
    }

    let pin = std::env::var("ZTE_AGENT_PIN")
        .ok()
        .or_else(|| read_startup_export("ZTE_AGENT_PIN"));
    if let Some(pin) = pin {
        if let Err(e) = state.auth.set_pin(&pin) {
            eprintln!("[WARN] ignoring invalid ZTE_AGENT_PIN: {e}");
        }
    }

    // Each background control is tied to its own saved user request and checks
    // its device interface before applying a change.
    let event_bus = EventBus::new();
    let charger_rx = event_bus.subscribe("BSP_CHARGER_EVENT");
    event_bus.start();
    state.charge_limit.start(charger_rx);
    usb::enforce_usb_mode_on_boot();
    state.lan.recover();
    server::start(threads.clamp(1, 16), state);
}

/// Read `export KEY='value'` out of the startup script.
fn read_startup_export(key: &str) -> Option<String> {
    let script = std::fs::read_to_string(STARTUP_SCRIPT).ok()?;
    let prefix = format!("export {key}=");
    script.lines().find_map(|line| {
        line.strip_prefix(&prefix)
            .map(|v| v.trim_matches(|c| c == '\'' || c == '"').to_string())
    })
}

/// One-shot cleanup for features removed from the agent (DoH proxy, SMS
/// forwarder, job scheduler).
///
/// The DoH part matters: enabling DoH pointed dnsmasq at the agent's own
/// resolver on 127.0.0.1:5353, and the module that undid that is gone. Without
/// this, a device that had DoH enabled would come back up forwarding DNS to a
/// port nothing listens on. Safe to run when DoH was never enabled — the config
/// file only exists if it was configured at least once.
fn migrate_drop_removed_features() {
    const DOH_CONFIG: &str = "/data/local/tmp/doh_config.json";

    if std::path::Path::new(DOH_CONFIG).is_file()
        && legacy_doh_redirect(
            ubus::uci_get("dhcp.lan_dns.server").ok().as_deref(),
            ubus::uci_get("dhcp.lan_dns.noresolv").ok().as_deref(),
        )
    {
        eprintln!("[migrate] DoH was configured on this device — restoring dnsmasq defaults");
        let result = std::process::Command::new("sh")
            .args([
                "-c",
                "rm -f /tmp/dnsmasq.d/doh.conf && \
                 uci delete dhcp.lan_dns.server && \
                 uci delete dhcp.lan_dns.noresolv && \
                 uci commit dhcp && \
                 /etc/init.d/dnsmasq restart",
            ])
            .bounded_output();
        if result.is_ok_and(|output| output.status.success()) {
            let _ = std::fs::remove_file(DOH_CONFIG);
        }
    }

    for orphan in [
        "/data/local/tmp/sms_forward.json",
        "/data/local/tmp/sms_forward_state.json",
        "/data/local/tmp/scheduler.json",
    ] {
        let _ = std::fs::remove_file(orphan);
    }
}

// A leftover legacy settings file does not authorise resetting unrelated DNS.
fn legacy_doh_redirect(server: Option<&str>, noresolv: Option<&str>) -> bool {
    matches!(server, Some("127.0.0.1#5353") | Some("127.0.0.1:5353")) && noresolv == Some("1")
}

#[cfg(test)]
mod startup_tests {
    #[test]
    fn removed_doh_cleanup_requires_its_exact_active_redirect() {
        assert!(super::legacy_doh_redirect(Some("127.0.0.1#5353"), Some("1")));
        for server in [None, Some("8.8.8.8"), Some("127.0.0.1#5353 8.8.8.8"), Some("127.0.0.1#53")] {
            assert!(!super::legacy_doh_redirect(server, Some("1")));
        }
        assert!(!super::legacy_doh_redirect(Some("127.0.0.1#5353"), None));
        assert!(!super::legacy_doh_redirect(Some("127.0.0.1#5353"), Some("0")));
    }
}
