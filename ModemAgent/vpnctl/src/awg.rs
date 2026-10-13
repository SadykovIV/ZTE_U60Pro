//! Import WireGuard/AmneziaWG client INI into the pinned Mihomo userspace core.
//! No shell hooks, routing commands, or secret-bearing error messages are accepted.
use serde_json::{json, Map, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
};

pub type Result<T> = std::result::Result<T, &'static str>;
pub struct Parsed {
    pub protocol: &'static str,
    pub proxy: Value,
    pub warnings: Vec<&'static str>,
}
type Fields = BTreeMap<String, String>;

fn number(value: &str, max: u64) -> Result<u64> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err("VPN_AWG_INVALID_NUMBER");
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|v| *v <= max)
        .ok_or("VPN_AWG_INVALID_NUMBER")
}
fn range(value: &str, max: u64) -> Result<(u64, u64)> {
    let (a, b) = value.split_once('-').unwrap_or((value, value));
    let (a, b) = (number(a, max)?, number(b, max)?);
    if a > b {
        return Err("VPN_AWG_INVALID_RANGE");
    }
    Ok((a, b))
}
fn flag(value: &str) -> Result<bool> {
    match value.to_ascii_lowercase().as_str() {
        "true" | "on" | "1" => Ok(true),
        "false" | "off" | "0" => Ok(false),
        _ => Err("VPN_AWG_INVALID_BOOLEAN"),
    }
}
// Standard padded base64 of exactly 32 bytes; reject noncanonical trailing bits.
fn key(value: &str) -> Result<()> {
    let b = value.as_bytes();
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    if b.len() != 44
        || b[43] != b'='
        || !b[..43].iter().all(|v| alphabet.contains(v))
        || alphabet.iter().position(|v| *v == b[42]).unwrap_or(1) & 3 != 0
    {
        return Err("VPN_AWG_INVALID_KEY");
    }
    Ok(())
}
fn required<'a>(fields: &'a Fields, name: &str) -> Result<&'a str> {
    fields
        .get(name)
        .filter(|v| !v.is_empty())
        .map(String::as_str)
        .ok_or("VPN_AWG_MISSING_FIELD")
}
fn list(value: &str) -> Result<Vec<&str>> {
    let values: Vec<_> = value.split(',').map(str::trim).collect();
    if values.iter().any(|v| v.is_empty()) {
        return Err("VPN_AWG_INVALID_LIST");
    }
    Ok(values)
}
fn prefix(value: &str) -> Result<(IpAddr, u8)> {
    let (addr, bits) = value.split_once('/').ok_or("VPN_AWG_INVALID_ADDRESS")?;
    let addr: IpAddr = addr.parse().map_err(|_| "VPN_AWG_INVALID_ADDRESS")?;
    let bits = number(bits, if addr.is_ipv4() { 32 } else { 128 })? as u8;
    Ok((addr, bits))
}
fn overlap(a: (IpAddr, u8), b: (IpAddr, u8)) -> bool {
    let bits = a.1.min(b.1);
    match (a.0, b.0) {
        (IpAddr::V4(a), IpAddr::V4(b)) => {
            bits == 0 || u32::from(a) >> (32 - bits) == u32::from(b) >> (32 - bits)
        }
        (IpAddr::V6(a), IpAddr::V6(b)) => {
            bits == 0 || u128::from(a) >> (128 - bits) == u128::from(b) >> (128 - bits)
        }
        _ => false,
    }
}
fn endpoint(value: &str) -> Result<(String, u16)> {
    let (host, port) = if let Some(rest) = value.strip_prefix('[') {
        let (host, port) = rest.split_once("]:").ok_or("VPN_AWG_INVALID_ENDPOINT")?;
        if !matches!(host.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
            return Err("VPN_AWG_INVALID_ENDPOINT");
        }
        (host, port)
    } else {
        let (host, port) = value.rsplit_once(':').ok_or("VPN_AWG_INVALID_ENDPOINT")?;
        if host.is_empty()
            || host.len() > 253
            || host.contains(':')
            || !host.trim_end_matches('.').split('.').all(|label| {
                !label.is_empty()
                    && label.len() <= 63
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-')
            })
        {
            return Err("VPN_AWG_INVALID_ENDPOINT");
        }
        (host, port)
    };
    let port = number(port, 65535)? as u16;
    if port == 0 {
        return Err("VPN_AWG_INVALID_ENDPOINT");
    }
    Ok((host.into(), port))
}
fn signature(mut value: &str, v3: bool) -> Result<()> {
    let mut size = 0u64;
    while !value.trim().is_empty() {
        value = value.trim_start();
        let rest = value.strip_prefix('<').ok_or("VPN_AWG_INVALID_SIGNATURE")?;
        let (tag, remaining) = rest.split_once('>').ok_or("VPN_AWG_INVALID_SIGNATURE")?;
        let parts: Vec<_> = tag.split_whitespace().collect();
        size += match parts.as_slice() {
            ["b", bytes] => {
                let bytes = bytes.strip_prefix("0x").unwrap_or(bytes);
                if bytes.is_empty()
                    || bytes.len() % 2 != 0
                    || !bytes.bytes().all(|v| v.is_ascii_hexdigit())
                {
                    return Err("VPN_AWG_INVALID_SIGNATURE");
                }
                (bytes.len() / 2) as u64
            }
            ["t"] => 4,
            ["r" | "rc" | "rd", count] => number(count, 65507)?,
            ["d" | "ds"] if v3 => 0,
            ["dz", count] if v3 => number(count, 65507)?,
            _ => return Err("VPN_AWG_INVALID_SIGNATURE"),
        };
        if size > 65507 {
            return Err("VPN_AWG_SIGNATURE_TOO_LARGE");
        }
        value = remaining;
    }
    Ok(())
}

pub fn protocol(proxy: &Value) -> &'static str {
    match proxy.get("amnezia-wg-option") {
        None => "wireguard",
        Some(awg) if awg["version"] == 3 => {
            if awg.get("random-trailers").is_some() || awg.get("disable-cookies").is_some() {
                "amneziawg3.1"
            } else {
                "amneziawg3"
            }
        }
        _ => "amneziawg2",
    }
}

pub fn parse(config: &str) -> Result<Parsed> {
    if config.len() > 32768 {
        return Err("VPN_PROFILE_TOO_LARGE");
    }
    let mut interface = Fields::new();
    let mut peers = Vec::<Fields>::new();
    let mut have_interface = false;
    let mut section = 0;
    for raw in config.trim_start_matches('\u{feff}').lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if line.chars().any(|c| c.is_control() && c != '\t') {
            return Err("VPN_AWG_INVALID_CONFIG");
        }
        if line.starts_with('[') {
            if line.eq_ignore_ascii_case("[Interface]") && !have_interface && peers.is_empty() {
                have_interface = true;
                section = 1;
            } else if line.eq_ignore_ascii_case("[Peer]") && have_interface {
                peers.push(Fields::new());
                section = 2;
            } else {
                return Err("VPN_AWG_INVALID_SECTION");
            }
            continue;
        }
        let (name, value) = line.split_once('=').ok_or("VPN_AWG_INVALID_CONFIG")?;
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        if name.is_empty() || !name.bytes().all(|v| v.is_ascii_alphanumeric()) {
            return Err("VPN_AWG_UNSUPPORTED_OPTION");
        }
        let target = match section {
            1 => &mut interface,
            2 => peers.last_mut().unwrap(),
            _ => return Err("VPN_AWG_INVALID_SECTION"),
        };
        if target.insert(name, value.into()).is_some() {
            return Err("VPN_AWG_DUPLICATE_OPTION");
        }
    }
    if !have_interface || peers.is_empty() {
        return Err("VPN_AWG_MISSING_FIELD");
    }
    let standard = ["privatekey", "address", "dns", "mtu"];
    let numeric = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"];
    let headers = ["h1", "h2", "h3", "h4"];
    let signatures = ["i1", "i2", "i3", "i4", "i5"];
    let v3_keys = [
        ("headerprotectionkey", "header-protection-key"),
        ("contentpaddingaddition", "content-padding-addition"),
        ("rekeyaftertime", "rekey-after-time"),
        ("rekeytimeout", "rekey-timeout"),
        ("rejectaftertime", "reject-after-time"),
        ("keepalivetimeout", "keepalive-timeout"),
        ("maxhandshakeattempts", "max-handshake-attempts"),
        ("randomtrailers", "random-trailers"),
        ("disablecookies", "disable-cookies"),
    ];
    for name in interface.keys() {
        if !standard.contains(&name.as_str())
            && !numeric.contains(&name.as_str())
            && !headers.contains(&name.as_str())
            && !signatures.contains(&name.as_str())
            && !v3_keys.iter().any(|(k, _)| *k == name)
        {
            // ListenPort, FwMark, Table and pre/post hooks cannot be represented
            // by an isolated Mihomo outbound. Never silently execute/drop them.
            return Err("VPN_AWG_UNSUPPORTED_OPTION");
        }
    }
    let private = required(&interface, "privatekey")?;
    key(private)?;
    let mut proxy = json!({"name":"VPN","type":"wireguard","private-key":private,"udp":true});
    let mut v4 = false;
    let mut v6 = false;
    for value in list(required(&interface, "address")?)? {
        let (address, _) = prefix(value)?;
        if address.is_unspecified() || address.is_multicast() {
            return Err("VPN_AWG_INVALID_ADDRESS");
        }
        let (field, used) = if address.is_ipv4() {
            ("ip", &mut v4)
        } else {
            ("ipv6", &mut v6)
        };
        if *used {
            return Err("VPN_AWG_MULTIPLE_LOCAL_ADDRESSES");
        }
        *used = true;
        proxy[field] = json!(value);
    }
    // The managed guest network is IPv4. Keep IPv6 tunnel metadata, but do not
    // claim an IPv6-only tunnel can carry the guest's IPv4 packets.
    if !v4 {
        return Err("VPN_AWG_IPV4_ADDRESS_REQUIRED");
    }
    let mut warnings = Vec::new();
    if v6 {
        warnings.push("VPN_IPV6_GUEST_DISABLED");
    }
    if let Some(dns) = interface.get("dns") {
        let values = list(dns)?;
        for addr in &values {
            let ip: IpAddr = addr.parse().map_err(|_| "VPN_AWG_INVALID_DNS")?;
            if ip.is_unspecified() || ip.is_multicast() {
                return Err("VPN_AWG_INVALID_DNS");
            }
            if ip.is_ipv6() && !v6 {
                return Err("VPN_AWG_IPV6_ADDRESS_REQUIRED");
            }
        }
        proxy["dns"] = json!(values);
        proxy["remote-dns-resolve"] = json!(true);
    }
    if let Some(mtu) = interface.get("mtu") {
        let mtu = number(mtu, 65535)?;
        if mtu < if v6 { 1280 } else { 68 } {
            return Err("VPN_AWG_INVALID_MTU");
        }
        proxy["mtu"] = json!(mtu);
    }
    let mut parsed_peers = Vec::new();
    let mut routes: Vec<((IpAddr, u8), usize)> = Vec::new();
    let mut public_keys = BTreeSet::new();
    let mut keepalive = None;
    for (index, fields) in peers.iter().enumerate() {
        if fields.keys().any(|name| {
            ![
                "publickey",
                "presharedkey",
                "allowedips",
                "endpoint",
                "persistentkeepalive",
            ]
            .contains(&name.as_str())
        }) {
            return Err("VPN_AWG_UNSUPPORTED_OPTION");
        }
        let public = required(fields, "publickey")?;
        key(public)?;
        if !public_keys.insert(public) {
            return Err("VPN_AWG_DUPLICATE_PEER");
        }
        let (server, port) = endpoint(required(fields, "endpoint")?)?;
        let mut peer = json!({"server":server,"port":port,"public-key":public});
        if let Some(value) = fields.get("presharedkey") {
            key(value)?;
            peer["pre-shared-key"] = json!(value);
        }
        let values = list(required(fields, "allowedips")?)?;
        for value in &values {
            let route = prefix(value)?;
            if routes
                .iter()
                .any(|(previous, owner)| *owner != index && overlap(route, *previous))
            {
                return Err("VPN_AWG_OVERLAPPING_PEERS");
            }
            routes.push((route, index));
        }
        peer["allowed-ips"] = json!(values);
        let current = fields
            .get("persistentkeepalive")
            .map(|s| number(s, 65535))
            .transpose()?
            .unwrap_or(0);
        if let Some(previous) = keepalive {
            if current != previous {
                return Err("VPN_AWG_PEER_KEEPALIVE_DIFFERS");
            }
        }
        keepalive = Some(current);
        parsed_peers.push(peer);
    }
    // Mihomo has one keepalive value for all peers and no range representation.
    proxy["persistent-keepalive"] = json!(keepalive.unwrap_or(0));
    proxy["peers"] = json!(parsed_peers);
    let v3 = v3_keys.iter().any(|(k, _)| interface.contains_key(*k));
    let has_awg = v3
        || numeric
            .iter()
            .chain(headers.iter())
            .chain(signatures.iter())
            .any(|k| interface.contains_key(*k));
    if has_awg {
        let mut awg = Map::new();
        awg.insert("version".into(), json!(if v3 { 3 } else { 2 }));
        for name in numeric {
            if let Some(value) = interface.get(name) {
                let max = if name.starts_with('s') {
                    65535
                } else {
                    u32::MAX as u64
                };
                awg.insert(name.into(), json!(number(value, max)?));
            }
        }
        let get_num = |name: &str| awg.get(name).and_then(Value::as_u64).unwrap_or(0);
        if get_num("jmin") > get_num("jmax") || get_num("jmax") > 65507 {
            return Err("VPN_AWG_INVALID_JUNK_SIZE");
        }
        let mut used_headers = Vec::new();
        for (index, name) in headers.iter().enumerate() {
            let bounds = if let Some(value) = interface.get(*name) {
                awg.insert((*name).into(), json!(value));
                range(value, u32::MAX as u64)?
            } else {
                ((index + 1) as u64, (index + 1) as u64)
            };
            if used_headers
                .iter()
                .any(|(a, b)| bounds.0 <= *b && *a <= bounds.1)
            {
                return Err("VPN_AWG_OVERLAPPING_HEADERS");
            }
            used_headers.push(bounds);
        }
        for name in signatures {
            if let Some(value) = interface.get(name) {
                signature(value, v3)?;
                awg.insert(name.into(), json!(value));
            }
        }
        for (name, target) in v3_keys {
            if let Some(value) = interface.get(name) {
                let val = match name {
                    "headerprotectionkey" => {
                        key(value)?;
                        for name in ["s1", "s2", "s3", "s4"] {
                            if awg.get(name).and_then(Value::as_u64).unwrap_or(0) < 12 {
                                return Err("VPN_AWG_HEADER_PADDING_REQUIRED");
                            }
                        }
                        json!(value)
                    }
                    "randomtrailers" | "disablecookies" => json!(flag(value)?),
                    _ => {
                        range(value, u32::MAX as u64)?;
                        json!(value)
                    }
                };
                awg.insert(target.into(), val);
            }
        }
        proxy["amnezia-wg-option"] = Value::Object(awg);
    }
    Ok(Parsed {
        protocol: protocol(&proxy),
        proxy,
        warnings,
    })
}
