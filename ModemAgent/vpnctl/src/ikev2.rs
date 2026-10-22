//! The native IKEv2 backend is deliberately separate from Mihomo imports.
//! Credentials are data, never shell fragments or user supplied strongSwan config.
use crate::profile::Result;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{net::Ipv4Addr, process::Command, time::Duration};

pub const PRIVATE_NETWORKS: &str = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16";
pub const DIRECTORY: &str = "/data/zte-vpn/ikev2";

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Input {
    pub server: String,
    pub server_id: String,
    pub username: String,
    pub password: Option<String>,
    pub ca_certificate: String,
    pub dns: String,
}

fn host(s: &str) -> bool {
    if s.parse::<Ipv4Addr>().is_ok() { return true; }
    !s.is_empty() && s.len() <= 253 && s.contains('.') &&
        s.split('.').all(|part| !part.is_empty() && part.len() <= 63 &&
            !part.starts_with('-') && !part.ends_with('-') &&
            part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')) &&
        !s.bytes().all(|b| b.is_ascii_digit() || b == b'.')
}

fn certificate(pem: &str) -> Result<()> {
    // A single CA certificate, not a private key, include directive or arbitrary
    // config. OpenSSL does the actual X.509/CA/expiry validation on the device.
    if pem.len() > 64 * 1024 { return Err("VPN_IKEV2_INVALID_CERTIFICATE"); }
    let body = pem.trim().strip_prefix("-----BEGIN CERTIFICATE-----")
        .and_then(|s| s.strip_suffix("-----END CERTIFICATE-----"))
        .ok_or("VPN_IKEV2_INVALID_CERTIFICATE")?;
    let compact: String = body.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    let der = STANDARD.decode(compact).map_err(|_| "VPN_IKEV2_INVALID_CERTIFICATE")?;
    if der.len() < 64 || der[0] != 0x30 { return Err("VPN_IKEV2_INVALID_CERTIFICATE"); }
    Ok(())
}

impl Input {
    pub fn into_proxy(mut self, previous: Option<&Value>) -> Result<Value> {
        self.server = self.server.trim().to_ascii_lowercase();
        self.server_id = self.server_id.trim().to_owned();
        self.username = self.username.trim().to_owned();
        self.dns = self.dns.trim().to_owned();
        if !host(&self.server) { return Err("VPN_IKEV2_INVALID_SERVER"); }
        if !host(&self.server_id) { return Err("VPN_IKEV2_INVALID_ID"); }
        if self.username.is_empty() || self.username.len() > 256 || self.username.chars().any(char::is_control) {
            return Err("VPN_IKEV2_INVALID_USERNAME");
        }
        let password = self.password.filter(|s| !s.is_empty())
            .or_else(|| previous.and_then(|p| p["password"].as_str()).map(str::to_owned))
            .ok_or("VPN_IKEV2_INVALID_PASSWORD")?;
        if password.len() > 1024 || password.chars().any(char::is_control) {
            return Err("VPN_IKEV2_INVALID_PASSWORD");
        }
        certificate(&self.ca_certificate)?;
        let dns: Ipv4Addr = self.dns.parse().map_err(|_| "VPN_IKEV2_INVALID_DNS")?;
        // DNS is routed through the same negotiated private selectors. The
        // guest subnet belongs to the modem and cannot be a remote DNS subnet.
        if !dns.is_private() || dns.octets()[..3] == [192, 168, 50] {
            return Err("VPN_IKEV2_INVALID_DNS");
        }
        Ok(json!({"type":"ikev2","server":self.server,"server_id":self.server_id,
            "username":self.username,"password":password,
            "ca_certificate":format!("{}\n",self.ca_certificate.trim()),"dns":dns.to_string()}))
    }
}

pub fn is_ikev2(proxy: &Value) -> bool { proxy["type"] == "ikev2" }
pub fn validate(proxy: &Value) -> Result<Value> {
    if !is_ikev2(proxy) { return Err("VPN_IKEV2_INVALID_PROFILE"); }
    let mut settings = proxy.clone();
    settings.as_object_mut().ok_or("VPN_IKEV2_INVALID_PROFILE")?.remove("type");
    serde_json::from_value::<Input>(settings).map_err(|_| "VPN_IKEV2_INVALID_PROFILE")?.into_proxy(None)
}
pub fn redacted(profile: &Value) -> Value {
    let mut result = profile.clone();
    if is_ikev2(&result["proxy"]) {
        if let Some(proxy) = result["proxy"].as_object_mut() {
            let present = proxy.remove("password").is_some();
            proxy.insert("password_set".into(), json!(present));
        }
        result.as_object_mut().unwrap().remove("source_config");
        result.as_object_mut().unwrap().remove("source_uri");
    }
    result
}

pub fn check_certificate(proxy: &Value) -> Result<()> {
    let cert = proxy["ca_certificate"].as_str().ok_or("VPN_IKEV2_INVALID_CERTIFICATE")?;
    let out = process_runner::output(Command::new("/usr/bin/openssl").args([
        "x509", "-inform", "PEM", "-noout", "-text", "-checkend", "0"
    ]), Some(cert.as_bytes()), Duration::from_secs(10), 128 * 1024)
        .map_err(|_| "VPN_IKEV2_UNAVAILABLE")?;
    let text = String::from_utf8_lossy(&out.stdout);
    let lines: Vec<_> = text.lines().collect();
    let is_ca = lines.windows(2).any(|pair| pair[0].trim_start().starts_with("X509v3 Basic Constraints:")
        && pair[1].trim_start().starts_with("CA:TRUE"));
    if !out.status.success() || !is_ca {
        return Err("VPN_IKEV2_INVALID_CERTIFICATE");
    }
    Ok(())
}

// strongSwan settings files support quoted strings with escaped backslashes
// and quotes. Secrets are hexadecimal so punctuation is never syntax.
fn quoted(s: &str) -> String { format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"")) }

pub fn files(proxy: &Value) -> Result<Vec<(&'static str, String)>> {
    let p = validate(proxy)?;
    let field = |name| p[name].as_str().unwrap();
    let secret: String = field("password").as_bytes().iter().map(|b| format!("{b:02x}")).collect();
    let config = format!(r#"connections {{
  zte-ikev2 {{
    version = 2
    remote_addrs = {server}
    vips = 0.0.0.0
    proposals = aes256-sha256-modp2048,aes128-sha256-modp2048,aes256-sha1-modp2048,default
    reauth_time = 0
    dpd_delay = 10s
    keyingtries = 1
    encap = yes
    local {{
      auth = eap-mschapv2
      eap_id = {username}
      id = {username}
    }}
    remote {{
      auth = pubkey
      id = {server_id}
      cacerts = /data/zte-vpn/ikev2/ca.pem
    }}
    children {{
      zte-private {{
        local_ts = dynamic
        remote_ts = {networks}
        if_id_in = 19090
        if_id_out = 19090
        reqid = 19090
        esp_proposals = aes256-sha256,aes128-sha256,aes256-sha1,default
        life_time = 20m
        rekey_time = 17m
        rand_time = 0
        start_action = none
        dpd_action = clear
        close_action = none
        updown = /bin/sh /data/zte-vpn/ikev2-updown.sh
      }}
    }}
  }}
}}
secrets {{
  eap-zte {{
    id = {username}
    secret = 0x{secret}
  }}
}}
"#, server=quoted(field("server")),username=quoted(field("username")),server_id=quoted(field("server_id")),networks=PRIVATE_NETWORKS);
    let strongswan = r#"charon {
  load_modular = no
  load = random nonce aes des sha1 sha2 hmac kdf openssl pem x509 pkcs1 pubkey constraints eap-identity eap-mschapv2 md4 socket-default kernel-netlink vici updown
  syslog {
    daemon {
      default = -1
    }
    auth {
      default = -1
    }
  }
  install_routes = no
  install_virtual_ip_on = zvpn-ipsec
  plugins {
    vici {
      socket = unix:///data/zte-vpn/ikev2/charon.vici
    }
    kernel-netlink {
      install_routes_xfrmi = no
    }
  }
}
"#.to_owned();
    let dhcp = include_str!("../../../MacIMEI/Resources/VPN/dnsmasq.conf")
        .replace("dhcp-option=6,192.168.50.1", &format!("dhcp-option=6,{}", field("dns")));
    Ok(vec![("swanctl.conf", config), ("strongswan.conf", strongswan),
        ("ca.pem", field("ca_certificate").into()), ("dnsmasq.conf", dhcp), ("dns", field("dns").into())])
}

#[cfg(test)]
mod tests {
    use super::*;
    fn input() -> Input {
        let mut bytes = vec![0;128]; bytes[0]=0x30;
        Input{server:"vpn.example.com".into(),server_id:"vpn.example.com".into(),username:"EXAMPLE\\alice".into(),
            password:Some("p#ass\"\\word ${x}".into()),ca_certificate:format!("-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----",STANDARD.encode(bytes)),dns:"10.0.2.1".into()}
    }
    #[test] fn fixed_split_and_escaped_credentials() {
        let proxy=input().into_proxy(None).unwrap();
        let files=files(&proxy).unwrap();
        let swan=&files.iter().find(|(name,_)| *name=="swanctl.conf").unwrap().1;
        assert!(swan.contains(&format!("remote_ts = {PRIVATE_NETWORKS}")));
        assert!(swan.contains("eap_id = \"EXAMPLE\\\\alice\""));
        assert!(swan.contains("secret = 0x"));
        assert!(!swan.contains(proxy["password"].as_str().unwrap()));
        assert!(!swan.contains("remote_ts = 0.0.0.0/0"));
        assert!(swan.contains("cacerts = /data/zte-vpn/ikev2/ca.pem"));
        assert!(files.iter().find(|(name,_)|*name=="dnsmasq.conf").unwrap().1.contains("dhcp-option=6,10.0.2.1"));
    }
    #[test] fn editing_preserves_secret_but_never_returns_it() {
        let proxy=input().into_proxy(None).unwrap();
        let mut update=input();update.password=None;update.server="vpn2.example.com".into();
        assert_eq!(update.clone().into_proxy(Some(&proxy)).unwrap()["password"],proxy["password"]);
        assert_eq!(update.into_proxy(None).unwrap_err(),"VPN_IKEV2_INVALID_PASSWORD");
        let result=redacted(&json!({"id":"test","proxy":proxy}));
        assert!(result["proxy"].get("password").is_none());assert_eq!(result["proxy"]["password_set"],true);
    }
    #[test] fn rejects_config_injection_unverified_ids_and_unroutable_dns() {
        for bad in ["vpn.example.com\ninclude x", "1.2.3.999", "https://vpn.example.com", "x;touch foo"] {
            let mut value=input();value.server=bad.into();assert!(value.into_proxy(None).is_err());
        }
        for bad in ["%any","*.example.com","vpn.example.com\n}"] {
            let mut value=input();value.server_id=bad.into();assert!(value.into_proxy(None).is_err());
        }
        for bad in ["1.1.1.1","127.0.0.1","224.0.0.1","192.168.50.1","10.0.2.1\nscript"] {
            let mut value=input();value.dns=bad.into();assert!(value.into_proxy(None).is_err());
        }
        let mut value=input();value.ca_certificate.push_str("\ninclude /etc/passwd");assert!(value.into_proxy(None).is_err());
        let mut value=input();value.password=Some("secret\n}".into());assert!(value.into_proxy(None).is_err());
    }
    // Optional isolated native-parser fixture. The only credentials are the
    // synthetic values in input(); no catalog or live device config is read.
    #[test] fn native_parser_fixture() {
        let Some(directory) = std::env::var_os("ZTE_IKEV2_PARSER_FIXTURE") else { return; };
        let directory = std::path::PathBuf::from(directory);
        let mut settings = input();
        settings.ca_certificate = std::fs::read_to_string(directory.join("ca.pem")).unwrap();
        let proxy = settings.into_proxy(None).unwrap();
        check_certificate(&proxy).unwrap();
        for (name, text) in files(&proxy).unwrap() { std::fs::write(directory.join(name), text).unwrap(); }
    }
}
