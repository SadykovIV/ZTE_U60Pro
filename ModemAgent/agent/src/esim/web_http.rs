//! Web-only modem HTTPS transport. Desktop RPC still delegates HTTP to its host.
use super::{model, Error, Result, MAX_BODY};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::time::{Duration, Instant};
const CURL: &str = "/usr/bin/curl";
const CURL_HASH: &str = "28ecc46fb6f64ec6c915a2cadfcde8de3f7ce12009056f525fbfaf23d001354d";
const SYSTEM_CA: &str = "/etc/ssl/certs/ca-certificates.crt";

struct CombinedCa(PathBuf);
impl Drop for CombinedCa {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
fn combined_bytes(system: &[u8], gsma: &[u8]) -> Result<Vec<u8>> {
    if system.len() > 1_048_576
        || gsma.len() > 16384
        || !system
            .windows(b"-----BEGIN CERTIFICATE-----".len())
            .any(|s| s == b"-----BEGIN CERTIFICATE-----")
        || !gsma.starts_with(b"-----BEGIN CERTIFICATE-----")
    {
        return Err(Error::new("http_unavailable"));
    }
    let mut data = system.to_vec();
    data.push(b'\n');
    data.extend_from_slice(gsma);
    Ok(data)
}
fn combined_ca(root: &Path) -> Result<CombinedCa> {
    // Keep the modem's normal trust store and add the pinned eSIM PKI only
    // inside this private request directory. No system trust changes.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(SYSTEM_CA)
        .map_err(|_| Error::new("http_unavailable"))?;
    let m = file
        .metadata()
        .map_err(|_| Error::new("http_unavailable"))?;
    if !m.is_file() || m.uid() != 0 || m.mode() & 0o022 != 0 || m.len() > 1_048_576 {
        return Err(Error::new("http_unavailable"));
    }
    let mut system = Vec::new();
    file.take(1_048_577)
        .read_to_end(&mut system)
        .map_err(|_| Error::new("http_unavailable"))?;
    let gsma = std::fs::read(root).map_err(|_| Error::new("http_unavailable"))?;
    let data = combined_bytes(&system, &gsma)?;
    let path = root.with_file_name("https-ca.pem");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .map_err(|_| Error::new("http_unavailable"))?;
    let bundle = CombinedCa(path);
    file.write_all(&data)
        .map_err(|_| Error::new("http_unavailable"))?;
    Ok(bundle)
}

pub fn available() -> bool {
    let Ok(mut file) = std::fs::File::open(CURL) else {
        return false;
    };
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => digest.update(&buffer[..n]),
            Err(_) => return false,
        }
    }
    format!("{:x}", digest.finalize()) == CURL_HASH
}
fn public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || a >= 224
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && ((b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99) || b == 168))
        || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
        || (a == 203 && b == 0 && c == 113))
}
fn public_address(addresses: &[SocketAddr]) -> Result<Ipv4Addr> {
    // Refuse mixed public/private DNS. IPv6-only services fail closed: no NAT64,
    // IPv4-mapped, transition or local-scope IPv6 route can bypass this filter.
    if addresses.is_empty()
        || addresses.iter().any(|a| match a.ip() {
            IpAddr::V4(ip) => !public_v4(ip),
            IpAddr::V6(_) => false,
        })
    {
        return Err(Error::new("http_destination_refused"));
    }
    addresses
        .iter()
        .find_map(|a| match a.ip() {
            IpAddr::V4(ip) if public_v4(ip) => Some(ip),
            _ => None,
        })
        .ok_or(Error::new("http_destination_refused"))
}
fn resolve(host: &str, deadline: Instant) -> Result<Ipv4Addr> {
    let budget = deadline
        .saturating_duration_since(Instant::now())
        .min(Duration::from_secs(10));
    if budget.is_zero() {
        return Err(Error::new("job_deadline_exceeded"));
    }
    let host = host.to_owned();
    let (tx, rx) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("esim-dns".into())
        .spawn(move || {
            let result = (host.as_str(), 443)
                .to_socket_addrs()
                .map(|v| v.take(65).collect::<Vec<_>>());
            let _ = tx.send(result);
        })
        .map_err(|_| Error::new("http_failed"))?;
    let addresses = rx
        .recv_timeout(budget)
        .map_err(|_| Error::new("http_failed"))?
        .map_err(|_| Error::new("http_failed"))?;
    if addresses.len() > 64 {
        return Err(Error::new("http_destination_refused"));
    }
    public_address(&addresses)
}
fn host(payload: &Value) -> Result<String> {
    model::validate_http_payload(payload)?;
    let url = payload["url"]
        .as_str()
        .ok_or(Error::new("invalid_http_request"))?;
    let authority = url
        .strip_prefix("https://")
        .unwrap_or_default()
        .split(['/', '?'])
        .next()
        .unwrap_or_default();
    Ok(authority
        .strip_suffix(":443")
        .unwrap_or(authority)
        .to_ascii_lowercase())
}
fn unhex(s: &str) -> Vec<u8> {
    s.as_bytes()
        .chunks_exact(2)
        .map(|x| {
            let digit = |c: u8| {
                if c.is_ascii_digit() {
                    c - b'0'
                } else {
                    c.to_ascii_lowercase() - b'a' + 10
                }
            };
            digit(x[0]) * 16 + digit(x[1])
        })
        .collect()
}
fn curl_arguments(
    payload: &Value,
    host: &str,
    ip: Ipv4Addr,
    root: &Path,
    seconds: u64,
) -> Result<Vec<String>> {
    if !public_v4(ip) || seconds == 0 {
        return Err(Error::new("http_destination_refused"));
    }
    let mut args = [
        "--disable",
        "--silent",
        "--globoff",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--no-location",
        "--max-redirs",
        "0",
        "--proxy",
        "",
        "--noproxy",
        "*",
        "--request",
        "POST",
        "--connect-timeout",
        "15",
        "--max-time",
    ]
    .map(str::to_owned)
    .to_vec();
    args.extend([
        seconds.to_string(),
        "--max-filesize".into(),
        MAX_BODY.to_string(),
        "--resolve".into(),
        format!("{host}:443:{ip}"),
        "--data-binary".into(),
        "@-".into(),
        "--write-out".into(),
        "\n%{http_code}".into(),
    ]);
    args.extend([
        "--cacert".into(),
        root.to_str()
            .ok_or(Error::new("http_unavailable"))?
            .to_owned(),
    ]);
    for h in payload["headers"]
        .as_array()
        .ok_or(Error::new("invalid_http_request"))?
    {
        let h = h.as_str().ok_or(Error::new("invalid_http_request"))?;
        if !h.is_ascii() || h.bytes().any(|b| !(32..=126).contains(&b)) {
            return Err(Error::new("invalid_http_request"));
        }
        args.extend(["--header".into(), h.to_owned()]);
    }
    args.extend([
        "--url".into(),
        payload["url"]
            .as_str()
            .ok_or(Error::new("invalid_http_request"))?
            .to_owned(),
    ]);
    Ok(args)
}
fn parse_output(bytes: &[u8]) -> Result<Value> {
    if bytes.len() < 4 || bytes.len() > MAX_BODY + 4 || bytes[bytes.len() - 4] != b'\n' {
        return Err(Error::new("http_failed"));
    }
    let status = std::str::from_utf8(&bytes[bytes.len() - 3..])
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .filter(|n| (100..=599).contains(n))
        .ok_or(Error::new("http_failed"))?;
    let rx = bytes[..bytes.len() - 4]
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<String>();
    Ok(json!({"rcode":status,"rx":rx}))
}
pub fn post(payload: &Value, root: &Path, deadline: Instant) -> Result<Value> {
    let deadline = deadline.min(Instant::now() + Duration::from_secs(60));
    let host = host(payload)?;
    if !available() {
        return Err(Error::new("http_unavailable"));
    }
    let ip = resolve(&host, deadline)?;
    let budget = deadline
        .saturating_duration_since(Instant::now())
        .min(Duration::from_secs(60));
    let ca = combined_ca(root)?;
    let args = curl_arguments(payload, &host, ip, &ca.0, budget.as_secs())?;
    let body = unhex(
        payload["tx"]
            .as_str()
            .ok_or(Error::new("invalid_http_request"))?,
    );
    let mut command = Command::new(CURL);
    command
        .args(args)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    // Only this short-lived network process may be killed on timeout/overflow.
    // The QMI bridge is never passed to the generic process runner.
    let output = process_runner::output(&mut command, Some(&body), budget, MAX_BODY + 4)
        .map_err(|_| Error::new("http_failed"))?;
    if !output.status.success() {
        return Err(Error::new("http_failed"));
    }
    parse_output(&output.stdout)
}
pub fn check() -> Value {
    // No card/firmware read and no URL supplied by the caller. Body is empty.
    let mut resources = match super::resources::Resources::extract() {
        Ok(v) => v,
        Err(e) => return json!({"ok":false,"error":e.code}),
    };
    let result = post(
        &json!({"url":"https://rsp.invigo.com/","tx":"","headers":[]}),
        &resources.gsma_root,
        Instant::now() + Duration::from_secs(60),
    );
    let cleaned = resources.cleanup().is_ok();
    match result {
        Ok(v) => {
            json!({"ok":cleaned,"status":v["rcode"],"body_bytes":v["rx"].as_str().map_or(0,|s|s.len()/2),"cleanup":cleaned})
        }
        Err(e) => json!({"ok":false,"error":e.code,"cleanup":cleaned}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn blocks_nonpublic_dns_and_pins_public_ip() {
        for s in [
            "0.0.0.0",
            "10.1.2.3",
            "127.0.0.1",
            "169.254.1.1",
            "172.31.0.1",
            "192.168.0.1",
            "100.64.1.1",
            "192.0.0.8",
            "192.0.2.1",
            "192.88.99.1",
            "198.19.0.1",
            "198.51.100.1",
            "203.0.113.1",
            "255.255.255.255",
        ] {
            assert!(!public_v4(s.parse().unwrap()), "{s}");
        }
        assert!(public_v4("8.8.8.8".parse().unwrap()));
        assert!(public_address(&[
            "8.8.8.8:443".parse().unwrap(),
            "127.0.0.1:443".parse().unwrap()
        ])
        .is_err());
        assert!(public_address(&["[::ffff:127.0.0.1]:443".parse().unwrap()]).is_err());
    }
    #[test]
    fn curl_policy_no_retry_proxy_redirect_or_insecure_tls() {
        let p = json!({"url":"https://rsp.invigo.com/es9/","tx":"7B7D","headers":["Content-Type: application/json"]});
        let h = host(&p).unwrap();
        let a = curl_arguments(
            &p,
            &h,
            "8.8.8.8".parse().unwrap(),
            Path::new("/tmp/owned/root.pem"),
            60,
        )
        .unwrap();
        assert_eq!(a[0], "--disable");
        assert!(a
            .windows(2)
            .any(|x| x == ["--resolve", "rsp.invigo.com:443:8.8.8.8"]));
        assert!(a
            .windows(2)
            .any(|x| x == ["--cacert", "/tmp/owned/root.pem"]));
        assert!(a.windows(2).any(|x| x == ["--data-binary", "@-"]));
        for forbidden in [
            "--insecure",
            "-k",
            "--retry",
            "--location",
            "--cert",
            "--key",
        ] {
            assert!(!a.iter().any(|x| x == forbidden));
        }
        let mut p = p;
        p["url"] = json!("https://another.example/es9/");
        let h = host(&p).unwrap();
        let a = curl_arguments(
            &p,
            &h,
            "8.8.8.8".parse().unwrap(),
            Path::new("/tmp/owned/root.pem"),
            60,
        )
        .unwrap();
        assert!(a
            .windows(2)
            .any(|x| x == ["--cacert", "/tmp/owned/root.pem"]));
    }
    #[test]
    fn e_sim_ca_extends_system_roots_with_bounds() {
        let system = b"-----BEGIN CERTIFICATE-----\nsystem\n-----END CERTIFICATE-----\n";
        let gsma = b"-----BEGIN CERTIFICATE-----\ngsma\n-----END CERTIFICATE-----\n";
        let bytes = combined_bytes(system, gsma).unwrap();
        assert!(bytes.starts_with(system));
        assert!(bytes.ends_with(gsma));
        assert!(combined_bytes(b"", gsma).is_err());
        assert!(combined_bytes(system, b"missing").is_err());
        assert!(combined_bytes(&vec![b'a'; 1_048_577], gsma).is_err());
    }
    #[test]
    fn bounded_binary_body_and_status_parsing() {
        assert_eq!(
            parse_output(b"\x00\xff\n200").unwrap(),
            json!({"rcode":200,"rx":"00FF"})
        );
        for b in [b"\n000".as_slice(), b"\n999", b"raw error", b"\n20X"] {
            assert!(parse_output(b).is_err());
        }
        assert!(parse_output(&vec![b'x'; MAX_BODY + 5]).is_err());
        assert_eq!(unhex("00aAFf"), vec![0, 170, 255]);
    }
}
