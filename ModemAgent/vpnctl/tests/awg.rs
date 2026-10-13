#[path = "../src/awg.rs"]
mod awg;

const KEY: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
fn config(v3: bool) -> String {
    format!("[Interface]\nPrivateKey={KEY}\nAddress=10.7.0.2/32, fd00::2/128\nDNS=10.7.0.1, fd00::1\nJc=4\nJmin=40\nJmax=70\nS1=80\nS2=90\nS3=12\nS4=12\nH1=100-109\nH2=200-209\nH3=300-309\nH4=400-409\nI1=<b 0x1234><r 12><t>\n{}[Peer]\nPublicKey={KEY}\nPresharedKey={KEY}\nAllowedIPs=0.0.0.0/0, ::/0\nEndpoint=example.test:51820\nPersistentKeepalive=25\n", if v3 { format!("HeaderProtectionKey={KEY}\nContentPaddingAddition=0-32\nRandomTrailers=on\nDisableCookies=off\nRekeyAfterTime=90-120\n") } else { String::new() })
}
#[test]
fn preserves_both_wire_formats_and_every_secret_without_exposing_in_errors() {
    for v3 in [false, true] {
        let p = awg::parse(&config(v3)).unwrap();
        assert_eq!(p.protocol, if v3 { "amneziawg3.1" } else { "amneziawg2" });
        assert_eq!(p.proxy["private-key"], KEY);
        assert_eq!(p.proxy["peers"][0]["public-key"], KEY);
        assert_eq!(p.proxy["peers"][0]["pre-shared-key"], KEY);
        assert_eq!(
            p.proxy["peers"][0]["allowed-ips"],
            serde_json::json!(["0.0.0.0/0", "::/0"])
        );
        assert_eq!(p.proxy["ip"], "10.7.0.2/32");
        assert_eq!(p.proxy["ipv6"], "fd00::2/128");
        assert_eq!(p.proxy["dns"], serde_json::json!(["10.7.0.1", "fd00::1"]));
        assert_eq!(p.proxy["amnezia-wg-option"]["h1"], "100-109");
        assert_eq!(p.proxy["amnezia-wg-option"]["i1"], "<b 0x1234><r 12><t>");
        if v3 {
            assert_eq!(p.proxy["amnezia-wg-option"]["header-protection-key"], KEY);
            assert_eq!(p.proxy["amnezia-wg-option"]["random-trailers"], true);
            assert_eq!(p.proxy["amnezia-wg-option"]["disable-cookies"], false);
            assert_eq!(p.proxy["amnezia-wg-option"]["rekey-after-time"], "90-120");
        }
        assert_eq!(p.warnings, vec!["VPN_IPV6_GUEST_DISABLED"]);
    }
}
#[test]
fn standard_wireguard_and_v3_are_distinct() {
    let plain=format!("[Interface]\nPrivateKey={KEY}\nAddress=10.0.0.2/32\n[Peer]\nPublicKey={KEY}\nAllowedIPs=0.0.0.0/0\nEndpoint=[2001:db8::1]:1234\n");
    assert_eq!(awg::parse(&plain).unwrap().protocol, "wireguard");
    let p = awg::parse(
        &config(true)
            .replace("RandomTrailers=on\n", "")
            .replace("DisableCookies=off\n", ""),
    )
    .unwrap();
    assert_eq!(p.protocol, "amneziawg3");
}
#[test]
fn prevents_unknown_options_hooks_and_duplicate_or_ambiguous_input() {
    for bad in [
        "PostUp=touch /tmp/private",
        "Table=auto",
        "FwMark=1",
        "ListenPort=12345",
        "PrivateKey=PRIVATE",
        "SaveConfig=true",
        "PersistentKeepalive=3-9",
    ] {
        let s = config(true).replace("[Peer]", &format!("{bad}\n[Peer]"));
        let error = awg::parse(&s).err().unwrap();
        assert!(error.starts_with("VPN_"));
        assert!(!error.contains("PRIVATE"));
    }
    for bad in [
        "PublicKey=PRIVATE",
        "Endpoint=example.test:0",
        "Endpoint=example.test:65536",
        "Endpoint=x;touch:1",
        "AllowedIPs=not-an-ip",
        "PersistentKeepalive=20-30",
    ] {
        let name = bad.split('=').next().unwrap();
        let input = config(true)
            .lines()
            .map(|l| {
                if l.starts_with(&format!("{name}=")) {
                    bad
                } else {
                    l
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(awg::parse(&input).is_err(), "invalid field should fail");
    }
}
#[test]
fn validates_packet_options_and_key_encoding() {
    for (old, new) in [
        ("H1=100-109", "H1=200-300"),
        ("H1=100-109", "H1=4294967296"),
        ("Jmin=40", "Jmin=90"),
        ("Jmax=70", "Jmax=65536"),
        ("S4=12", "S4=11"),
        ("ContentPaddingAddition=0-32", "ContentPaddingAddition=99-1"),
        ("RandomTrailers=on", "RandomTrailers=maybe"),
        ("I1=<b 0x1234><r 12><t>", "I1=<r -1>"),
        ("I1=<b 0x1234><r 12><t>", "I1=<r 65507><t>"),
        ("I1=<b 0x1234><r 12><t>", "I1=<b 0x123>"),
        ("I1=<b 0x1234><r 12><t>", "I1=<unknown>"),
        ("MTU=1280", "MTU=68"),
    ] {
        let input = format!("MTU=1280\n{}", config(true));
        // Insert MTU into the actual interface, not before its section.
        let input = input
            .replace("MTU=1280\n[Interface]", "[Interface]\nMTU=1280")
            .replace(old, new);
        assert!(
            awg::parse(&input).is_err(),
            "packet or key constraint should fail"
        );
    }
    assert!(awg::parse(
        &config(true).replace(KEY, "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQF=")
    )
    .is_err());
    assert!(awg::parse(&config(true).replace("S4=12", "S4=65536")).is_err());
}
#[test]
fn multiple_peers_require_disjoint_routes_and_shared_keepalive() {
    let input = config(false).replace("AllowedIPs=0.0.0.0/0, ::/0", "AllowedIPs=10.0.0.0/8");
    let second="[Peer]\nPublicKey=AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=\nAllowedIPs=192.168.0.0/16\nEndpoint=second.test:51821\nPersistentKeepalive=25\n";
    assert_eq!(
        awg::parse(&(input.clone() + second)).unwrap().proxy["peers"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(
        awg::parse(&(input.clone() + &second.replace("192.168.0.0/16", "10.1.0.0/16"))).is_err()
    );
    assert!(awg::parse(&(input + &second.replace("Keepalive=25", "Keepalive=30"))).is_err());
}
#[test]
fn comments_bom_crlf_ipv6_and_configuration_limits() {
    assert!(awg::parse(
        &("\u{feff}# comment\r\n".to_owned() + &config(true).replace('\n', "\r\n"))
    )
    .is_ok());
    assert!(awg::parse(&config(true).replace("10.7.0.2/32, ", "")).is_err());
    assert!(awg::parse(
        &config(true).replace("10.7.0.2/32, fd00::2/128", "10.7.0.2/32, 10.8.0.2/32")
    )
    .is_err());
    assert!(awg::parse(
        &config(true).replace("DNS=10.7.0.1, fd00::1", "DNS=resolver.example.test")
    )
    .is_err());
    assert!(awg::parse(&" ".repeat(32769)).is_err());
    assert!(awg::parse(&config(true).replace("[Peer]", "[Interface]\n[Peer]")).is_err());
}
