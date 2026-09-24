use serde_json::{json, Value};
use std::collections::BTreeMap;

pub type Result<T> = std::result::Result<T, &'static str>;

fn decode(s: &str) -> Result<String> {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err("VPN_INVALID_URI");
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).map_err(|_| "VPN_INVALID_URI")?;
            out.push(u8::from_str_radix(hex, 16).map_err(|_| "VPN_INVALID_URI")?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    let value = String::from_utf8(out).map_err(|_| "VPN_INVALID_URI")?;
    if value.chars().any(char::is_control) {
        return Err("VPN_INVALID_URI");
    }
    Ok(value)
}

pub fn valid_id(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
pub fn name(s: &str) -> Result<String> {
    let s = s.trim();
    if s.is_empty() || s.chars().count() > 64 || s.chars().any(char::is_control) {
        return Err("VPN_INVALID_NAME");
    }
    Ok(s.into())
}
/// A display-name edit must not rewrite the imported URI or live proxy settings.
pub fn rename(p: &mut Value, label: &str) -> Result<()> {
    let label = name(label)?;
    if !p.is_object() {
        return Err("VPN_INVALID_STATE");
    }
    p["name"] = json!(label);
    Ok(())
}
fn key_length(s: &str) -> Result<usize> {
    let data = s.trim_end_matches('=');
    if s.len() - data.len() > 2
        || data.len() % 4 == 1
        || !data
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("VPN_INVALID_KEY");
    }
    Ok(data.len() * 6 / 8)
}

/// Only proxy fields are accepted. Imports cannot inject routes, listeners,
/// scripts, providers, DIRECT fallbacks or external configuration URLs.
pub fn parse(uri: &str, label: Option<&str>) -> Result<(String, Value, Vec<&'static str>)> {
    if uri.len() > 32768 {
        return Err("VPN_PROFILE_TOO_LARGE");
    }
    let uri = uri
        .trim()
        .replace("\\:", ":")
        .replace("\\@", "@")
        .replace("\\_", "_");
    let body = uri.strip_prefix("vless://").ok_or("VPN_VLESS_ONLY")?;
    let (body, fragment) = body.split_once('#').unwrap_or((body, "VPN"));
    let (authority, query) = body.split_once('?').unwrap_or((body, ""));
    let (uuid, address) = authority.split_once('@').ok_or("VPN_INVALID_URI")?;
    let uuid = decode(uuid)?;
    if !valid_id(&uuid) {
        return Err("VPN_INVALID_UUID");
    }
    let (server, port) = address.rsplit_once(':').ok_or("VPN_INVALID_URI")?;
    let server = server.trim_start_matches('[').trim_end_matches(']');
    let port: u16 = port.parse().map_err(|_| "VPN_INVALID_PORT")?;
    if port == 0 {
        return Err("VPN_INVALID_PORT");
    }
    if server.is_empty()
        || server.len() > 253
        || !server
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-_:".contains(&c))
    {
        return Err("VPN_INVALID_SERVER");
    }
    if server.contains(':') && server.parse::<std::net::Ipv6Addr>().is_err() {
        return Err("VPN_INVALID_SERVER");
    }
    let mut q = BTreeMap::new();
    let known = [
        "security",
        "pbk",
        "sid",
        "spx",
        "sni",
        "fp",
        "type",
        "encryption",
        "host",
        "path",
        "mode",
        "extra",
        "x_padding_bytes",
        "flow",
        "alpn",
        "serviceName",
        "authority",
        "packetEncoding",
        "allowInsecure",
    ];
    if !query.is_empty() {
        for pair in query.split('&') {
            let (k, v) = pair.split_once('=').ok_or("VPN_INVALID_URI")?;
            let k = decode(k)?;
            let v = decode(v)?;
            if !known.contains(&k.as_str()) {
                return Err("VPN_UNSUPPORTED_OPTION");
            }
            if q.insert(k, v).is_some() {
                return Err("VPN_DUPLICATE_OPTION");
            }
        }
    }
    let get = |key: &str, default: &str| q.get(key).cloned().unwrap_or_else(|| default.into());
    let title = name(label.unwrap_or(&decode(fragment)?))?;
    let security = get("security", "none");
    if !["none", "tls", "reality"].contains(&security.as_str()) {
        return Err("VPN_UNSUPPORTED_SECURITY");
    }
    if !["0", "false"].contains(&get("allowInsecure", "false").as_str()) {
        return Err("VPN_UNSUPPORTED_OPTION");
    }
    let network = get("type", "tcp");
    if !["tcp", "xhttp", "ws", "grpc"].contains(&network.as_str()) {
        return Err("VPN_UNSUPPORTED_TRANSPORT");
    }
    let packet = get("packetEncoding", "xudp");
    if !["xudp", "packetaddr", ""].contains(&packet.as_str()) {
        return Err("VPN_UNSUPPORTED_OPTION");
    }
    let mut proxy = json!({"name":"VPN","type":"vless","server":server,"port":port,"uuid":uuid.to_lowercase(),"udp":true,"packet-encoding":packet,"network":network,"tls":security!="none","skip-cert-verify":false});
    let encryption = get("encryption", "none");
    if encryption != "none" && !encryption.is_empty() {
        let parts: Vec<_> = encryption.split('.').collect();
        if parts.len() < 4
            || parts[0] != "mlkem768x25519plus"
            || !["native", "xorpub", "random"].contains(&parts[1])
            || !["0rtt", "1rtt"].contains(&parts[2])
        {
            return Err("VPN_UNSUPPORTED_ENCRYPTION");
        }
        let keys: Vec<_> = parts[3..].iter().filter(|s| s.len() >= 20).collect();
        if keys.is_empty() || keys.iter().any(|k| !matches!(key_length(k), Ok(32 | 1184))) {
            return Err("VPN_INVALID_KEY");
        }
        proxy["encryption"] = json!(encryption);
    }
    if security != "none" {
        proxy["servername"] = json!(get("sni", server));
        proxy["client-fingerprint"] = json!(get("fp", "chrome"));
        if let Some(alpn) = q.get("alpn") {
            proxy["alpn"] = json!(alpn.split(',').collect::<Vec<_>>());
        }
    }
    if security == "reality" {
        let key = get("pbk", "");
        let sid = get("sid", "");
        if key_length(&key)? != 32
            || sid.len() > 16
            || sid.len() % 2 != 0
            || !sid.bytes().all(|c| c.is_ascii_hexdigit())
        {
            return Err("VPN_INVALID_KEY");
        }
        proxy["reality-opts"] = json!({"public-key":key,"short-id":sid});
    } else if q.contains_key("pbk") || q.contains_key("sid") {
        return Err("VPN_CONFLICTING_OPTION");
    }
    if let Some(flow) = q.get("flow").filter(|s| !s.is_empty()) {
        if flow != "xtls-rprx-vision" || network != "tcp" || security == "none" {
            return Err("VPN_CONFLICTING_OPTION");
        }
        proxy["flow"] = json!(flow);
    }
    let path = get("path", "/");
    if path.len() > 2048 || !path.starts_with('/') {
        return Err("VPN_INVALID_PATH");
    }
    match network.as_str() {
        "xhttp" => {
            let extra: Value =
                serde_json::from_str(&get("extra", "{}")).map_err(|_| "VPN_INVALID_EXTRA")?;
            let extra = extra.as_object().ok_or("VPN_INVALID_EXTRA")?;
            if extra
                .keys()
                .any(|k| !["mode", "xPaddingBytes"].contains(&k.as_str()))
            {
                return Err("VPN_UNSUPPORTED_OPTION");
            }
            let mode = get(
                "mode",
                extra.get("mode").and_then(Value::as_str).unwrap_or("auto"),
            );
            if !["auto", "stream-one", "stream-up", "packet-up"].contains(&mode.as_str())
                || extra.get("mode").is_some_and(|v| v.as_str() != Some(&mode))
            {
                return Err("VPN_CONFLICTING_OPTION");
            }
            if extra.get("xPaddingBytes").is_some_and(|v| !v.is_string()) {
                return Err("VPN_INVALID_EXTRA");
            }
            let extra_padding = extra.get("xPaddingBytes").and_then(Value::as_str);
            let link_padding = q.get("x_padding_bytes").map(String::as_str);
            if matches!((extra_padding, link_padding), (Some(a), Some(b)) if a != b) {
                return Err("VPN_CONFLICTING_OPTION");
            }
            let padding = link_padding.or(extra_padding).unwrap_or("100-1000");
            if !padding.bytes().all(|c| c.is_ascii_digit() || c == b'-') || padding.len() > 30 {
                return Err("VPN_INVALID_EXTRA");
            }
            proxy["xhttp-opts"] = json!({"host":get("host",server),"path":path,"mode":mode,"x-padding-bytes":padding});
        }
        "ws" => {
            proxy["ws-opts"] = json!({"path":path,"headers":{"Host":get("host",server)}});
        }
        "grpc" => {
            proxy["grpc-opts"] = json!({"grpc-service-name":get("serviceName","")});
            if q.contains_key("authority") {
                return Err("VPN_UNSUPPORTED_OPTION");
            }
        }
        _ => {
            if q.contains_key("extra") || q.contains_key("host") || q.contains_key("path") {
                return Err("VPN_UNSUPPORTED_OPTION");
            }
        }
    }
    if network != "xhttp"
        && (q.contains_key("extra") || q.contains_key("mode") || q.contains_key("x_padding_bytes"))
    {
        return Err("VPN_UNSUPPORTED_OPTION");
    }
    if network != "grpc" && (q.contains_key("serviceName") || q.contains_key("authority")) {
        return Err("VPN_UNSUPPORTED_OPTION");
    }
    if network == "grpc" && (q.contains_key("path") || q.contains_key("host")) {
        return Err("VPN_UNSUPPORTED_OPTION");
    }
    let warnings = if q.contains_key("spx") {
        vec!["VPN_SPX_PRESERVED"]
    } else {
        vec![]
    };
    Ok((title, proxy, warnings))
}

pub fn config(proxy: Value, probe: bool) -> Value {
    let mut result = json!({"socks-port":17890,"allow-lan":!probe,"bind-address":if probe {"127.0.0.1"} else {"*"},"mode":"rule","log-level":"warning","ipv6":false,"proxies":[proxy],"rules":["MATCH,VPN"]});
    if !probe {
        result["redir-port"] = json!(17893);
        result["tun"] = json!({"enable":true,"device":"zvpn-tun","stack":"gvisor","auto-route":false,"auto-redirect":false,"auto-detect-interface":false,"dns-hijack":[],"mtu":1500});
        result["dns"] = json!({"enable":true,"listen":"0.0.0.0:17874","ipv6":false,"enhanced-mode":"redir-host","use-hosts":false,"use-system-hosts":false,"nameserver":["udp://1.1.1.1:53#VPN"],"fallback":[],"proxy-server-nameserver":["https://1.1.1.1/dns-query"]});
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    const URI:&str="vless://12345678-1234-1234-1234-123456789abc@example.com:443?security=tls&type=ws&path=%2Ftest#Test";
    #[test]
    fn renaming_preserves_connection_and_accepts_unicode_boundaries() {
        let original = json!({"id":"id","name":"Old","proxy":{"server":"example.test","uuid":"credential"},"source_uri":"vless://original#Old","warnings":["VPN_SPX_PRESERVED"]});
        let mut renamed = original.clone();
        rename(&mut renamed, &"Я".repeat(64)).unwrap();
        for key in ["id", "proxy", "source_uri", "warnings"] {
            assert_eq!(renamed[key], original[key]);
        }
        let before = renamed.clone();
        for invalid in ["".to_string(), "Я".repeat(65), "Line\nbreak".to_string()] {
            assert_eq!(rename(&mut renamed, &invalid), Err("VPN_INVALID_NAME"));
            assert_eq!(renamed, before);
        }
        rename(&mut renamed, "  Основной VPN  ").unwrap();
        assert_eq!(renamed["name"], "Основной VPN");
    }

    #[test]
    fn imports_uri_without_executing_or_expanding() {
        let (n, p, _) = parse(URI, None).unwrap();
        assert_eq!(n, "Test");
        assert_eq!(p["ws-opts"]["path"], "/test");
        assert_eq!(p["skip-cert-verify"], false);
    }
    #[test]
    fn rejects_duplicates_unknown_options_controls_and_invalid_ports() {
        for suffix in ["&type=tcp", "&routing-mark=1", "&host=bad%0D%0Aheader"] {
            assert!(parse(
                &format!("{}{}", URI.split('#').next().unwrap(), suffix),
                None
            )
            .is_err());
        }
        for p in ["0", "65536", "-1", "443;touch"] {
            assert!(parse(&URI.replace(":443", &format!(":{p}")), None).is_err());
        }
    }
    #[test]
    fn preserves_exact_percent_decode_and_literal_plus() {
        assert_eq!(decode("a%252Fb+c").unwrap(), "a%2Fb+c");
        assert!(decode("bad%zz").is_err());
    }
    #[test]
    fn no_direct_or_profile_routes() {
        let (_, p, _) = parse(URI, None).unwrap();
        let c = config(p, false);
        assert_eq!(c["rules"], json!(["MATCH,VPN"]));
        assert_eq!(c["tun"]["auto-route"], false);
        assert!(!c.to_string().contains("DIRECT"));
    }
    #[test]
    fn denies_path_ids_and_control_names() {
        assert!(!valid_id("../../config.json"));
        assert!(parse(URI, Some("bad\nname")).is_err());
    }
    #[test]
    fn xhttp_padding_alias_matches_or_rejects_conflicting_extra() {
        let base =
            "vless://12345678-1234-1234-1234-123456789abc@example.com:443?type=xhttp&security=tls";
        let (_, proxy, _) = parse(&format!("{base}&x_padding_bytes=50-200"), None).unwrap();
        assert_eq!(proxy["xhttp-opts"]["x-padding-bytes"], "50-200");
        let extra = "&extra=%7B%22xPaddingBytes%22%3A%2250-200%22%7D";
        let (_, with_extra, _) =
            parse(&format!("{base}{extra}&x_padding_bytes=50-200"), None).unwrap();
        assert_eq!(with_extra, proxy);
        assert_eq!(
            parse(&format!("{base}{extra}&x_padding_bytes=100-1000"), None).unwrap_err(),
            "VPN_CONFLICTING_OPTION"
        );
        assert!(parse(&format!("{base}&x_padding_bytes=bad"), None).is_err());
        assert!(parse(
            &format!("{base}&x_padding_bytes=50-200").replace("type=xhttp", "type=ws"),
            None
        )
        .is_err());
    }
    #[test]
    fn second_approved_profile_fixture() {
        if let Ok(file) = std::env::var("VPN_SECOND_PROFILE_FIXTURE") {
            let text = std::fs::read_to_string(file).unwrap();
            let (_, proxy, _) = parse(&text, None).expect("second profile should parse");
            assert_eq!(proxy["xhttp-opts"]["x-padding-bytes"], "100-1000");
            assert_eq!(proxy["network"], "xhttp");
            assert!(proxy.get("encryption").is_none());
        }
    }
    #[test]
    fn approved_profile_fixture() {
        if let Ok(file) = std::env::var("VPN_PROFILE_FIXTURE") {
            let text = std::fs::read_to_string(file).unwrap();
            let (_, proxy, warnings) = parse(&text, None).expect("approved profile should parse");
            assert!(proxy["network"] == "xhttp");
            assert!(proxy["reality-opts"]["public-key"].as_str().unwrap().len() == 43);
            assert!(proxy["encryption"].as_str().unwrap().len() > 1000);
            assert!(warnings == vec!["VPN_SPX_PRESERVED"]);
        }
    }
    #[test]
    fn reality_requires_exact_key_length_and_hex_short_id() {
        let u = URI.replace("security=tls", "security=reality");
        assert!(parse(&u, None).is_err());
        let u = u.replace("#Test", &format!("&pbk={}&sid=0a#Test", "A".repeat(43)));
        assert!(parse(&u, None).is_ok());
        assert!(parse(&u.replace("sid=0a", "sid=z"), None).is_err());
    }
}
