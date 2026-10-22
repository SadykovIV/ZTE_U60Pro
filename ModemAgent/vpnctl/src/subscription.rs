//! Subscription documents contain proxy definitions only. Provider routes,
//! listeners, external providers and scripts never become modem configuration.
use crate::{awg, profile, profile::Result};
use base64::{engine::general_purpose, Engine};
use serde_json::{json, Value};
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::{collections::BTreeSet, process::Command, time::Duration};

pub const DOCUMENT_LIMIT: usize = 8 * 1024 * 1024;
pub const PROFILE_LIMIT: usize = 1024;
pub const REQUEST_LIMIT: usize = 32 * 1024 * 1024;
pub struct Parsed {
    pub profiles: Vec<Value>,
    pub skipped: Vec<Value>,
    pub duplicates: usize,
}
// Bound the decoded structure too: YAML aliases can expand a small download.
struct Bounded<'a> { budget: &'a mut usize, depth: usize }
impl Bounded<'_> {
    fn spend<E: de::Error>(&mut self, count: usize) -> std::result::Result<(), E> {
        *self.budget = self.budget.checked_sub(count).ok_or_else(|| E::custom("document expansion limit"))?;
        Ok(())
    }
}
impl<'de> DeserializeSeed<'de> for Bounded<'_> {
    type Value = Value;
    fn deserialize<D: de::Deserializer<'de>>(mut self, d: D) -> std::result::Result<Value, D::Error> {
        self.spend::<D::Error>(64)?;
        if self.depth > 48 { return Err(de::Error::custom("document nesting limit")); }
        d.deserialize_any(self)
    }
}
impl<'de> Visitor<'de> for Bounded<'_> {
    type Value = Value;
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result { f.write_str("a bounded subscription document") }
    fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Value,E> { Ok(json!(v)) }
    fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Value,E> { Ok(json!(v)) }
    fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Value,E> { Ok(json!(v)) }
    fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Value,E> { serde_json::Number::from_f64(v).map(Value::Number).ok_or_else(|| E::custom("nonfinite number")) }
    fn visit_unit<E: de::Error>(self) -> std::result::Result<Value,E> { Ok(Value::Null) }
    fn visit_none<E: de::Error>(self) -> std::result::Result<Value,E> { Ok(Value::Null) }
    fn visit_str<E: de::Error>(mut self, v: &str) -> std::result::Result<Value,E> { self.spend::<E>(v.len())?; Ok(json!(v)) }
    fn visit_string<E: de::Error>(mut self, v: String) -> std::result::Result<Value,E> { self.spend::<E>(v.len())?; Ok(Value::String(v)) }
    fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> std::result::Result<Value,A::Error> {
        let mut list = Vec::new();
        while let Some(v) = a.next_element_seed(Bounded {budget:self.budget,depth:self.depth+1})? { list.push(v); }
        Ok(Value::Array(list))
    }
    fn visit_map<A: MapAccess<'de>>(mut self, mut a: A) -> std::result::Result<Value,A::Error> {
        let mut map = serde_json::Map::new();
        while let Some(key) = a.next_key::<String>()? {
            self.spend::<A::Error>(key.len()+64)?;
            if map.contains_key(&key) { return Err(de::Error::custom("duplicate field")); }
            let value = a.next_value_seed(Bounded {budget:self.budget,depth:self.depth+1})?;
            map.insert(key,value);
        }
        Ok(Value::Object(map))
    }
}
fn yaml(text: &str) -> Result<Value> {
    let mut budget = 16 * 1024 * 1024;
    let mut documents = serde_yaml_ng::Deserializer::from_str(text);
    let d = documents.next().ok_or("VPN_SUBSCRIPTION_FORMAT")?;
    let value = Bounded {budget:&mut budget,depth:0}.deserialize(d).map_err(|_| "VPN_SUBSCRIPTION_FORMAT")?;
    if documents.next().is_some() { return Err("VPN_SUBSCRIPTION_FORMAT"); }
    Ok(value)
}
pub fn host(url: &str) -> Result<String> {
    if url.len() > 8192 || url.chars().any(|c| c.is_control() || c.is_whitespace())
        || url.contains(['\\', '"', '#']) { return Err("VPN_SUBSCRIPTION_URL"); }
    let rest = url.strip_prefix("https://").ok_or("VPN_SUBSCRIPTION_URL")?;
    let authority = rest.split(['/', '?']).next().unwrap_or("");
    let (host, port) = if authority.starts_with('[') {
        let (host, rest) = authority[1..].split_once(']').ok_or("VPN_SUBSCRIPTION_URL")?;
        if host.parse::<std::net::Ipv6Addr>().is_err() { return Err("VPN_SUBSCRIPTION_URL"); }
        (host, rest.strip_prefix(':').unwrap_or(if rest.is_empty() { "443" } else { "" }))
    } else {
        let (host, port) = authority.split_once(':').unwrap_or((authority, "443"));
        if host.is_empty() || host.len() > 253 || !host.trim_end_matches('.').split('.').all(|s| {
            !s.is_empty() && s.len() <= 63 && !s.starts_with('-') && !s.ends_with('-')
                && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
        }) { return Err("VPN_SUBSCRIPTION_URL"); }
        (host, port)
    };
    if port.parse::<u16>().ok().filter(|p| *p != 0).is_none() { return Err("VPN_SUBSCRIPTION_URL"); }
    Ok(host.to_lowercase())
}
pub fn protocol(proxy: &Value) -> &'static str {
    match proxy["type"].as_str().unwrap_or("") {
        "ikev2" => "ikev2",
        "wireguard" => awg::protocol(proxy),
        "vless" => "vless", "vmess" => "vmess", "trojan" => "trojan",
        "hysteria2" => "hysteria2", "hysteria" => "hysteria", "ss" => "shadowsocks",
        "tuic" => "tuic", "socks5" => "socks5", "http" => "http", "anytls" => "anytls",
        _ => "unknown",
    }
}
fn is_native_ikev2(proxy: &Value) -> bool { proxy["type"] == "ikev2" }
fn native(mut proxy: Value) -> Result<Value> {
    proxy.as_object().ok_or("VPN_SUBSCRIPTION_ENTRY")?;
    if serde_json::to_vec(&proxy).map_err(|_| "VPN_SUBSCRIPTION_ENTRY")?.len() > 128 * 1024 {
        return Err("VPN_PROFILE_TOO_LARGE");
    }
    if is_native_ikev2(&proxy) || protocol(&proxy) == "unknown" { return Err("VPN_UNSUPPORTED_PROTOCOL"); }
    check_fields(&proxy, proxy["type"] == "wireguard", true)?;
    let raw_name = proxy["name"].as_str().ok_or("VPN_INVALID_NAME")?.trim();
    let name: String = raw_name.chars().take(64).collect();
    let name = profile::name(&name)?;
    let mut warnings = if raw_name.chars().count() > 64 { vec!["NAME_TRUNCATED"] } else { vec![] };
    let field = |name: &str| proxy.as_object().unwrap().iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value);
    if field("skip-cert-verify").is_some_and(|value| value == true)
        && !field("fingerprint").is_some_and(|value| value.as_str().is_some_and(|pin| !pin.is_empty())) {
        warnings.push("VPN_INSECURE_TLS");
    }
    proxy["name"] = json!("VPN");
    Ok(json!({"name":name,"protocol":protocol(&proxy),"proxy":proxy,"warnings":warnings}))
}
fn inline_pem(value: &Value, certificate: bool) -> bool {
    let Some(text) = value.as_str() else { return false };
    if text.is_empty() { return true; }
    let labels: &[&str] = if certificate { &["CERTIFICATE"] } else { &["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"] };
    let mut rest = text.trim();
    let mut blocks = 0;
    while !rest.is_empty() {
        let mut found = None;
        for label in labels {
            if let Some(body) = rest.strip_prefix(&format!("-----BEGIN {label}-----")) {
                let Some((body, tail)) = body.split_once(&format!("-----END {label}-----")) else { return false };
                let compact: String = body.chars().filter(|c| !c.is_whitespace()).collect();
                if compact.is_empty() || general_purpose::STANDARD.decode(compact).is_err() { return false }
                found = Some(tail.trim()); break;
            }
        }
        let Some(tail) = found else { return false };
        rest = tail; blocks += 1;
        if !certificate && blocks > 1 { return false }
    }
    blocks > 0
}

fn check_fields(value: &Value, wireguard: bool, top: bool) -> Result<()> {
    if let Some(object) = value.as_object() {
        let mut keys = BTreeSet::new();
        for (field, value) in object {
            let lower = field.to_ascii_lowercase();
            if !keys.insert(lower.clone()) { return Err("VPN_SUBSCRIPTION_ENTRY"); }
            // Mihomo's field decoder ignores key case. Check nested TLS/download
            // options too; certificate paths must never read modem credentials.
            if ["dialer-proxy", "interface-name", "routing-mark"].contains(&lower.as_str()) {
                return Err("VPN_SUBSCRIPTION_ROUTING");
            }
            if (lower == "certificate" || lower == "private-key")
                && !(top && wireguard && lower == "private-key")
                && !inline_pem(value, lower == "certificate") {
                return Err("VPN_SUBSCRIPTION_FILE_REFERENCE");
            }
            // HTTP header names are user data, not configuration directives.
            if lower != "headers" && lower != "ws-headers" { check_fields(value, wireguard, false)?; }
        }
    } else if let Some(values) = value.as_array() {
        for value in values { check_fields(value, wireguard, false)?; }
    }
    Ok(())
}
fn document(text: &str) -> Result<Vec<std::result::Result<Value, &'static str>>> {
    let text = text.trim_start_matches('\u{feff}').trim();
    if text.is_empty() || text.len() > DOCUMENT_LIMIT { return Err("VPN_SUBSCRIPTION_DOCUMENT"); }
    // URI lists are tried before YAML; a single URI is also a valid YAML scalar.
    if text.lines().any(|line| is_uri(line.trim())) {
        return Ok(text.lines().filter(|line| !line.trim().is_empty() && !line.trim().starts_with('#')).map(|line| {
            let uri = line.trim();
            let (name, proxy, warnings) = profile::parse(uri, None)?;
            Ok(json!({"name":name,"protocol":protocol(&proxy),"proxy":proxy,"warnings":warnings,"source_uri":uri}))
        }).collect());
    }
    // Standard and URL-safe subscription encodings, with optional padding.
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.len() >= 16 && compact.bytes().all(|c| c.is_ascii_alphanumeric() || b"+/=_-".contains(&c)) {
        for engine in [&general_purpose::STANDARD, &general_purpose::STANDARD_NO_PAD, &general_purpose::URL_SAFE, &general_purpose::URL_SAFE_NO_PAD] {
            if let Ok(bytes) = engine.decode(&compact) {
                if let Ok(decoded) = String::from_utf8(bytes) {
                    // Do not recursively decode untrusted data.
                    if decoded.lines().any(|l| is_uri(l.trim())) { return document(&decoded); }
                }
            }
        }
    }
    let value = yaml(text)?;
    let entries = value.get("proxies").and_then(Value::as_array).ok_or("VPN_SUBSCRIPTION_FORMAT")?;
    if entries.len() > PROFILE_LIMIT { return Err("VPN_PROFILE_LIMIT"); }
    Ok(entries.iter().cloned().map(native).collect())
}
fn is_uri(text: &str) -> bool {
    ["vless://", "hy2://", "hysteria2://"].iter().any(|s| text.starts_with(s))
}
pub fn parse(text: &str) -> Result<Parsed> {
    let entries = document(text)?;
    if entries.len() > PROFILE_LIMIT { return Err("VPN_PROFILE_LIMIT"); }
    let mut result = Parsed { profiles: vec![], skipped: vec![], duplicates: 0 };
    let mut seen = BTreeSet::new();
    for (index, entry) in entries.into_iter().enumerate() {
        match entry {
            Ok(mut p) => {
                let key = serde_json::to_string(&p["proxy"]).map_err(|_| "VPN_SUBSCRIPTION_ENTRY")?;
                if !seen.insert(key) { result.duplicates += 1; continue; }
                p["source_index"] = json!(index + 1);
                result.profiles.push(p);
            }
            Err(code) => result.skipped.push(json!({"index":index+1,"code":code})),
        }
    }
    if result.profiles.is_empty() { return Err("VPN_SUBSCRIPTION_EMPTY"); }
    Ok(result)
}
pub fn select(documents: &[String]) -> Result<Parsed> {
    if documents.is_empty() || documents.len() > 2 || documents.iter().any(|s| s.len() > DOCUMENT_LIMIT) {
        return Err("VPN_SUBSCRIPTION_DOCUMENT");
    }
    let mut error = "VPN_SUBSCRIPTION_FORMAT";
    for text in documents {
        match parse(text) { Ok(parsed) => return Ok(parsed), Err(e) => error = e }
    }
    Err(error)
}
pub fn fetch(url: &str) -> Result<Parsed> {
    host(url)?;
    let mut last_error = "VPN_SUBSCRIPTION_FETCH";
    for agent in ["clash.meta", "Happ/1.0"] {
        // The token-bearing URL is supplied on stdin, never in process arguments.
        let input = format!("url = \"{url}\"\nuser-agent = \"{agent}\"\n");
        let result = process_runner::output(Command::new("curl").args([
            "--config", "-", "--fail", "--silent", "--show-error", "--location",
            "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "4",
            "--connect-timeout", "15", "--max-time", "60", "--max-filesize", "8388608",
        ]), Some(input.as_bytes()), Duration::from_secs(65), DOCUMENT_LIMIT);
        if let Ok(out) = result {
            if out.status.success() {
                if let Ok(text) = String::from_utf8(out.stdout) {
                    match parse(&text) { Ok(parsed) => return Ok(parsed), Err(e) => last_error = e }
                }
            }
        }
    }
    Err(last_error)
}

#[cfg(test)]
mod tests {
    use super::*;
    const URI: &str = "vless://00000000-0000-0000-0000-000000000001@example.org:443?security=tls&type=tcp#Example";
    #[test] fn url_tokens_are_never_returned_and_curl_injection_is_rejected() {
        assert_eq!(host("https://Example.org/private?token=test").unwrap(), "example.org");
        assert_eq!(host("https://[::1]:8443/test").unwrap(), "::1");
        for url in ["http://example.org", "https://user:pass@example.org/", "https://example.org\noutput=x", "https://x/\"", "https://x\\a/", "https://x:0/"] {
            assert!(host(url).is_err());
        }
    }
    #[test] fn base64_uri_feed_and_duplicates() {
        let text = format!("{URI}\n{URI}\nunsupported://secret");
        let encoded = general_purpose::STANDARD.encode(&text);
        let parsed = parse(&encoded).unwrap();
        assert_eq!(parsed.profiles.len(), 1);
        assert_eq!(parsed.duplicates, 1);
        assert_eq!(parsed.skipped[0], json!({"index":3,"code":"VPN_VLESS_ONLY"}));
        assert!(!serde_json::to_string(&parsed.skipped).unwrap().contains("secret"));
    }
    #[test] fn native_fields_preserved_but_provider_network_is_not_imported() {
        let doc = r#"proxies:
  - name: HY2
    type: hysteria2
    server: example.org
    port: 443
    password: example
    bbr-profile: aggressive
  - name: Unsafe
    type: vless
    dialer-proxy: DIRECT
rules: [MATCH,DIRECT]
external-controller: 0.0.0.0:9999
"#;
        let parsed = parse(doc).unwrap();
        assert_eq!(parsed.profiles.len(), 1);
        assert_eq!(parsed.profiles[0]["proxy"]["bbr-profile"], "aggressive");
        assert!(parsed.profiles[0].get("rules").is_none());
        assert_eq!(parsed.skipped[0]["code"], "VPN_SUBSCRIPTION_ROUTING");
    }
    #[test] fn http_success_with_error_document_falls_back() {
        let result = select(&[r#"{"error":"wrong user agent"}"#.into(), general_purpose::STANDARD.encode(URI)]).unwrap();
        assert_eq!(result.profiles.len(), 1);
        assert!(parse("proxies: []").is_err());
        assert!(parse("proxies: []\nproxies: []").is_err());
    }
    #[test] fn rejects_case_aliases_and_bounded_yaml_expansion() {
        for field in ["Dialer-Proxy", "DIALER-PROXY", "Interface-Name", "ROUTING-MARK"] {
            let doc = format!("proxies:\n - name: Example\n   type: vless\n   {field}: DIRECT\n");
            assert!(parse(&doc).is_err());
        }
        assert!(parse("proxies:\n - name: Example\n   type: vless\n   Server: x\n   server: y").is_err());
        let bomb = format!("anchor: &a {}\nproxies: [{}]", "x".repeat(300_000), vec!["*a";64].join(","));
        assert!(yaml(&bomb).is_err());
        assert!(yaml("proxies: []\n---\nproxies: []").is_err());
        assert!(yaml(&format!("{}0{}", "[".repeat(60), "]".repeat(60))).is_err());
    }
    #[test] fn proxy_cannot_read_modem_key_files_even_in_nested_tls() {
        for value in [json!({"Certificate":"/etc/private"}), json!({"xhttp-opts":{"download-settings":{"PRIVATE-KEY":"/etc/private"}}}), json!({"plugin-opts":{"certificate":"relative.pem"}})] {
            assert_eq!(check_fields(&value, false, true), Err("VPN_SUBSCRIPTION_FILE_REFERENCE"));
        }
        assert!(check_fields(&json!({"type":"wireguard","private-key":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}), true, true).is_ok());
        assert!(check_fields(&json!({"certificate":"-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----"}), false, true).is_ok());
        assert!(check_fields(&json!({"certificate":"-----BEGIN CERTIFICATE-----bad path-----END CERTIFICATE-----"}), false, true).is_err());
        assert!(check_fields(&json!({"certificate":"", "private-key":""}), false, true).is_ok());
        assert!(check_fields(&json!({"ws-headers":{"certificate":"custom-header-value", "interface-name":"another-header"}}), false, true).is_ok());
    }
    #[test] fn native_tls_warning_matches_uri_policy() {
        let mut proxy = json!({"type":"hysteria2","name":"Example","server":"example.org","port":443,"password":"fixture","Skip-Cert-Verify":true});
        assert_eq!(native(proxy.clone()).unwrap()["warnings"], json!(["VPN_INSECURE_TLS"]));
        proxy["Fingerprint"] = json!("11".repeat(32));
        assert_eq!(native(proxy.clone()).unwrap()["warnings"], json!([]));
        proxy["Fingerprint"] = json!("");
        proxy["Skip-Cert-Verify"] = json!(false);
        assert_eq!(native(proxy).unwrap()["warnings"], json!([]));
    }
}
