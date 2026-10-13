use serde_json::{json, Value};
use std::collections::BTreeMap;
use base64::{engine::general_purpose, Engine};

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
    let trimmed = uri.trim();
    if trimmed.starts_with("hy2://") || trimmed.starts_with("hysteria2://") {
        return parse_hysteria2(trimmed, label);
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
        "headerType",
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
    if !["", "none"].contains(&get("headerType", "").as_str()) {
        return Err("VPN_UNSUPPORTED_OPTION");
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
            if q.get("authority").is_some_and(|v| !v.is_empty())
                || !["", "gun"].contains(&get("mode", "gun").as_str()) {
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
        && (q.contains_key("extra") || (network != "grpc" && q.contains_key("mode")) || q.contains_key("x_padding_bytes"))
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

// Hysteria's shared URI contains only connection settings. In particular,
// local files, bandwidth, client listeners and routing are not URI options.
// https://v2.hysteria.network/docs/developers/URI-Scheme/
fn parse_hysteria2(uri: &str, label: Option<&str>) -> Result<(String, Value, Vec<&'static str>)> {
    if uri.chars().any(char::is_control) { return Err("VPN_INVALID_URI"); }
    let body = uri.strip_prefix("hy2://").or_else(|| uri.strip_prefix("hysteria2://"))
        .ok_or("VPN_INVALID_URI")?;
    let (body, fragment) = body.split_once('#').unwrap_or((body, "Hysteria2"));
    let (authority, query) = body.split_once('?').unwrap_or((body, ""));
    let authority = authority.strip_suffix('/').unwrap_or(authority);
    let (password, address) = if let Some((auth, address)) = authority.split_once('@') {
        (decode(auth)?, address)
    } else { (String::new(), authority) };
    let (server, ports) = if let Some(address) = address.strip_prefix('[') {
        let (host, rest) = address.split_once(']').ok_or("VPN_INVALID_SERVER")?;
        if host.parse::<std::net::Ipv6Addr>().is_err() { return Err("VPN_INVALID_SERVER"); }
        let ports = if rest.is_empty() { "443" } else { rest.strip_prefix(':').ok_or("VPN_INVALID_PORT")? };
        (host, ports)
    } else {
        let (host, ports) = address.split_once(':').unwrap_or((address, "443"));
        if host.is_empty() || host.len() > 253 || !host.bytes().all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c)) {
            return Err("VPN_INVALID_SERVER");
        }
        (host, ports)
    };
    let port = |text: &str| -> Result<u16> {
        if text.is_empty() || !text.bytes().all(|c| c.is_ascii_digit()) { return Err("VPN_INVALID_PORT"); }
        text.parse::<u16>().ok().filter(|n| *n != 0).ok_or("VPN_INVALID_PORT")
    };
    let mut first_port = None;
    for part in ports.split(',') {
        let (first, last) = part.split_once('-').unwrap_or((part, part));
        let (first, last) = (port(first)?, port(last)?);
        if first > last { return Err("VPN_INVALID_PORT"); }
        first_port.get_or_insert(first);
    }
    let mut options = BTreeMap::new();
    if !query.is_empty() {
        for entry in query.split('&') {
            let (key, value) = entry.split_once('=').ok_or("VPN_INVALID_URI")?;
            let key = decode(&key.replace('+', " "))?;
            let value = decode(&value.replace('+', " "))?;
            if !["obfs", "obfs-password", "sni", "insecure", "pinSHA256", "ech"].contains(&key.as_str()) {
                return Err("VPN_UNSUPPORTED_OPTION");
            }
            if options.insert(key, value).is_some() { return Err("VPN_DUPLICATE_OPTION"); }
        }
    }
    let insecure = match options.get("insecure").map(String::as_str).unwrap_or("0") {
        "0" => false, "1" => true, _ => return Err("VPN_UNSUPPORTED_SECURITY"),
    };
    let mut proxy = json!({"name":"VPN","type":"hysteria2","server":server,"port":first_port.unwrap(),"password":password,"skip-cert-verify":insecure});
    if ports.contains([',', '-']) { proxy["ports"] = json!(ports); }
    if let Some(sni) = options.get("sni") {
        if sni.len() > 253 || sni.chars().any(char::is_whitespace) { return Err("VPN_INVALID_SERVER"); }
        proxy["sni"] = json!(sni);
    }
    let obfs = options.get("obfs").map(String::as_str).unwrap_or("");
    let obfs_password = options.get("obfs-password").map(String::as_str).unwrap_or("");
    match obfs {
        "" if obfs_password.is_empty() => (),
        "salamander" | "gecko" if !obfs_password.is_empty() => {
            proxy["obfs"] = json!(obfs);
            proxy["obfs-password"] = json!(obfs_password);
        }
        _ => return Err("VPN_UNSUPPORTED_OPTION"),
    }
    if let Some(pin) = options.get("pinSHA256") {
        let compact = pin.replace(':', "");
        if compact.len() != 64 || !compact.bytes().all(|c| c.is_ascii_hexdigit()) { return Err("VPN_INVALID_KEY"); }
        proxy["fingerprint"] = json!(compact.to_ascii_lowercase());
    }
    if let Some(ech) = options.get("ech") {
        if general_purpose::STANDARD.decode(ech).ok().filter(|bytes| !bytes.is_empty()).is_none() { return Err("VPN_INVALID_KEY"); }
        proxy["ech-opts"] = json!({"enable":true,"config":ech});
    }
    let warnings = if insecure && !options.contains_key("pinSHA256") { vec!["VPN_INSECURE_TLS"] } else { vec![] };
    Ok((name(label.unwrap_or(&decode(fragment)?))?, proxy, warnings))
}

pub fn config(proxy: Value, probe: bool) -> Value {
    let mut result = json!({"socks-port":17890,"allow-lan":!probe,"bind-address":if probe {"127.0.0.1"} else {"*"},"mode":"rule","log-level":"warning","ipv6":false,"proxies":[proxy],"rules":["MATCH,VPN"]});
    if !probe {
        result["redir-port"] = json!(17893);
        result["tun"] = json!({"enable":true,"device":"zvpn-tun","stack":"gvisor","auto-route":false,"auto-redirect":false,"auto-detect-interface":false,"dns-hijack":[],"mtu":1500});
        // DNS follows the selected VPN over TCP. Requiring proxy UDP here
        // makes TCP-capable profiles look offline when their server rejects XUDP.
        result["dns"] = json!({"enable":true,"listen":"0.0.0.0:17874","ipv6":false,"enhanced-mode":"redir-host","use-hosts":false,"use-system-hosts":false,"nameserver":["https://1.1.1.1/dns-query#VPN"],"fallback":[],"proxy-server-nameserver":["https://1.1.1.1/dns-query"]});
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hysteria2_default_port_auth_and_fragment_are_preserved() {
        let (n, p, warnings) = parse("hy2://user:p%40ss%3A%2F+word@example.org/#%D0%A2%D0%B5%D1%81%D1%82", None).unwrap();
        assert_eq!(n, "Тест");
        assert_eq!(p["password"], "user:p@ss:/+word");
        assert_eq!(p["type"], "hysteria2");
        assert_eq!(p["server"], "example.org");
        assert_eq!(p["port"], 443);
        assert_eq!(p["skip-cert-verify"], false);
        assert!(p.get("ports").is_none());
        assert!(warnings.is_empty());
        let (n, p, _) = parse("hysteria2://[2001:db8::1]", Some("IPv6")).unwrap();
        assert_eq!(n, "IPv6"); assert_eq!(p["server"], "2001:db8::1"); assert_eq!(p["password"], "");
    }
    #[test]
    fn hysteria2_hopping_obfs_and_explicit_tls_policy_are_preserved() {
        let (_, p, w) = parse("hysteria2://secret@[2001:db8::1]:443,5000-6000/?obfs=salamander&obfs-password=p%2Bq+r&sni=peer.example&insecure=1", None).unwrap();
        assert_eq!(p["server"], "2001:db8::1"); assert_eq!(p["port"], 443);
        assert_eq!(p["ports"], "443,5000-6000"); assert_eq!(p["obfs-password"], "p+q r");
        assert_eq!(p["sni"], "peer.example"); assert_eq!(p["skip-cert-verify"], true);
        assert_eq!(w, vec!["VPN_INSECURE_TLS"]);
        let pin = vec!["AB";32].join(":");
        let (_, p, w) = parse(&format!("hy2://p@host:8443?pinSHA256={pin}&ech=AAECAw%3D%3D&insecure=1&obfs=gecko&obfs-password=p"), None).unwrap();
        assert_eq!(p["fingerprint"], "ab".repeat(32));
        assert_eq!(p["ech-opts"], json!({"enable":true,"config":"AAECAw=="}));
        assert_eq!(p["obfs"], "gecko"); assert!(w.is_empty());
    }
    #[test]
    fn hysteria2_invalid_or_unrepresentable_options_fail_explicitly() {
        for uri in ["hy2://host:0", "hy2://host:65536", "hy2://host:", "hy2://host:443,", "hy2://host:443-1", "hy2://host:+443", "hy2://2001:db8::1", "hy2://[bad]:443", "hy2://host/path", "hy2://p@host?insecure=true", "hy2://p@host?insecure=0&insecure=1", "hy2://p@host?obfs=salamander", "hy2://p@host?obfs=unknown&obfs-password=p", "hy2://p@host?obfs-password=p", "hy2://p@host?pinSHA256=deadbeef", "hy2://p@host?ech=/tmp/ech.txt", "hy2://p@host?ech=", "hy2://p@host?ca=/private/cert", "hy2://p@host?up=100", "hy2://p@host?dialer-proxy=DIRECT", "hy2://p%0A@host", "hy2://p@host#bad%00name"] {
            assert!(parse(uri, None).is_err(), "{uri}");
        }
        assert_eq!(parse("hy2://p@host?ca=cert", None).unwrap_err(), "VPN_UNSUPPORTED_OPTION");
        assert_eq!(parse("hy2://p@host?insecure=1&insecure=0", None).unwrap_err(), "VPN_DUPLICATE_OPTION");
    }
    #[test]
    #[ignore = "requires matching Mihomo binary in ZTE_HY2_CORE; parser-only, no traffic"]
    fn hysteria2_matching_core_accepts_synthetic_profiles() {
        use std::{fs, os::unix::fs::DirBuilderExt, process::Command};
        let core = std::env::var("ZTE_HY2_CORE").expect("matching core path");
        let directory = std::env::temp_dir().join(format!("zte-hy2-core-{}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&directory).unwrap();
        let pin = "ab".repeat(32);
        let uris = ["hy2://password@example.invalid".to_owned(), "hysteria2://user:password@[2001:db8::1]:443,5000-6000/?sni=peer.invalid&obfs=salamander&obfs-password=synthetic&insecure=1".into(), format!("hy2://password@example.invalid?pinSHA256={pin}&ech=AAECAw%3D%3D"), "hy2://password@example.invalid:443-445?obfs=gecko&obfs-password=synthetic".into()];
        for (index, uri) in uris.iter().enumerate() {
            let (_, proxy, _) = parse(uri, None).unwrap();
            let file = directory.join(format!("{index}.json"));
            fs::write(&file, serde_json::to_vec(&config(proxy, true)).unwrap()).unwrap();
            let result = Command::new(&core).args(["-t", "-d"]).arg(&directory).arg("-f").arg(&file).output().unwrap();
            assert!(result.status.success(), "case {index}: {}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
        }
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn grpc_gun_links_allow_empty_exporter_placeholders() {
        let uri = "vless://00000000-0000-0000-0000-000000000001@example.org:443?security=tls&type=grpc&mode=gun&authority=&headerType=&serviceName=service#Example";
        let (_, proxy, _) = parse(uri, None).unwrap();
        assert_eq!(proxy["grpc-opts"]["grpc-service-name"], "service");
        for bad in [uri.replace("mode=gun", "mode=multi"), uri.replace("authority=&", "authority=override.example&"), uri.replace("headerType=&", "headerType=http&")] {
            assert!(parse(&bad, None).is_err());
        }
    }
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
    fn client_dns_uses_https_through_vpn_without_direct_fallback() {
        let (_, proxy, _) = parse(URI, None).unwrap();
        let config = config(proxy, false);
        assert_eq!(config["dns"]["nameserver"], json!(["https://1.1.1.1/dns-query#VPN"]));
        assert_eq!(config["dns"]["fallback"], json!([]));
        assert_eq!(config["rules"], json!(["MATCH,VPN"]));
        assert_eq!(config["dns"]["proxy-server-nameserver"], json!(["https://1.1.1.1/dns-query"]));
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
