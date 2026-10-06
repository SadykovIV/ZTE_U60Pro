use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tiny_http::{Header, Method, Request, Response, Server};

use crate::at_cmd;
use crate::cell;
use crate::connection_logger;
use crate::device_ext;
use crate::handlers::{self, AppState};
use crate::network_ext;
use crate::router;
use crate::signal_logger;
use crate::sim;
use crate::sms;
use crate::usb;
use crate::wifi;

/// How long a worker blocks before re-checking whether the listener died.
/// Also bounds how long a rebuild waits for the other workers to drain.
const WORKER_POLL: Duration = Duration::from_millis(500);
const RETRY_MIN: Duration = Duration::from_secs(1);
const RETRY_MAX: Duration = Duration::from_secs(30);

pub fn start(threads: usize, state: Arc<AppState>) {
    // Seed the CPU tracker with a baseline (speed tracker self-seeds)
    state.cpu.seed();

    // tiny_http's accept thread exits permanently on its first accept() error
    // — plausible here via EMFILE, ENOBUFS under memory pressure, or interface
    // churn. That used to leave every worker blocked forever on a listener that
    // would never yield another request, with the process still alive and
    // nothing to restart it. Supervise instead: a worker that sees the failure
    // flags it, all workers drain, and we rebuild the listener.
    let mut retry = RETRY_MIN;
    loop {
        let bind = state.binding.address();
        let generation = state.binding.generation.load(Ordering::Acquire);
        let server = match Server::http(&bind) {
            Ok(s) => {
                retry = RETRY_MIN;
                Arc::new(s)
            }
            Err(e) => {
                eprintln!(
                    "[server] bind {bind} failed: {e}; retrying in {}s",
                    retry.as_secs()
                );
                std::thread::sleep(retry);
                retry = (retry * 2).min(RETRY_MAX);
                continue;
            }
        };

        let dead = Arc::new(AtomicBool::new(false));
        let mut handles = Vec::new();

        for _ in 0..threads {
            let server = Arc::clone(&server);
            let state = Arc::clone(&state);
            let dead = Arc::clone(&dead);
            handles.push(std::thread::spawn(move || loop {
                if state.binding.generation.load(Ordering::Acquire) != generation {
                    dead.store(true, Ordering::Relaxed);
                }
                if dead.load(Ordering::Relaxed) {
                    return;
                }
                match server.recv_timeout(WORKER_POLL) {
                    Ok(Some(request)) => handle_request(request, &state),
                    // Idle timeout — loop round and re-check `dead`.
                    Ok(None) => {}
                    Err(e) => {
                        eprintln!("[server] listener failed: {e}");
                        dead.store(true, Ordering::Relaxed);
                        return;
                    }
                }
            }));
        }

        for h in handles {
            let _ = h.join();
        }

        eprintln!("[server] listener down, rebuilding in {}s", retry.as_secs());
        std::thread::sleep(retry);
        retry = (retry * 2).min(RETRY_MAX);
    }
}

const DESTRUCTIVE_PATHS: &[&str] = &[
    "/api/device/reboot",
    "/api/device/shutdown",
    "/api/system/kill-bloat",
];

fn cors_headers(origin: Option<&str>) -> Vec<Header> {
    let allowed = origin
        .and_then(|o| is_lan_origin(o).then_some(o))
        .unwrap_or("");
    vec![
        Header::from_bytes("Access-Control-Allow-Origin", allowed).unwrap(),
        Header::from_bytes(
            "Access-Control-Allow-Methods",
            "GET, POST, PUT, DELETE, OPTIONS",
        )
        .unwrap(),
        Header::from_bytes(
            "Access-Control-Allow-Headers",
            "Authorization, Content-Type, X-Confirm",
        )
        .unwrap(),
        Header::from_bytes("Access-Control-Max-Age", "86400").unwrap(),
    ]
}

fn is_lan_origin(origin: &str) -> bool {
    if !origin.starts_with("http://") {
        return false;
    }
    let host = &origin[7..];
    let host = host.split(':').next().unwrap_or(host);
    if host == "localhost" || host == "127.0.0.1" || host == "::1" {
        return true;
    }
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    let octets: Vec<u8> = parts.iter().filter_map(|p| p.parse().ok()).collect();
    if octets.len() != 4 {
        return false;
    }
    octets[0] == 10
        || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
        || (octets[0] == 192 && octets[1] == 168)
}

fn needs_auth(method: &Method, path: &str) -> bool {
    path != "/api/auth/login" && !(*method == Method::Post && path == "/api/router/lan/confirm")
}

fn handle_request(mut request: Request, state: &AppState) {
    let method = request.method().clone();
    let url = request.url().to_string();
    let path = url.split('?').next().unwrap_or(&url).to_string();
    let origin = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("Origin"))
        .map(|h| h.value.as_str().to_string());
    let origin_ref = origin.as_deref();
    let client_ip = request
        .remote_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_default();
    let user_agent = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("User-Agent"))
        .map(|h| h.value.as_str().to_string());
    let user_agent_ref = user_agent.as_deref();

    if method == Method::Options {
        let mut response = Response::empty(200);
        for h in cors_headers(origin_ref) {
            response = response.with_header(h);
        }
        let _ = request.respond(response);
        return;
    }

    if !state.mode.permits(&method, &path) {
        let (status, body) = crate::agent_mode::denied();
        respond(request, status, body, origin_ref);
        return;
    }

    // The LAN confirmation nonce authorises only the pending change. It lets
    // the browser prove connectivity without sending its session bearer token
    // to a new IP that might already be occupied by another host.
    if needs_auth(&method, &path) {
        let authorized = request
            .headers()
            .iter()
            .find(|h| h.field.as_str().to_ascii_lowercase() == "authorization")
            .and_then(|h| h.value.as_str().strip_prefix("Bearer "))
            .map(|token| state.auth.validate(token))
            .unwrap_or(false);

        if !state.auth.has_password() {
            respond(
                request,
                403,
                json!({"ok": false, "error": "no password configured. Set ZTE_AGENT_PASSWORD environment variable."}),
                origin_ref,
            );
            return;
        } else if !authorized {
            respond(
                request,
                401,
                json!({"ok": false, "error": "unauthorized"}),
                origin_ref,
            );
            return;
        }
    }

    if DESTRUCTIVE_PATHS.contains(&path.as_str()) {
        let confirmed = request
            .headers()
            .iter()
            .any(|h| h.field.equiv("X-Confirm") && h.value.as_str() == "true");
        if !confirmed {
            respond(
                request,
                400,
                json!({"ok": false, "error": "destructive action requires X-Confirm: true header"}),
                origin_ref,
            );
            return;
        }
    }

    if method == Method::Get {
        let download = match (&method, path.as_str()) {
            (&Method::Get, "/api/logger/signal/download") => {
                Some((signal_logger::LOG_PATH, "signal_log.csv"))
            }
            (&Method::Get, "/api/logger/connection/download") => {
                Some((connection_logger::LOG_PATH, "connection_log.csv"))
            }
            _ => None,
        };
        if let Some((path, name)) = download {
            match crate::logging::open_download(path) {
                Ok((file, len)) => {
                    use std::io::Read;
                    let mut response = Response::new(
                        tiny_http::StatusCode(200),
                        vec![],
                        file.take(len),
                        Some(len as usize),
                        None,
                    )
                    .with_header(
                        Header::from_bytes("Content-Type", "text/csv; charset=utf-8").unwrap(),
                    )
                    .with_header(
                        Header::from_bytes(
                            "Content-Disposition",
                            format!("attachment; filename=\"{name}\""),
                        )
                        .unwrap(),
                    )
                    .with_header(Header::from_bytes("Cache-Control", "no-store").unwrap());
                    for header in cors_headers(origin_ref) {
                        response = response.with_header(header);
                    }
                    let _ = request.respond(response);
                }
                Err(_) => respond(
                    request,
                    404,
                    json!({"ok": false, "error": "no readable log file"}),
                    origin_ref,
                ),
            }
            return;
        }
    }

    let mut body = Vec::new();
    let mut reader = request.as_reader();
    let mut limited = std::io::Read::take(&mut reader, 1024 * 1024 + 1);
    if let Err(e) = std::io::Read::read_to_end(&mut limited, &mut body) {
        respond(
            request,
            400,
            json!({"ok": false, "error": format!("failed to read body: {e}")}),
            origin_ref,
        );
        return;
    }

    if body.len() > 1024 * 1024 {
        respond(
            request,
            413,
            json!({"ok": false, "error": "request body exceeds 1 MiB"}),
            origin_ref,
        );
        return;
    }

    #[cfg(feature = "esim")]
    if path.starts_with("/api/esim/") {
        // The normal authentication check above has already accepted this token.
        // Keep job ownership separate from the public route dispatcher.
        let owner = request.headers().iter()
            .find(|h| h.field.equiv("Authorization"))
            .and_then(|h| h.value.as_str().strip_prefix("Bearer ")).unwrap_or_default();
        let (status, value) = crate::esim::web::route(&state.esim_jobs, &method, &path, owner, &body);
        respond(request, status, value, origin_ref);
        return;
    }

    let (status, body_json) = route(&method, &path, state, &body, &client_ip, user_agent_ref);
    respond(request, status, body_json, origin_ref);
}

pub fn route(
    method: &Method,
    path: &str,
    state: &AppState,
    body: &[u8],
    client_ip: &str,
    user_agent: Option<&str>,
) -> (u16, Value) {
    // Keep this gate in the dispatcher as well: tests and internal callers
    // must not bypass the HTTP entry point.
    if !state.mode.permits(method, path) { return crate::agent_mode::denied(); }
    let result = match (method, path) {
        // Auth
        (&Method::Post, "/api/auth/login") => handlers::login(state, body, client_ip, user_agent),
        // Batch — the dashboard's heartbeat; feeds Home, Signal and Modem/Data
        (&Method::Get, "/api/dashboard") => handlers::dashboard(state),
        // Device / system
        (&Method::Get, "/api/health") => {
            let (status, mut body) = agent_health();
            body["data"]["mode"] = json!(state.mode.name());
            (status, body)
        },
        (&Method::Get, "/api/capabilities") => (200, state.mode.capabilities()),
        (&Method::Get, "/api/device") => handlers::device(state),
        (&Method::Get, "/api/cpu") => handlers::cpu(state),
        (&Method::Get, "/api/memory") => handlers::memory(state),
        (&Method::Get, "/api/system/top") => handlers::system_top(state),
        (&Method::Post, "/api/system/kill-bloat") => handlers::system_kill_bloat(state, body),
        (&Method::Post, "/api/system/restart-agent") => device_ext::agent_restart(state),
        (&Method::Post, "/api/device/reboot") => device_ext::device_reboot(state),
        (&Method::Post, "/api/device/shutdown") => device_ext::device_shutdown(state),
        (&Method::Get, "/api/device/battery-info") => network_ext::network_battery_ubus(state),
        (&Method::Get, "/api/device/thermal/all") => device_ext::device_thermal_all(state),
        (&Method::Get, "/api/device/battery/detail") => device_ext::device_battery_detail(state),
        (&Method::Get, "/api/device/charger") => device_ext::device_charger(state),
        (&Method::Get, "/api/device/charge-control") => device_ext::charge_control_get(state),
        (&Method::Put, "/api/device/charge-control") => device_ext::charge_control_set(state, body),
        // Network
        (&Method::Get, "/api/network/clients") => network_ext::network_clients(state),
        // WiFi
        (&Method::Get, "/api/wifi/status") => wifi::wifi_status(state),
        (&Method::Put, "/api/wifi/settings") => wifi::wifi_set(state, body),
        // Modem
        (&Method::Put, "/api/data-usage/reset-day") => {
            handlers::data_usage_reset_day_set(state, body)
        }
        (&Method::Get, "/api/modem/capabilities") => cell::modem_capabilities(state),
        (&Method::Put, "/api/modem/network-mode") => cell::modem_network_mode_set(state, body),
        // SMS
        (&Method::Get, "/api/sms/capabilities") => sms::sms_capabilities(state),
        (&Method::Post, "/api/sms/list") => sms::sms_list(state, body),
        (&Method::Post, "/api/sms/send") => sms::sms_send(state, body),
        (&Method::Post, "/api/sms/delete") => sms::sms_delete(state, body),
        (&Method::Post, "/api/sms/read") => sms::sms_mark_read(state, body),
        // SIM
        (&Method::Get, "/api/sim/info") => sim::sim_info(state),
        (&Method::Get, "/api/sim/imei") => sim::sim_imei(state),
        // Cell / band lock
        (&Method::Post, "/api/cell/lock/nr") => cell::cell_lock_nr(state, body),
        (&Method::Post, "/api/cell/lock/lte") => cell::cell_lock_lte(state, body),
        (&Method::Post, "/api/cell/lock/reset") => cell::cell_lock_reset(state),
        (&Method::Post, "/api/cell/band/nr") => cell::cell_band_nr(state, body),
        (&Method::Post, "/api/cell/band/lte") => cell::cell_band_lte(state, body),
        (&Method::Post, "/api/cell/band/reset") => cell::cell_band_reset(state),
        // Router
        (&Method::Get, "/api/router/dns") => router::router_dns_get(state),
        (&Method::Put, "/api/router/dns") => router::router_dns_set(state, body),
        (&Method::Get, "/api/router/lan") => router::router_lan_get(state),
        (&Method::Put, "/api/router/lan") => router::router_lan_set(state, body),
        (&Method::Post, "/api/router/lan/confirm") => router::router_lan_confirm(state, body),
        (&Method::Get, "/api/router/apn/mode") => router::router_apn_mode_get(state),
        (&Method::Put, "/api/router/apn/mode") => router::router_apn_mode_set(state, body),
        (&Method::Get, "/api/router/apn/profiles") => router::router_apn_profiles_get(state),
        (&Method::Post, "/api/router/apn/profiles") => router::router_apn_profiles_add(state, body),
        (&Method::Post, "/api/router/apn/profiles/delete") => {
            router::router_apn_profiles_delete(state, body)
        }
        (&Method::Post, "/api/router/apn/profiles/activate") => {
            router::router_apn_profiles_activate(state, body)
        }
        // USB
        (&Method::Get, "/api/usb/status") => usb::usb_status(state),
        (&Method::Put, "/api/usb/mode") => usb::usb_mode_set(state, body),
        (&Method::Put, "/api/usb/default") => usb::usb_default_set(state, body),
        (&Method::Put, "/api/usb/powerbank") => usb::usb_powerbank_set(state, body),
        (&Method::Get, "/api/vpn/status") => crate::vpn::status(),
        (&Method::Post, "/api/vpn/request") => crate::vpn::request(body),
        // Shared IPv4 TTL settings (native application + dashboard)
        (&Method::Get, "/api/ttl/status") => crate::ttl::status(),
        (&Method::Put, "/api/ttl/set") => crate::ttl::set(body),
        (&Method::Delete, "/api/ttl/clear") => crate::ttl::clear(),
        // AT console
        (&Method::Post, "/api/at/send") => at_console(state, body),
        (&Method::Get, "/api/at/port") => at_port(state),
        // Signal logger
        (&Method::Post, "/api/logger/signal/start") => signal_logger::start_logging(state, body),
        (&Method::Post, "/api/logger/signal/stop") => signal_logger::stop_logging(state),
        (&Method::Get, "/api/logger/signal/status") => signal_logger::status(state),
        // Connection logger
        (&Method::Post, "/api/logger/connection/start") => {
            connection_logger::start_logging(state, body)
        }
        (&Method::Post, "/api/logger/connection/stop") => connection_logger::stop_logging(state),
        (&Method::Get, "/api/logger/connection/status") => connection_logger::status(state),
        // Fallback
        _ => (404, json!({"ok": false, "error": "not found"})),
    };
    if state.mode == crate::agent_mode::AgentMode::Discovery && method == &Method::Get
        && matches!(path, "/api/sim/info" | "/api/sim/imei" | "/api/router/dns" |
            "/api/router/apn/mode" | "/api/router/apn/profiles" | "/api/device/charger")
        && result.0 == 200 && !result.1["data"].as_object().is_some_and(|v| !v.is_empty()) {
        return (503, json!({"ok": false, "state": "not-assessed", "error": "The requested device information is not available"}));
    }
    result
}

// --- AT console ---

fn at_console(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let command = match parsed["command"].as_str() {
        Some(c) if !c.is_empty() => c,
        _ => return (400, json!({"ok": false, "error": "missing 'command'"})),
    };
    let timeout = parsed["timeout"].as_u64().unwrap_or(2).min(30);

    if !is_at_command_allowed(command) {
        return (
            403,
            json!({"ok": false, "error": "command not allowed. Only read-only AT commands are permitted."}),
        );
    }

    match at_cmd::send(&state.at_port, command, timeout) {
        Ok(resp) => (200, json!({"ok": true, "data": {"response": resp.trim()}})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

const AT_BLOCKED_PREFIXES: &[&str] = &[
    "AT+CFUN",
    "AT^",
    "AT$QCRMCALL",
    "AT+CLCK",
    "AT+CMGD",
    "AT+CMGF=1;+CMGS",
    "AT+CGDCONT=",
    "AT+CGACT=",
];

const AT_ALLOWED_EXACT: &[&str] = &[
    "AT",
    "ATI",
    "AT+CSQ",
    "AT+COPS?",
    "AT+COPS=?",
    "AT+CGDCONT?",
    "AT+CREG?",
    "AT+CGREG?",
    "AT+CEREG?",
    "AT+CGPADDR",
    "AT+CGACT?",
    "AT+CLAC",
    "AT+CGSN",
    "AT+CGMI",
    "AT+CGMM",
    "AT+CGMR",
    "AT+QENG=\"SERVINGCELL\"",
    "AT+QNWINFO",
    "AT+QRSRP",
    "AT+QRSRQ",
    "AT+QINISTAT",
    "AT+QSPN",
    "AT+QCIDINCOMING",
    "AT+CGCONTRDP",
];

fn is_at_command_allowed(cmd: &str) -> bool {
    let upper = cmd.trim().to_uppercase();
    if upper.is_empty() {
        return false;
    }
    for prefix in AT_BLOCKED_PREFIXES {
        if upper.starts_with(prefix) {
            return false;
        }
    }
    AT_ALLOWED_EXACT.contains(&upper.as_str())
}

/// GET /api/at/port — report the detected AT serial port (if any)
fn at_port(state: &AppState) -> (u16, Value) {
    match state.at_port.detect_serialized() {
        Some(port) => (
            200,
            json!({"ok": true, "data": {"port": port, "available": true}}),
        ),
        None => (
            200,
            json!({"ok": true, "data": {"port": null, "available": false}}),
        ),
    }
}

fn agent_health() -> (u16, Value) {
    (
        200,
        json!({"ok": true, "data": {"status": "ok", "version": crate::AGENT_VERSION, "ttl_schema_version": 2}}),
    )
}

fn respond(request: Request, status: u16, body: Value, origin: Option<&str>) {
    let body_str = serde_json::to_string(&body).unwrap_or_default();
    let content_type = Header::from_bytes("Content-Type", "application/json").unwrap();
    let mut response = Response::from_string(body_str)
        .with_status_code(status)
        .with_header(content_type)
        .with_header(Header::from_bytes("Cache-Control", "no-store").unwrap());
    for h in cors_headers(origin) {
        response = response.with_header(h);
    }
    let _ = request.respond(response);
}

#[cfg(test)]
mod tests {
    use super::{agent_health, is_at_command_allowed};

    #[test]
    fn direct_dispatch_cannot_bypass_discovery_mode() {
        let state = crate::handlers::AppState::with_mode(crate::agent_mode::AgentMode::Discovery);
        // Dispatch must reject these without invoking external tools or sysfs writes.
        for (method, path) in [(tiny_http::Method::Post,"/api/router/lan/confirm"),
            (tiny_http::Method::Put,"/api/device/charge-control"),
            (tiny_http::Method::Get,"/api/modem/capabilities"),
            (tiny_http::Method::Post,"/api/esim/enable")] {
            let (status,body)=super::route(&method,path,&state,b"{}","127.0.0.1",None);
            assert_eq!(status,403);assert_eq!(body["code"],"CAPABILITY_NOT_ASSESSED");
        }
        let (status,body)=super::route(&tiny_http::Method::Get,"/api/health",&state,b"","127.0.0.1",None);
        assert_eq!(status,200);assert_eq!(body["data"]["mode"],"discovery");
        let (status,body)=super::route(&tiny_http::Method::Get,"/api/capabilities",&state,b"","127.0.0.1",None);
        assert_eq!(status,200);assert_eq!(body["data"]["hardware_read_only"],true);
        state.auth.set_password("fixture-password");
        let (status,body)=super::route(&tiny_http::Method::Post,"/api/auth/login",&state,br#"{"password":"fixture-password"}"#,"127.0.0.1",None);
        assert_eq!(status,200);assert!(body["data"]["token"].as_str().is_some());
    }
    #[test]
    fn every_esim_job_route_requires_normal_bearer_auth() {
        for path in ["/api/esim/capabilities", "/api/esim/jobs", "/api/esim/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
            assert!(super::needs_auth(&tiny_http::Method::Get,path));
            assert!(super::needs_auth(&tiny_http::Method::Post,path));
        }
    }

    fn fake_output(body: &str, success: bool) -> std::io::Result<std::process::Output> {
        use std::os::unix::process::ExitStatusExt;
        Ok(std::process::Output { status: std::process::ExitStatus::from_raw(if success {0} else {256}),
            stdout: body.as_bytes().to_vec(), stderr: Vec::new() })
    }
    fn read_command(cmd: &std::process::Command) -> std::io::Result<std::process::Output> {
        let args: Vec<_> = cmd.get_args().map(|v| v.to_str().unwrap()).collect();
        match cmd.get_program().to_str().unwrap() {
            "ubus" => {
                assert_eq!(args[0], "call");
                let pair = (args[1], args[2]);
                assert!([("zte_nwinfo_api", "nwinfo_get_netinfo"), ("network.interface.zte_wan", "status"),
                    ("network.interface.zte_wan6", "status"), ("zwrt_bsp.thermal", "get_cpu_temp"),
                    ("zwrt_data", "get_wwandst"), ("zwrt_data", "get_wwandst_clearday"),
                    ("zwrt_bsp.battery", "list"), ("zwrt_bsp.charger", "list"),
                    ("luci-rpc", "getDHCPLeases"), ("zwrt_wlan", "report"),
                    ("zwrt_zte_mdm.api", "get_sim_info"), ("zwrt_zte_mdm.api", "get_imei"),
                    ("zwrt_router.api", "router_get_dns_para"), ("zwrt_apn_object", "get_apn_mode"),
                    ("zwrt_apn_object", "get_manu_apn_list"), ("zwrt_bsp.usb", "list")].contains(&pair), "unexpected RPC {pair:?}");
                fake_output(if pair.1 == "getDHCPLeases" {r#"{"dhcp_leases":[]}"#} else {"{}"}, true)
            },
            "uci" => {
                assert!(args[0] == "get" || args[0] == "show");
                fake_output(if args[0] == "show" {"wireless.wifi0=wifi-device\nwireless.main_2g=wifi-iface\n"} else {"3600"}, true)
            },
            "iw" => { assert!(args.ends_with(&["info"]) || args.ends_with(&["station", "dump"])); fake_output("", true) },
            "bridge" => { assert_eq!(args, ["fdb", "show", "br", "br-lan"]); fake_output("", true) },
            "ethtool" => fake_output("", true),
            other => panic!("unexpected command {other}"),
        }
    }
    #[test]
    fn discovery_read_dispatch_calls_only_audited_read_commands_and_keeps_auth() {
        crate::process::with_commands(read_command, || {
            let state = crate::handlers::AppState::with_mode(crate::agent_mode::AgentMode::Discovery);
            for route in crate::agent_mode::SAFE_READS {
                let path = format!("/api/{route}");
                assert!(super::needs_auth(&tiny_http::Method::Get, &path));
                let (status, body) = super::route(&tiny_http::Method::Get, &path, &state, b"", "127.0.0.1", None);
                assert_ne!(status, 403, "{path}");
                assert_ne!(status, 404, "{path}");
                assert!(status == 200 || status == 503, "{path} {body}");
            }
        });
    }
    #[test]
    fn discovery_wifi_sources_and_station_failures_are_not_false_empty_success() {
        crate::process::with_commands(|_| fake_output("", false), || {
            let state = crate::handlers::AppState::with_mode(crate::agent_mode::AgentMode::Discovery);
            let (code, value) = crate::wifi::wifi_status(&state);
            assert_eq!(code, 503); assert_eq!(value["state"], "not-assessed");
            let (code, value) = crate::network_ext::network_clients(&state);
            if std::path::Path::new("/proc/net/arp").is_file() {
                assert_eq!(code, 200); assert_eq!(value["data"]["state"], "partial");
                assert_eq!(value["data"]["sources"]["wifi_2g"], false);
            } else { assert_eq!(code, 503); assert_eq!(value["state"], "not-assessed"); }
        });
        crate::process::with_commands(|cmd| {
            if cmd.get_program() == "iw" { fake_output("", false) } else { read_command(cmd) }
        }, || {
            let state = crate::handlers::AppState::with_mode(crate::agent_mode::AgentMode::Discovery);
            let (code, value) = crate::wifi::wifi_status(&state);
            assert_eq!(code, 200); assert_eq!(value["data"]["station_counts_state"], "not-assessed");
            assert!(value["data"]["clients_total"].is_null());
            assert!(value["data"]["clients_2g"].is_null());
        });
    }
    #[test]
    fn discovery_vendor_method_failure_remains_an_error_without_any_write_fallback() {
        crate::process::with_commands(|cmd| {
            assert_eq!(cmd.get_program(), "ubus");
            assert_eq!(cmd.get_args().next().unwrap(), "call");
            fake_output("", false)
        }, || {
            let state = crate::handlers::AppState::with_mode(crate::agent_mode::AgentMode::Discovery);
            for path in ["/api/sim/info", "/api/sim/imei", "/api/router/dns", "/api/router/apn/mode",
                "/api/router/apn/profiles", "/api/usb/status", "/api/device/charger", "/api/device/battery-info"] {
                let (code,value) = super::route(&tiny_http::Method::Get, path, &state, b"", "127.0.0.1", None);
                assert_eq!(code, 503, "{path}"); assert_eq!(value["ok"], false);
            }
        });
        for output in ["", "null", "{}", "[]", "malformed"] {
            crate::process::with_commands(move |_| fake_output(output, true), || {
                let state = crate::handlers::AppState::with_mode(crate::agent_mode::AgentMode::Discovery);
                let (code, value) = super::route(&tiny_http::Method::Get, "/api/sim/info", &state, b"", "127.0.0.1", None);
                assert_eq!(code, 503); assert_eq!(value["ok"], false);
            });
        }
    }

    #[test]
    fn health_exposes_release_and_ttl_contract() {
        let (status, body) = agent_health();
        assert_eq!(status, 200);
        assert_eq!(body["data"]["version"], crate::AGENT_VERSION);
        assert_eq!(body["data"]["ttl_schema_version"], 2);
    }

    #[test]
    fn at_allowlist_is_exact_and_read_only() {
        assert!(is_at_command_allowed("AT"));
        assert!(is_at_command_allowed("at+csq"));
        assert!(is_at_command_allowed("AT+QENG=\"servingcell\""));
        assert!(!is_at_command_allowed("AT+CSQ=1"));
        assert!(!is_at_command_allowed("AT+FOO"));
        assert!(!is_at_command_allowed("AT+CFUN=1"));
        assert!(!is_at_command_allowed("AT^RESET"));
    }
}
