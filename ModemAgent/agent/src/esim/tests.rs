use super::*;
use std::collections::VecDeque;
use std::io::Cursor;

fn snapshot(rows: &[(&str, &str)]) -> Snapshot {
    Snapshot::parse(json!({"ok":true,"eid":"89000000000000000000000000000000","profiles":rows.iter().map(|(id,state)|
        json!({"iccid":id,"isdp_aid":null,"state":state,"enabled":*state=="enabled",
            "nickname":null,"service_provider":"Synthetic fixture","name":null})).collect::<Vec<_>>()})).unwrap()
}
const ONE: &str = "890000000000000001";
const TWO: &str = "890000000000000002";
fn request(op: &str, before: &Snapshot) -> Request {
    let mut v = json!({"protocol":1,"operation":op,"expected_snapshot":before});
    match op {
        "download" => v["activation_code"] = json!("LPA:1$smdp.example$SYNTHETIC"),
        "enable" | "delete" => v["iccid"] = json!(ONE),
        _ => (),
    }
    if op == "delete" {
        v["confirm_delete"] = json!(true);
    }
    serde_json::from_value(v).unwrap()
}

#[test]
fn rejects_ambiguous_inventory_and_mismatched_state() {
    let mut s = snapshot(&[(ONE, "disabled")]);
    s.profiles.push(s.profiles[0].clone());
    assert!(s.validate().is_err());
    let mut s = snapshot(&[(ONE, "disabled"), (TWO, "disabled")]);
    for p in &mut s.profiles {
        p.isdp_aid = Some("AA00".into());
    }
    assert!(s.validate().is_err());
    let mut s = snapshot(&[(ONE, "unknown")]);
    s.profiles[0].enabled = true;
    assert!(s.validate().is_err());
    assert!(Snapshot::parse(json!({"ok":true,"eid":"8900","profiles":[]})).is_err());
}

#[test]
fn request_validation_before_any_device_action() {
    let before = snapshot(&[]);
    let mut r = request("download", &before);
    assert!(r.validate().is_ok());
    for code in [
        "LPA:1$127.0.0.1$x",
        "LPA:1$user@smdp.example$x",
        "LPA:1$smdp.example:80$x",
        "LPA:1$smdp.example$",
        "LPA:1$smdp.example$x\n",
        "secret",
    ] {
        r.activation_code = Some(code.into());
        assert!(r.validate().is_err());
    }
    let mut r = request("delete", &snapshot(&[(ONE, "disabled")]));
    r.confirm_delete = Some(false);
    assert!(r.validate().is_err());
    r.confirm_delete = Some(true);
    r.protocol = 2;
    assert!(r.validate().is_err());
}

#[test]
fn launcher_surface_excludes_download_delete_and_auth_material() {
    assert!(launcher_request(json!({"protocol":1,"operation":"list"})).is_ok());
    let s = snapshot(&[(ONE, "disabled")]);
    assert!(launcher_request(
        json!({"protocol":1,"operation":"enable","expected_snapshot":s,"iccid":ONE})
    )
    .is_ok());
    for v in [
        json!({"protocol":1,"operation":"list","password":"SYNTHETIC_SECRET"}),
        json!({"protocol":1,"operation":"list","token":"SYNTHETIC_SECRET"}),
        json!({"protocol":1,"operation":"enable","iccid":ONE}),
        json!({"protocol":1,"operation":"delete","expected_snapshot":s,"iccid":ONE,"confirm_delete":true}),
        json!({"protocol":1,"operation":"download","expected_snapshot":s,"activation_code":"LPA:1$smdp.example$SYNTHETIC_SECRET"}),
    ] {
        let error = launcher_request(v).err().unwrap();
        assert!(!format!("{error:?}").contains("SYNTHETIC_SECRET"));
    }
}

#[test]
fn refresh_and_identifier_match_pinned_cli() {
    let mut before = snapshot(&[(ONE, "disabled")]);
    let r = request("enable", &before);
    assert_eq!(
        r.arguments(&before).unwrap(),
        args(&["profile", "enable", ONE, "0"])
    );
    before.profiles[0].isdp_aid = Some("00112233445566778899AABBCCDDEEFF".into());
    assert_eq!(
        r.arguments(&before).unwrap()[2],
        "00112233445566778899AABBCCDDEEFF"
    );
    before.profiles[0].isdp_aid = Some("AABB".into());
    before.profiles[0].state = "unknown".into();
    assert_eq!(
        r.arguments(&before).unwrap(),
        args(&["profile", "enable", ONE, "0"])
    );
    let r = request("delete", &before);
    assert!(r.arguments(&before).is_err());
}

#[test]
fn enable_existing_profile_uses_zero_refresh_with_another_active_profile() {
    let mut before = snapshot(&[(ONE, "disabled"), (TWO, "enabled")]);
    let r = request("enable", &before);
    before.validate().unwrap();
    assert_eq!(
        r.arguments(&before).unwrap(),
        args(&["profile", "enable", ONE, "0"])
    );
    let aid = "00112233445566778899AABBCCDDEEFF";
    before.profiles[0].isdp_aid = Some(aid.into());
    assert_eq!(
        r.arguments(&before).unwrap(),
        args(&["profile", "enable", aid, "0"])
    );
}

#[test]
fn exact_mutation_postconditions() {
    let before = snapshot(&[(ONE, "disabled")]);
    let dl = request("download", &before);
    assert!(dl.postcondition(&before, &snapshot(&[(ONE, "disabled"), (TWO, "disabled")])));
    assert!(!dl.postcondition(&before, &snapshot(&[(ONE, "enabled"), (TWO, "disabled")])));
    assert!(!dl.postcondition(&before, &snapshot(&[(ONE, "disabled"), (TWO, "enabled")])));
    assert!(!dl.postcondition(&before, &before));
    let en = request("enable", &before);
    assert!(en.postcondition(&before, &snapshot(&[(ONE, "enabled")])));
    assert!(!en.postcondition(&before, &snapshot(&[(ONE, "enabled"), (TWO, "enabled")])));
    let del = request("delete", &before);
    assert!(del.postcondition(&before, &snapshot(&[])));
    assert!(!del.postcondition(&before, &snapshot(&[(TWO, "disabled")])));
    let mut other = snapshot(&[(ONE, "enabled")]);
    other.eid.replace_range(31..32, "1");
    assert!(!en.postcondition(&before, &other));
}

#[test]
fn notification_zero_handling_never_prunes_previous_queue() {
    let none = BTreeSet::new();
    assert_eq!(
        notification_arguments(&none, &[0].into()),
        Some(args(&["notification", "process", "-a", "-r"]))
    );
    assert_eq!(notification_arguments(&[5].into(), &[0].into()), None);
    assert_eq!(
        notification_arguments(&[5].into(), &[0, 7].into()),
        Some(args(&["notification", "process", "-r", "7"]))
    );
    for value in [
        json!({"data":[{"seqNumber":true}]}),
        json!({"data":[{"seqNumber":1.0}]}),
        json!({"data":[{"seqNumber":-1}]}),
        json!({"data":[{"seqNumber":4294967296u64}]}),
        json!({"data":[{"seqNumber":1},{"seqNumber":1}]}),
    ] {
        assert!(sequence_numbers(&value).is_err());
    }
}

#[test]
fn https_envelope_allowlist_and_body_limits() {
    let good = json!({"url":"https://smdp.example:443/path?x=1","tx":"7B7D","headers":["Content-Type: application/json","X-Admin-Protocol: gsma/rsp/v2.2.0"]});
    assert!(model::validate_http_payload(&good).is_ok());
    for url in [
        "http://smdp.example/",
        "https://127.0.0.1/",
        "https://[::1]/",
        "https://smdp.example:444/",
        "https://user@smdp.example/",
        "https://smdp.example/#frag",
        "https://smdp.example\\@evil.example/",
        "https://smdp.example/\r\nx",
    ] {
        let mut v = good.clone();
        v["url"] = json!(url);
        assert!(model::validate_http_payload(&v).is_err());
    }
    for h in [
        "Host: evil.example",
        "Connection: close",
        "Authorization: secret",
        "Content-Type: x\r\ny",
    ] {
        let mut v = good.clone();
        v["headers"] = json!([h]);
        assert!(model::validate_http_payload(&v).is_err());
    }
    let mut v = good.clone();
    v["tx"] = json!("f");
    assert!(model::validate_http_payload(&v).is_err());
    v["tx"] = json!("00".repeat(MAX_BODY + 1));
    assert!(model::validate_http_payload(&v).is_err());
}

#[test]
fn relay_requires_exact_positive_id_and_hex_response() {
    let payload = json!({"url":"https://smdp.example/x","tx":"","headers":[]});
    for (reply, ok) in [
        (
            json!({"type":"http_response","id":1,"rcode":200,"rx":"7b7d"}),
            true,
        ),
        (
            json!({"type":"http_response","id":1,"rcode":0,"rx":""}),
            true,
        ),
        (
            json!({"type":"http_response","id":2,"rcode":200,"rx":""}),
            false,
        ),
        (
            json!({"type":"http_response","id":1,"rcode":0,"rx":"00"}),
            false,
        ),
        (
            json!({"type":"http_response","id":1,"rcode":true,"rx":""}),
            false,
        ),
    ] {
        let mut input = Cursor::new(format!("{reply}\n").into_bytes());
        let mut output = Vec::new();
        let mut rpc = Rpc {
            input: &mut input,
            output: &mut output,
            next_id: 1,
            trace: None,
        };
        assert_eq!(rpc.http(&payload).is_ok(), ok);
        let emitted: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(emitted["id"], 1);
    }
}

#[derive(Default)]
struct FakeRelay {
    stages: Vec<&'static str>,
}
impl Relay for FakeRelay {
    fn http(&mut self, _: &Value) -> Result<Value> {
        panic!("no HTTP expected")
    }
    fn progress(&mut self, stage: &'static str) -> Result<()> {
        self.stages.push(stage);
        Ok(())
    }
}
struct FakeRuntime {
    snapshots: VecDeque<Snapshot>,
    results: VecDeque<Result<Value>>,
    commands: Vec<Vec<String>>,
    begins: usize,
    ends: usize,
    fail_begin: bool,
    fail_end: Option<usize>,
    end_error: Option<Error>,
    radio_calls: usize,
    fail_radio: bool,
    fail_radio_ready: bool,
}
impl FakeRuntime {
    fn new(before: Snapshot, after: Snapshot, results: Vec<Result<Value>>) -> Self {
        Self {
            snapshots: [before, after.clone(), after].into(),
            results: results.into(),
            commands: vec![],
            begins: 0,
            ends: 0,
            fail_begin: false,
            fail_end: None,
            end_error: None,
            radio_calls: 0,
            fail_radio: false,
            fail_radio_ready: false,
        }
    }
}
impl Runtime for FakeRuntime {
    fn snapshot(&mut self) -> Result<Snapshot> {
        Ok(self
            .snapshots
            .pop_front()
            .expect("bounded snapshot fixture"))
    }
    fn begin(&mut self, _: &Snapshot) -> Result<()> {
        self.begins += 1;
        if self.fail_begin {
            Err(Error::new("snapshot_changed"))
        } else {
            Ok(())
        }
    }
    fn command(&mut self, a: &[String], _: &mut dyn Relay) -> Result<Value> {
        self.commands.push(a.to_vec());
        self.results.pop_front().expect("no autoretry")
    }
    fn end(&mut self) -> Result<()> {
        self.ends += 1;
        if self.fail_end == Some(self.ends) {
            Err(self
                .end_error
                .take()
                .unwrap_or_else(|| Error::new("bridge_cleanup_failed")))
        } else {
            Ok(())
        }
    }
    fn radio_ready(&mut self) -> Result<()> {
        if self.fail_radio_ready {
            Err(Error::new("radio_not_online"))
        } else {
            Ok(())
        }
    }
    fn refresh_modem(&mut self, _: &str, _: &mut dyn Relay) -> Result<()> {
        assert_eq!(
            self.begins, self.ends,
            "radio cannot begin while bridge is open"
        );
        self.radio_calls += 1;
        if self.fail_radio {
            Err(Error::new("modem_iccid_mismatch").radio(true))
        } else {
            Ok(())
        }
    }
}
fn ok() -> Result<Value> {
    Ok(json!({"code":0}))
}
fn queue(ids: &[u32]) -> Result<Value> {
    Ok(json!({"code":0,"data":ids.iter().map(|n|json!({"seqNumber":n})).collect::<Vec<_>>()}))
}

#[test]
fn mutation_has_two_guards_one_attempt_and_fresh_postcondition() {
    let before = snapshot(&[(ONE, "disabled")]);
    let after = snapshot(&[(ONE, "enabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(before.clone(), after, vec![queue(&[]), ok(), queue(&[])]);
    let out = perform(&r, &mut rt, &mut FakeRelay::default()).unwrap();
    assert!(out.changed);
    assert!(!out.notifications_pending);
    assert_eq!((rt.begins, rt.ends), (2, 2));
    assert_eq!(
        rt.commands,
        vec![
            args(&["notification", "list"]),
            args(&["profile", "enable", ONE, "0"]),
            args(&["notification", "list"])
        ]
    );
    let mut stale = r;
    stale.expected_snapshot.as_mut().unwrap().profiles.clear();
    let mut rt = FakeRuntime::new(before.clone(), before, vec![]);
    assert!(perform(&stale, &mut rt, &mut FakeRelay::default()).is_err());
    assert_eq!(rt.begins, 0);
    assert!(rt.commands.is_empty());
}

#[test]
fn mutation_failure_never_retries_and_returns_verified_snapshot() {
    let before = snapshot(&[(ONE, "disabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(
        before.clone(),
        before,
        vec![queue(&[]), Err(Error::new("lpac_failed"))],
    );
    let e = perform(&r, &mut rt, &mut FakeRelay::default())
        .err()
        .unwrap();
    assert_eq!(e.code, "lpac_failed");
    assert!(e.snapshot.is_some());
    assert_eq!(rt.ends, 1);
    assert_eq!(rt.commands.len(), 2);
    assert_eq!(rt.radio_calls, 0);
}

#[test]
fn enable_cycle_runs_only_after_closed_bridge_and_card_postcondition() {
    let before = snapshot(&[(ONE, "disabled"), (TWO, "enabled")]);
    let after = snapshot(&[(ONE, "enabled"), (TWO, "disabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(
        before.clone(),
        after.clone(),
        vec![queue(&[]), ok(), queue(&[])],
    );
    let result = perform(&r, &mut rt, &mut FakeRelay::default()).unwrap();
    assert_eq!(rt.radio_calls, 1);
    assert_eq!(rt.commands[1], args(&["profile", "enable", ONE, "0"]));
    assert_eq!(
        rt.commands
            .iter()
            .filter(|a| a.first().is_some_and(|x| x == "profile"))
            .count(),
        1
    );
    let (value, exit) = final_value(Ok(result));
    assert_eq!(exit, 0);
    assert_eq!(value["modem_verified"], true);
    assert_eq!(value["radio_restored"], true);
    let mut rt = FakeRuntime::new(before, after, vec![queue(&[]), ok()]);
    rt.fail_end = Some(1);
    assert_eq!(
        perform(&r, &mut rt, &mut FakeRelay::default())
            .err()
            .unwrap()
            .code,
        "bridge_cleanup_failed"
    );
    assert_eq!(rt.radio_calls, 0);
}

#[test]
fn already_enabled_refreshes_modem_without_profile_command() {
    let before = snapshot(&[(ONE, "enabled"), (TWO, "disabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(before.clone(), before, vec![]);
    let result = perform(&r, &mut rt, &mut FakeRelay::default()).unwrap();
    assert!(!result.changed);
    assert_eq!(result.modem_verified, Some(true));
    assert_eq!(rt.radio_calls, 1);
    assert_eq!(rt.begins, 0);
    assert!(rt.commands.is_empty());
}

#[test]
fn radio_guard_fails_before_mutation_and_cycle_error_keeps_snapshot() {
    let before = snapshot(&[(ONE, "disabled")]);
    let after = snapshot(&[(ONE, "enabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(before.clone(), after.clone(), vec![]);
    rt.fail_radio_ready = true;
    assert_eq!(
        perform(&r, &mut rt, &mut FakeRelay::default())
            .err()
            .unwrap()
            .code,
        "radio_not_online"
    );
    assert_eq!(rt.begins, 0);
    assert!(rt.commands.is_empty());
    let mut rt = FakeRuntime::new(before, after, vec![queue(&[]), ok()]);
    rt.fail_radio = true;
    let error = perform(&r, &mut rt, &mut FakeRelay::default())
        .err()
        .unwrap();
    assert_eq!(error.code, "modem_iccid_mismatch");
    assert!(error.snapshot.is_some());
    let (value, exit) = final_value(Err(error));
    assert_eq!(exit, 1);
    assert_eq!(value["radio_restored"], true);
    assert_eq!(value["modem_verified"], false);
    assert_eq!(rt.radio_calls, 1);
    assert_eq!(rt.commands.len(), 2);
}

#[test]
fn post_cycle_card_change_is_not_success_and_no_mutation_retry() {
    let before = snapshot(&[(ONE, "disabled")]);
    let after = snapshot(&[(ONE, "enabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(before.clone(), after, vec![queue(&[]), ok()]);
    *rt.snapshots.back_mut().unwrap() = before;
    let error = perform(&r, &mut rt, &mut FakeRelay::default())
        .err()
        .unwrap();
    assert_eq!(error.code, "postcondition_failed");
    assert_eq!(error.radio_restored, Some(true));
    assert_eq!(rt.radio_calls, 1);
    assert_eq!(rt.commands.len(), 2);
}

#[test]
fn notification_failure_keeps_confirmed_change_but_cleanup_failure_is_explicit() {
    let before = snapshot(&[(ONE, "disabled")]);
    let after = snapshot(&[(ONE, "enabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(
        before.clone(),
        after.clone(),
        vec![queue(&[]), ok(), Err(Error::new("lpac_failed"))],
    );
    let out = perform(&r, &mut rt, &mut FakeRelay::default()).unwrap();
    assert!(out.changed && out.notifications_pending);
    let mut rt = FakeRuntime::new(before, after, vec![queue(&[]), ok(), queue(&[])]);
    rt.fail_end = Some(2);
    let e = perform(&r, &mut rt, &mut FakeRelay::default())
        .err()
        .unwrap();
    assert_eq!(e.code, "notification_cleanup_failed");
    assert!(e.snapshot.is_some());
}

#[test]
fn notification_cleanup_preserves_unknown_channel_and_first_component_cause() {
    for (cleanup_code, expected_code) in [
        ("card_cleanup_unknown", "card_cleanup_unknown"),
        ("bridge_cleanup_failed", "notification_cleanup_failed"),
    ] {
        let before = snapshot(&[(ONE, "disabled")]);
        let after = snapshot(&[(ONE, "enabled")]);
        let r = request("enable", &before);
        let mut rt = FakeRuntime::new(
            before,
            after.clone(),
            vec![queue(&[]), ok(), queue(&[])],
        );
        rt.fail_end = Some(2);
        rt.end_error = Some(Error::new(cleanup_code).component(Some("qmi_open_unknown")));
        let error = perform(&r, &mut rt, &mut FakeRelay::default()).err().unwrap();
        assert_eq!(error.code, expected_code);
        assert_eq!(error.component_error, Some("qmi_open_unknown"));
        assert_eq!(
            serde_json::to_value(error.snapshot.as_ref().unwrap()).unwrap(),
            serde_json::to_value(&after).unwrap()
        );
        assert_eq!(rt.begins, 2);
        assert_eq!(rt.ends, 2);
        assert_eq!(rt.radio_calls, 1);
        assert_eq!(rt.commands.len(), 3, "no command or mutation retry");
        assert_eq!(rt.commands.iter().filter(|args| args.get(1).map(String::as_str) == Some("enable")).count(), 1);
        let (result, exit) = final_value(Err(error));
        assert_eq!(exit, 1);
        assert_eq!(result["error"], expected_code);
        assert_eq!(result["component_error"], "qmi_open_unknown");
        assert_eq!(result["snapshot"], serde_json::to_value(&after).unwrap());
    }
}

#[test]
fn bridge_handshake_mismatch_prevents_every_lpac_command() {
    let before = snapshot(&[(ONE, "disabled")]);
    let r = request("enable", &before);
    let mut rt = FakeRuntime::new(before.clone(), before, vec![]);
    rt.fail_begin = true;
    assert!(perform(&r, &mut rt, &mut FakeRelay::default()).is_err());
    assert!(rt.commands.is_empty());
}

#[test]
fn line_boundaries_and_fixed_error_output() {
    assert!(children::read_json(&mut Cursor::new(b"{}".to_vec())).is_err());
    assert!(children::read_json(&mut Cursor::new(vec![b' '; MAX_LINE + 1])).is_err());
    let (value, status) = final_value(Err(Error::new("lpac_failed")));
    assert_eq!(status, 1);
    assert_eq!(
        value,
        json!({"type":"result","ok":false,"error":"lpac_failed",
            "card":{"kind":"unknown","management":"unknown",
                "reason":"operation_failed","cleanup_confirmed":false}})
    );
    assert!(resources::verify().is_ok());
}

#[test]
fn card_check_empty_euicc_is_confirmed_without_extra_card_operations() {
    let before = snapshot(&[]);
    let r: Request = serde_json::from_value(json!({"protocol":1,"operation":"list"})).unwrap();
    let mut runtime = FakeRuntime::new(before.clone(), before.clone(), vec![]);
    let result = perform(&r, &mut runtime, &mut FakeRelay::default()).unwrap();
    let (value, exit) = final_value(Ok(result));
    assert_eq!(exit, 0);
    assert_eq!(value["card"], json!({
        "kind":"euicc_confirmed", "management":"available",
        "reason":"eid_and_profiles_read", "cleanup_confirmed":true
    }));
    assert_eq!(value["snapshot"], serde_json::to_value(&before).unwrap());
    assert_eq!(runtime.snapshots.len(), 2, "only the existing snapshot is read");
    assert!(runtime.commands.is_empty());
    assert_eq!((runtime.begins, runtime.ends, runtime.radio_calls), (0, 0, 0));
    assert!(!value["card"].to_string().contains(&before.eid));
}

#[test]
fn card_check_failures_never_claim_plain_sim_absence_or_available_management() {
    for (code, component, reason) in [
        ("card_busy", Some("lock_unavailable"), "busy"),
        ("esim_busy", None, "busy"),
        ("card_open_rejected", Some("qmi_open_rejected"), "open_rejected"),
        ("card_cleanup_unknown", Some("qmi_open_unknown"), "cleanup_unknown"),
        ("snapshot_cleanup_failed", Some("channel_close_failed"), "cleanup_unknown"),
        ("snapshot_failed", Some("qmi_transmit_error"), "read_failed"),
        ("snapshot_failed", Some("snapshot_card_status_error"), "read_failed"),
        ("snapshot_failed", Some("eid_parse_error"), "read_failed"),
        ("snapshot_failed", Some("profiles_parse_error"), "read_failed"),
        ("card_not_ready", None, "not_ready"),
        ("job_deadline_exceeded", None, "read_failed"),
        ("unsupported_firmware", None, "unsupported_device"),
        ("lpac_failed", None, "operation_failed"),
        ("PRIVATE_UNRECOGNIZED_CANARY", None, "operation_failed"),
    ] {
        let (value, exit) = final_value(Err(Error::new(code).component(component)));
        assert_eq!(exit, 1);
        assert_eq!(value["card"], json!({"kind":"unknown", "management":"unknown",
            "reason":reason, "cleanup_confirmed":false}), "{code}");
        assert!(!value["card"].to_string().contains("PRIVATE_UNRECOGNIZED_CANARY"));
    }
}

#[test]
fn card_check_cleanup_uncertainty_wins_over_busy_and_preserved_inventory() {
    let before = snapshot(&[(ONE, "disabled")]);
    let error = Error::new("card_busy")
        .component(Some("qmi_open_unknown"))
        .snapshot(before.clone());
    let (value, exit) = final_value(Err(error));
    assert_eq!(exit, 1);
    assert_eq!(value["card"]["kind"], "unknown");
    assert_eq!(value["card"]["reason"], "cleanup_unknown");
    assert_eq!(value["card"]["cleanup_confirmed"], false);
    assert_eq!(value["snapshot"], serde_json::to_value(before).unwrap());
}

#[test]
fn card_check_invalid_success_snapshot_is_not_a_positive_detection() {
    let mut malformed = snapshot(&[]);
    malformed.eid = "INVALID_EID".into();
    let (value, exit) = final_value(Ok(Outcome {
        snapshot: malformed, changed: false, notifications_pending: false, modem_verified: None,
    }));
    assert_eq!(exit, 1);
    assert_eq!(value["ok"], false);
    assert_eq!(value["card"]["kind"], "unknown");
    assert_eq!(value["card"]["cleanup_confirmed"], false);
}

#[test]
fn embedded_resources_extract_and_remove_only_own_directory() {
    use std::os::unix::fs::PermissionsExt;
    let mut r = resources::Resources::extract().unwrap();
    let dir = r.helper.parent().unwrap().to_owned();
    assert_eq!(
        std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(&r.helper).unwrap().permissions().mode() & 0o777,
        0o500
    );
    r.cleanup().unwrap();
    assert!(!dir.exists());
}

#[test]
fn actual_child_error_closes_stdin_and_waits_for_eof_cleanup() {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::temp_dir().join(format!("esim-eof-fixture-{}", std::process::id()));
    std::fs::create_dir(&path).unwrap();
    let script = path.join("child");
    let marker = path.join("cleaned");
    // The child can only create its marker after seeing EOF. No kill or device IO.
    std::fs::write(&script,format!("#!/bin/sh\nprintf 'not-json\\n'\nwhile IFS= read -r line; do :; done\nprintf cleaned > '{}'\nexit 0\n",marker.display())).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = children::ChildPipe::spawn(&script, &[], false).unwrap();
    assert!(child.read().is_err());
    child.finish().unwrap();
    assert_eq!(std::fs::read(&marker).unwrap(), b"cleaned");
    drop(child);
    std::fs::remove_file(marker).unwrap();
    std::fs::remove_file(script).unwrap();
    std::fs::remove_dir(path).unwrap();
}

#[test]
fn actual_lpac_relay_waits_past_result_and_rejects_boolean_success() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("esim-relay-fixture-{}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    let bridge = dir.join("bridge");
    let lpa = dir.join("lpac");
    let marker = dir.join("bridge-eof");
    let before = snapshot(&[]);
    let encoded = serde_json::to_string(&before).unwrap();
    std::fs::write(&bridge,format!("#!/bin/sh\nIFS= read -r header\nprintf '%s\\n' '{encoded}'\nwhile IFS= read -r line; do\n printf '%s\\n' '{{\"type\":\"apdu\",\"payload\":{{\"ecode\":0}}}}'\ndone\nprintf cleaned > '{}'\n",marker.display())).unwrap();
    std::fs::set_permissions(&bridge, std::fs::Permissions::from_mode(0o700)).unwrap();
    for (code, success) in [("0", true), ("true", false), ("0.0", false)] {
        std::fs::write(&lpa,format!("#!/bin/sh\nprintf '%s\\n' '{{\"type\":\"apdu\",\"payload\":{{\"func\":\"connect\",\"param\":null}}}}'\nIFS= read -r reply\nprintf '%s\\n' '{{\"type\":\"lpa\",\"payload\":{{\"code\":{code}}}}}'\nprintf '%s\\n' '{{\"type\":\"apdu\",\"payload\":{{\"func\":\"disconnect\",\"param\":null}}}}'\nIFS= read -r reply\nexit 0\n")).unwrap();
        std::fs::set_permissions(&lpa, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut runtime = LocalRuntime::new(bridge.clone(), lpa.clone());
        runtime.begin(&before).unwrap();
        assert_eq!(
            runtime
                .command(&args(&["profile", "list"]), &mut FakeRelay::default())
                .is_ok(),
            success
        );
        assert!(!marker.exists()); // Final LPA message alone has not closed the bridge.
        runtime.end().unwrap();
        assert_eq!(std::fs::read(&marker).unwrap(), b"cleaned");
        std::fs::remove_file(&marker).unwrap();
    }
    for f in [bridge, lpa] {
        std::fs::remove_file(f).unwrap();
    }
    std::fs::remove_dir(dir).unwrap();
}

#[test]
fn web_deadline_refuses_late_apdu_and_still_closes_owned_bridge() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};
    let dir = std::env::temp_dir().join(format!("esim-budget-fixture-{}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    let bridge = dir.join("bridge");
    let lpa = dir.join("lpac");
    let marker = dir.join("closed");
    let sent = dir.join("apdu-sent");
    let before = snapshot(&[]);
    let encoded = serde_json::to_string(&before).unwrap();
    std::fs::write(&bridge,format!("#!/bin/sh\nIFS= read -r header\nprintf '%s\\n' '{encoded}'\nwhile IFS= read -r line; do\nprintf sent > '{}'\nprintf '%s\\n' '{{\"type\":\"apdu\",\"payload\":{{\"ecode\":0}}}}'\ndone\nprintf closed > '{}'\n",sent.display(),marker.display())).unwrap();
    std::fs::write(&lpa,"#!/bin/sh\nsleep 0.15\nprintf '%s\\n' '{\"type\":\"apdu\",\"payload\":{\"func\":\"transmit\",\"param\":\"0084000000\"}}'\nIFS= read -r response\nexit 0\n").unwrap();
    for f in [&bridge, &lpa] {
        std::fs::set_permissions(f, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let mut runtime = LocalRuntime::with_deadline(
        bridge.clone(),
        lpa.clone(),
        Instant::now() + Duration::from_millis(100),
    );
    runtime.begin(&before).unwrap();
    assert_eq!(
        runtime
            .command(&args(&["profile", "list"]), &mut FakeRelay::default())
            .unwrap_err()
            .code,
        "job_deadline_exceeded"
    );
    assert!(!sent.exists());
    assert!(!marker.exists());
    runtime.end().unwrap();
    assert_eq!(std::fs::read(&marker).unwrap(), b"closed");
    for f in [bridge, lpa, marker] {
        std::fs::remove_file(f).unwrap();
    }
    std::fs::remove_dir(dir).unwrap();
}

#[test]
fn interactive_rpc_emits_waiting_while_http_reply_is_pending_without_line_interleaving() {
    use std::io::{BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::sync::{mpsc, Arc};
    use std::time::Duration;
    let (client, server) = UnixStream::pair().unwrap();
    let (observed_tx, observed_rx) = mpsc::channel();
    let join = std::thread::spawn(move || {
        let mut client = client;
        let mut waiting = false;
        let mut seq = 0;
        while let Ok(value) = observed_rx.recv_timeout(Duration::from_secs(3)) {
            let value: Value = value;
            if value["type"] == "progress" {
                assert!(value.to_string().find("SYNTHETIC_PRIVATE").is_none());
                let current = value["detail"]["log_seq"].as_u64().unwrap();
                assert!(current > seq);
                seq = current;
                if value["detail"]["event"] == "waiting"
                    && value["detail"]["waiting_for"] == "operator_https"
                {
                    waiting = true;
                    client.write_all(b"{\"type\":\"http_response\",\"id\":1,\"rcode\":200,\"rx\":\"7B7D\"}\n").unwrap();
                    break;
                }
            }
        }
        assert!(waiting);
    });
    std::thread::scope(|scope| {
        let (tx, rx) = mpsc::channel::<trace::Wire>();
        scope.spawn(move || {
            while let Ok(wire) = rx.recv() {
                let value: Value = serde_json::from_slice(&wire.bytes).unwrap(); // Every message remains a complete JSON line.
                let _ = observed_tx.send(value);
                wire.ack.send(true).unwrap();
            }
        });
        let mut output = trace::WireWriter::new(tx);
        let event_writer = output.clone();
        let (trace, heartbeat) = trace::Trace::with_interval(
            Arc::new(move |v| emit(&mut event_writer.clone(), &v)),
            Duration::from_millis(10),
        );
        let mut input = BufReader::new(server);
        let mut rpc = Rpc {
            input: &mut input,
            output: &mut output,
            next_id: 1,
            trace: Some(trace.clone()),
        };
        rpc.progress("downloading").unwrap();
        let response = rpc
            .http(&json!({"url":"https://example.com/SYNTHETIC_PRIVATE","tx":"7B7D","headers":[]}))
            .unwrap();
        assert_eq!(response, json!({"rcode":200,"rx":"7B7D"}));
        drop(rpc);
        drop(heartbeat);
        drop(trace);
        drop(output);
    });
    join.join().unwrap();
}
