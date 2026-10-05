//! Local stdio adapter. The LPA runs on the host; this module owns one card channel.
use crate::euicc::es10;
use crate::qmi::uim::OpenChannelError;
use serde_json::{json, Value};

pub type Result<T> = std::result::Result<T, &'static str>;
pub const MAX_LINE: usize = 262_144;
const MAX_APDU: usize = 65_500;
const MAX_RESPONSE: usize = 2 * 1024 * 1024;

pub trait CardIo {
    fn guard(&mut self) -> Result<()>;
    fn open(&mut self) -> std::result::Result<u8, OpenChannelError>;
    fn ordinary_ready(&mut self) -> Result<bool>;
    fn close(&mut self, channel: u8) -> Result<()>;
    fn transmit(&mut self, channel: u8, command: &[u8]) -> Result<Vec<u8>>;
}

pub trait Device {
    type Card: CardIo;
    fn connect(&mut self) -> Result<Self::Card>;
}

pub fn valid_eid(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| b.is_ascii_digit())
}

pub fn expected_eid(header: &Value) -> Result<String> {
    let obj = header.as_object().ok_or("invalid_header")?;
    if obj.len() != 1 {
        return Err("invalid_header");
    }
    let value = obj
        .get("expected_eid")
        .and_then(Value::as_str)
        .ok_or("invalid_header")?;
    if !valid_eid(value) {
        return Err("invalid_expected_eid");
    }
    Ok(value.to_owned())
}

pub fn decode_hex(text: &str) -> Result<Vec<u8>> {
    if text.len() % 2 != 0 || text.len() / 2 > MAX_APDU || !text.is_ascii() {
        return Err("invalid_hex");
    }
    text.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let a = (pair[0] as char).to_digit(16).ok_or("invalid_hex")?;
            let b = (pair[1] as char).to_digit(16).ok_or("invalid_hex")?;
            Ok(((a << 4) | b) as u8)
        })
        .collect()
}

/// Numeric QMI result metadata is safe to retain; no response bytes, card
/// identifiers, AID, APDU or backend error strings cross this boundary.
fn open_failure_event(error: OpenChannelError) -> Value {
    let (outcome, result, code) = match error {
        OpenChannelError::Rejected {
            qmi_result,
            qmi_error,
        } => ("rejected", Some(qmi_result), Some(qmi_error)),
        OpenChannelError::Unknown {
            qmi_result,
            qmi_error,
        } => ("unknown", qmi_result, qmi_error),
    };
    let mut event = json!({"event":"qmi_open_result", "outcome":outcome});
    if let (Some(result), Some(code)) = (result, code) {
        event["qmi_result"] = json!(result);
        event["qmi_error"] = json!(code);
    }
    event
}

pub struct Session<D: Device> {
    device: D,
    card: Option<D::Card>,
    channel: Option<u8>,
    expected: Option<String>,
    pub cleanup_failed: bool,
    pub operation_failed: bool,
}

impl<D: Device> Session<D> {
    pub fn new(device: D, expected: Option<String>) -> Self {
        Self {
            device,
            card: None,
            channel: None,
            expected,
            cleanup_failed: false,
            operation_failed: false,
        }
    }

    fn connect(&mut self) -> Result<()> {
        if self.card.is_some() || self.channel.is_some() {
            return Err("already_connected");
        }
        if self.cleanup_failed || self.operation_failed {
            return Err("session_failed");
        }
        let mut card = self.device.connect()?;
        card.guard()?;
        self.card = Some(card);
        Ok(())
    }

    fn open(&mut self) -> Result<u8> {
        if self.channel.is_some() {
            return Err("already_open");
        }
        if self.cleanup_failed || self.operation_failed {
            return Err("session_failed");
        }
        let card = self.card.as_mut().ok_or("not_connected")?;
        let channel = match card.open() {
            Ok(channel) => channel,
            Err(error @ OpenChannelError::Rejected { .. }) => {
                eprintln!("{}", open_failure_event(error));
                // This narrow response proves rejection before the card
                // operation. There is no channel to close or lock to retain.
                return Err("qmi_open_rejected");
            }
            Err(error @ OpenChannelError::Unknown { .. }) => {
                eprintln!("{}", open_failure_event(error));
                self.cleanup_failed = true;
                eprintln!("{{\"event\":\"cleanup_unknown\",\"stage\":\"channel_open\"}}");
                return Err("qmi_open_unknown");
            }
        };
        // Retain ownership before validating the returned number, so even an
        // unsupported channel is closed rather than silently lost.
        self.channel = Some(channel);
        // The pinned lpac encoder uses basic-channel CLA coding only. Reject
        // extended channels before any ES10/host APDU; still close our id.
        if !(1..=3).contains(&channel) {
            self.close()?;
            return Err("unsupported_channel");
        }
        Ok(channel)
    }

    pub fn close(&mut self) -> Result<()> {
        if let Some(channel) = self.channel.take() {
            let result = self
                .card
                .as_mut()
                .ok_or("missing_owned_connection")
                .and_then(|c| c.close(channel));
            if result.is_err() {
                // A timed-out Close may have completed remotely. Never retry
                // it: the channel number could have been reused meanwhile.
                self.cleanup_failed = true;
                eprintln!("{{\"event\":\"cleanup_failed\",\"stage\":\"channel_close\"}}");
                return Err("channel_close_failed");
            }
        }
        if self.cleanup_failed {
            Err("card_cleanup_unknown")
        } else {
            Ok(())
        }
    }

    pub fn disconnect(&mut self) -> Result<()> {
        let result = self.close();
        self.card = None;
        result
    }

    fn transmit(&mut self, command: &[u8]) -> Result<Vec<u8>> {
        let channel = self.channel.ok_or("not_open")?;
        self.card
            .as_mut()
            .ok_or("not_connected")?
            .transmit(channel, command)
    }

    fn read_response(&mut self, command: &[u8]) -> Result<Vec<u8>> {
        let mut last_command = command.to_vec();
        let mut response = self.transmit(&last_command)?;
        let mut collected = Vec::new();
        // Same 61xx/6Cxx behavior as pinned upstream ChannelGuard, but bounded
        // memory and no send after the final permitted continuation iteration.
        for attempt in 0..32 {
            let (data, sw) = es10::split_status(&response).map_err(|_| "short_apdu_response")?;
            if collected.len().saturating_add(data.len()) > MAX_RESPONSE {
                return Err("snapshot_response_too_large");
            }
            if sw == 0x9000 {
                collected.extend_from_slice(data);
                return Ok(collected);
            }
            if attempt == 31 {
                return Err("snapshot_continuation_limit");
            }
            let [sw1, sw2] = sw.to_be_bytes();
            match sw1 {
                0x61 => {
                    collected.extend_from_slice(data);
                    last_command = es10::get_response(sw2);
                }
                0x6c => {
                    // Retry the command that produced 6C, including a GET
                    // RESPONSE, preserving earlier 61-chain data. A 6C reply
                    // contributes no data to the completed response.
                    *last_command.last_mut().ok_or("empty_read_command")? = sw2;
                }
                _ => return Err("snapshot_card_status_error"),
            }
            response = self.transmit(&last_command)?;
        }
        Err("snapshot_continuation_limit")
    }

    fn read_eid(&mut self) -> Result<String> {
        let response =
            self.read_response(&es10::get_eid_request().map_err(|_| "eid_command_error")?)?;
        let eid = es10::parse_eid(&response).map_err(|_| "eid_parse_error")?;
        if !valid_eid(&eid) {
            return Err("eid_parse_error");
        }
        if self.expected.as_ref().is_some_and(|v| v != &eid) {
            return Err("eid_mismatch");
        }
        Ok(eid)
    }

    /// An explicit SELECT separates application absence from Open ownership.
    fn select_isdr(&mut self) -> Result<bool> {
        // Keep the ISO CLA and QMI channel TLV consistent even on a modem
        // that does not rewrite the CLA from the optional channel field.
        let channel = self.channel.ok_or("not_open")?;
        if !(1..=3).contains(&channel) {
            return Err("unsupported_channel");
        }
        let mut command = vec![channel, 0xa4, 0x04, 0x0c, es10::ISD_R_AID.len() as u8];
        command.extend_from_slice(&es10::ISD_R_AID);
        let response = self.transmit(&command)?;
        let (data, sw) = es10::split_status(&response).map_err(|_| "short_apdu_response")?;
        // P2=0C requests no response data. Other SWs, trailing data and transport
        // errors remain unknown; never infer ordinary SIM from a failed Open.
        if !data.is_empty() {
            return Err("snapshot_card_status_error");
        }
        match sw {
            0x9000 => Ok(true),
            0x6a82 => Ok(false),
            _ => Err("snapshot_card_status_error"),
        }
    }

    pub fn euicc_snapshot(&mut self) -> Result<Value> {
        let value = self.snapshot()?;
        if value.get("card").is_some() {
            return Err("card_not_euicc");
        }
        Ok(value)
    }

    pub fn snapshot(&mut self) -> Result<Value> {
        let result = (|| {
            self.connect()?;
            self.open()?;
            if !self.select_isdr()? {
                if !self
                    .card
                    .as_mut()
                    .ok_or("not_connected")?
                    .ordinary_ready()?
                {
                    return Err("card_not_ready");
                }
                self.card.as_mut().ok_or("not_connected")?.guard()?;
                return Ok(json!({"ok":true,"card":{"kind":"ordinary_sim",
                    "management":"unavailable","reason":"isdr_not_found","cleanup_confirmed":true}}));
            }
            let eid = self.read_eid()?;
            let data = self.read_response(
                &es10::get_profiles_request().map_err(|_| "profiles_command_error")?,
            )?;
            let profiles = es10::parse_profiles(&data).map_err(|_| "profiles_parse_error")?;
            let rows: Vec<Value> = profiles.iter().map(|p| json!({
                "iccid": p.iccid, "isdp_aid": p.isdp_aid,
                "state": p.state_label(), "enabled": p.is_enabled(),
                "nickname": p.nickname, "service_provider": p.service_provider, "name": p.name
            })).collect();
            // Selection cache is checked again before returning private data.
            self.card.as_mut().ok_or("not_connected")?.guard()?;
            Ok(json!({"ok": true, "eid": eid, "profiles": rows}))
        })();
        let cleanup = self.disconnect();
        if result.is_err() {
            self.operation_failed = true;
        }
        cleanup?;
        result
    }

    fn dispatch(&mut self, message: &Value) -> Result<Value> {
        if message.get("type").and_then(Value::as_str) != Some("apdu") {
            return Err("invalid_envelope");
        }
        let payload = message
            .get("payload")
            .and_then(Value::as_object)
            .ok_or("invalid_envelope")?;
        let func = payload
            .get("func")
            .and_then(Value::as_str)
            .ok_or("invalid_function")?;
        match func {
            "connect" => {
                self.connect()?;
                Ok(json!({"ecode": 0}))
            }
            "disconnect" => {
                self.disconnect()?;
                Ok(json!({"ecode": 0}))
            }
            "logic_channel_close" => {
                self.close()?;
                Ok(json!({"ecode": 0}))
            }
            "logic_channel_open" => {
                let param = payload
                    .get("param")
                    .and_then(Value::as_str)
                    .ok_or("invalid_aid")?;
                if decode_hex(param)?.as_slice() != es10::ISD_R_AID {
                    return Err("aid_not_allowed");
                }
                // Guard again immediately before opening, and bind this owned
                // channel to the expected EID before forwarding host APDUs.
                self.card.as_mut().ok_or("not_connected")?.guard()?;
                let channel = self.open()?;
                let identified = (|| {
                    if !self.select_isdr()? {
                        return Err("card_not_euicc");
                    }
                    self.read_eid()
                })();
                if let Err(error) = identified {
                    self.close()?;
                    return Err(error);
                }
                Ok(json!({"ecode": channel}))
            }
            "transmit" => {
                if self.cleanup_failed || self.operation_failed {
                    return Err("session_failed");
                }
                let param = payload
                    .get("param")
                    .and_then(Value::as_str)
                    .ok_or("invalid_apdu")?;
                let command = decode_hex(param)?;
                if command.len() < 4 {
                    return Err("invalid_apdu");
                }
                let response = self.transmit(&command)?;
                Ok(json!({"ecode": 0, "data": es10::hex(&response)}))
            }
            _ => Err("unsupported_function"),
        }
    }

    pub fn handle(&mut self, message: &Value) -> Value {
        let payload = match self.dispatch(message) {
            Ok(payload) => payload,
            Err(code) => {
                self.operation_failed = true;
                // Only local fixed error codes are emitted; never backend
                // errors, APDUs, EIDs, ICCIDs, profile text or input JSON.
                eprintln!("{}", json!({"event":"operation_failed", "code":code}));
                json!({"ecode": -1})
            }
        };
        json!({"type":"apdu", "payload":payload})
    }
}

impl<D: Device> Drop for Session<D> {
    fn drop(&mut self) {
        let _ = self.disconnect();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::rc::Rc;

    #[derive(Default)]
    struct Counts {
        guards: usize,
        connects: usize,
        opens: usize,
        closes: usize,
        transmissions: usize,
        fail_guard: bool,
        not_ready: bool,
        fail_close: bool,
        fail_open: bool,
        fail_transmit: bool,
        rejected_open: Option<u16>,
        returned_channel: Option<u8>,
        commands: Vec<Vec<u8>>,
        responses: VecDeque<Vec<u8>>,
    }
    struct Mock(Rc<RefCell<Counts>>);
    struct MockCard(Rc<RefCell<Counts>>);
    impl Device for Mock {
        type Card = MockCard;
        fn connect(&mut self) -> Result<MockCard> {
            self.0.borrow_mut().connects += 1;
            Ok(MockCard(self.0.clone()))
        }
    }
    impl CardIo for MockCard {
        fn guard(&mut self) -> Result<()> {
            let mut c = self.0.borrow_mut();
            c.guards += 1;
            if c.fail_guard {
                Err("selection_mismatch")
            } else {
                Ok(())
            }
        }
        fn open(&mut self) -> std::result::Result<u8, OpenChannelError> {
            let mut c = self.0.borrow_mut();
            c.opens += 1;
            if let Some(qmi_error) = c.rejected_open {
                Err(OpenChannelError::Rejected {
                    qmi_result: 1,
                    qmi_error,
                })
            } else if c.fail_open {
                Err(OpenChannelError::unknown())
            } else {
                Ok(c.returned_channel.unwrap_or(1))
            }
        }
        fn ordinary_ready(&mut self) -> Result<bool> {
            Ok(!self.0.borrow().not_ready)
        }
        fn close(&mut self, _: u8) -> Result<()> {
            let mut c = self.0.borrow_mut();
            c.closes += 1;
            if c.fail_close {
                Err("qmi_close_error")
            } else {
                Ok(())
            }
        }
        fn transmit(&mut self, _: u8, cmd: &[u8]) -> Result<Vec<u8>> {
            {
                let mut c = self.0.borrow_mut();
                c.transmissions += 1;
                c.commands.push(cmd.to_vec());
                if c.fail_transmit {
                    return Err("qmi_transmit_error");
                }
                if let Some(response) = c.responses.pop_front() {
                    return Ok(response);
                }
            }
            if cmd == es10::get_eid_request().unwrap() {
                let mut r = vec![0xbf, 0x3e, 0x12, 0x5a, 0x10];
                r.extend([0x11; 16]);
                r.extend([0x90, 0]);
                Ok(r)
            } else if cmd == es10::get_profiles_request().unwrap() {
                Ok(vec![0xbf, 0x2d, 2, 0xa0, 0, 0x90, 0])
            } else {
                Ok(vec![0x90, 0])
            }
        }
    }
    fn setup() -> (Session<Mock>, Rc<RefCell<Counts>>) {
        let c = Rc::new(RefCell::new(Counts::default()));
        (Session::new(Mock(c.clone()), Some("1".repeat(32))), c)
    }
    fn msg(func: &str, param: &str) -> Value {
        json!({"type":"apdu","payload":{"func":func,"param":param}})
    }
    fn open_msg() -> Value {
        msg("logic_channel_open", &es10::hex(&es10::ISD_R_AID))
    }
    #[test]
    fn strict_header_and_hex() {
        assert!(expected_eid(&json!({"expected_eid":"1".repeat(32)})).is_ok());
        for value in [
            json!({"expected_eid":"1".repeat(31)}),
            json!({"expected_eid":"Ａ".repeat(32)}),
            json!({"expected_eid":"1".repeat(32),"x":true}),
        ] {
            assert!(expected_eid(&value).is_err());
        }
        assert!(decode_hex("éé").is_err());
        assert!(decode_hex("0").is_err());
        assert!(decode_hex("xx").is_err());
    }
    #[test]
    fn snapshot_closes_before_return() {
        let (mut s, c) = setup();
        let v = s.snapshot().unwrap();
        assert_eq!(v["profiles"], json!([]));
        assert_eq!(v["eid"], "1".repeat(32));
        assert_eq!(c.borrow().closes, 1);
        assert_eq!(c.borrow().guards, 2);
        assert!(s.card.is_none());
    }
    #[test]
    fn mismatch_stops_before_profile_read() {
        let (mut s, c) = setup();
        s.expected = Some("2".repeat(32));
        assert_eq!(s.snapshot(), Err("eid_mismatch"));
        assert_eq!(c.borrow().transmissions, 2);
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn route_guard_refuses_before_open() {
        let (mut s, c) = setup();
        c.borrow_mut().fail_guard = true;
        assert!(s.snapshot().is_err());
        assert_eq!(c.borrow().connects, 1);
        assert_eq!(c.borrow().opens, 0);
    }
    #[test]
    fn duplicate_connect_and_open_never_overwrite_ownership() {
        let (mut s, c) = setup();
        assert_eq!(s.handle(&msg("connect", ""))["payload"]["ecode"], 0);
        s.handle(&open_msg());
        assert_eq!(s.handle(&msg("connect", ""))["payload"]["ecode"], -1);
        assert_eq!(s.handle(&open_msg())["payload"]["ecode"], -1);
        assert_eq!(c.borrow().connects, 1);
        assert_eq!(c.borrow().opens, 1);
        s.disconnect().unwrap();
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn disconnected_session_can_reconnect() {
        let (mut s, c) = setup();
        for _ in 0..2 {
            s.handle(&msg("connect", ""));
            s.handle(&open_msg());
            s.handle(&msg("disconnect", ""));
        }
        assert_eq!(c.borrow().opens, 2);
        assert_eq!(c.borrow().closes, 2);
        assert!(!s.operation_failed);
    }
    #[test]
    fn foreign_aid_and_basic_channel_refused() {
        let (mut s, c) = setup();
        s.handle(&msg("connect", ""));
        assert_eq!(
            s.handle(&msg("logic_channel_open", "A0000001"))["payload"]["ecode"],
            -1
        );
        assert_eq!(
            s.handle(&msg("transmit", "80CA9F7F00"))["payload"]["ecode"],
            -1
        );
        assert_eq!(c.borrow().opens, 0);
        assert_eq!(c.borrow().transmissions, 0);
    }
    #[test]
    fn drop_closes_owned_channel() {
        let (mut s, c) = setup();
        s.handle(&msg("connect", ""));
        s.handle(&open_msg());
        drop(s);
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn explicit_close_failure_sticky_and_not_retried() {
        let (mut s, c) = setup();
        s.handle(&msg("connect", ""));
        s.handle(&open_msg());
        c.borrow_mut().fail_close = true;
        assert_eq!(s.handle(&msg("disconnect", ""))["payload"]["ecode"], -1);
        assert!(s.cleanup_failed);
        assert_eq!(s.disconnect(), Err("card_cleanup_unknown"));
        drop(s);
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn snapshot_close_failure_never_success() {
        let (mut s, c) = setup();
        c.borrow_mut().fail_close = true;
        assert_eq!(s.snapshot(), Err("channel_close_failed"));
        assert!(s.cleanup_failed);
    }
    #[test]
    fn explicit_open_reject_releases_connection_without_close_or_retry() {
        for error in [1, 71, 82] {
            let (mut session, counts) = setup();
            counts.borrow_mut().rejected_open = Some(error);
            assert_eq!(session.snapshot(), Err("qmi_open_rejected"));
            assert!(!session.cleanup_failed);
            assert!(session.operation_failed);
            assert!(session.card.is_none());
            assert!(session.disconnect().is_ok());
            assert_eq!(session.snapshot(), Err("session_failed"));
            drop(session);
            let c = counts.borrow();
            assert_eq!((c.opens, c.closes, c.transmissions), (1, 0, 0));
        }
    }
    #[test]
    fn bridge_open_reject_is_terminal_and_does_not_retain_lock() {
        let (mut s, c) = setup();
        c.borrow_mut().rejected_open = Some(82);
        s.handle(&msg("connect", ""));
        assert_eq!(s.handle(&open_msg())["payload"]["ecode"], -1);
        assert_eq!(s.handle(&open_msg())["payload"]["ecode"], -1);
        assert!(!s.cleanup_failed);
        assert!(s.disconnect().is_ok());
        assert_eq!(
            (
                c.borrow().opens,
                c.borrow().closes,
                c.borrow().transmissions
            ),
            (1, 0, 0)
        );
    }
    #[test]
    fn open_error_metadata_contains_only_fixed_labels_and_numbers() {
        assert_eq!(
            open_failure_event(OpenChannelError::unknown()),
            json!({"event":"qmi_open_result","outcome":"unknown"})
        );
        assert_eq!(
            open_failure_event(OpenChannelError::Rejected {
                qmi_result: 1,
                qmi_error: 82
            }),
            json!({"event":"qmi_open_result","outcome":"rejected","qmi_result":1,"qmi_error":82})
        );
        assert_eq!(
            open_failure_event(OpenChannelError::Unknown {
                qmi_result: Some(1),
                qmi_error: Some(2)
            }),
            json!({"event":"qmi_open_result","outcome":"unknown","qmi_result":1,"qmi_error":2})
        );
    }
    #[test]
    fn unknown_open_retains_cleanup_failure_without_guessed_close() {
        let (mut s, c) = setup();
        c.borrow_mut().fail_open = true;
        assert_eq!(s.snapshot(), Err("card_cleanup_unknown"));
        assert!(s.cleanup_failed);
        assert_eq!(c.borrow().opens, 1);
        assert_eq!(c.borrow().closes, 0);
    }
    #[test]
    fn extended_channel_closed_before_any_apdu() {
        let (mut s, c) = setup();
        c.borrow_mut().returned_channel = Some(4);
        s.handle(&msg("connect", ""));
        assert_eq!(s.handle(&open_msg())["payload"]["ecode"], -1);
        assert_eq!(c.borrow().closes, 1);
        assert_eq!(c.borrow().transmissions, 0);
        s.disconnect().unwrap();
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn six_c_retries_last_get_response_preserving_prior_data() {
        let (mut s, c) = setup();
        s.connect().unwrap();
        s.open().unwrap();
        c.borrow_mut().responses = VecDeque::from([
            vec![0xaa, 0x61, 2],
            vec![0x6c, 3],
            vec![0xbb, 0xcc, 0xdd, 0x90, 0],
        ]);
        let initial = es10::get_profiles_request().unwrap();
        assert_eq!(
            s.read_response(&initial).unwrap(),
            vec![0xaa, 0xbb, 0xcc, 0xdd]
        );
        assert_eq!(
            c.borrow().commands,
            vec![initial, es10::get_response(2), es10::get_response(3)]
        );
    }
    #[test]
    fn channel_rechecks_eid_before_host_transmit() {
        let (mut s, c) = setup();
        s.handle(&msg("connect", ""));
        s.expected = Some("2".repeat(32));
        assert_eq!(s.handle(&open_msg())["payload"]["ecode"], -1);
        assert_eq!(c.borrow().transmissions, 2);
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn ordinary_sim_select_not_found_is_success_without_eid_or_profiles() {
        let (mut s, c) = setup();
        c.borrow_mut().responses.push_back(vec![0x6a, 0x82]);
        let value = s
            .snapshot()
            .expect("explicit SELECT not found is a normal card result");
        assert_eq!(
            value,
            json!({"ok":true,"card":{"kind":"ordinary_sim",
            "management":"unavailable","reason":"isdr_not_found","cleanup_confirmed":true}})
        );
        assert_eq!(c.borrow().transmissions, 1);
        assert_eq!(c.borrow().closes, 1);
    }
    #[test]
    fn select_status_other_than_not_found_is_unknown_and_closes() {
        let (mut s, c) = setup();
        c.borrow_mut().responses.push_back(vec![0x69, 0x85]);
        assert_eq!(s.snapshot(), Err("snapshot_card_status_error"));
        assert_eq!(c.borrow().transmissions, 1);
        assert_eq!(c.borrow().closes, 1);
    }

    #[test]
    fn ordinary_requires_ready_and_confirmed_close() {
        for (not_ready, fail_close, expected) in [
            (true, false, "card_not_ready"),
            (false, true, "channel_close_failed"),
        ] {
            let (mut session, counts) = setup();
            let mut c = counts.borrow_mut();
            c.not_ready = not_ready;
            c.fail_close = fail_close;
            c.responses.push_back(vec![0x6a, 0x82]);
            drop(c);
            assert_eq!(session.snapshot(), Err(expected));
            assert_eq!(counts.borrow().transmissions, 1);
            assert_eq!(counts.borrow().closes, 1);
        }
    }
    #[test]
    fn malformed_or_transport_select_never_becomes_ordinary() {
        for response in [
            vec![],
            vec![0x6a],
            vec![0, 0x6a, 0x82],
            vec![0x61, 0x10],
            vec![0x6c, 0],
            vec![0x6e, 0],
        ] {
            let (mut session, counts) = setup();
            counts.borrow_mut().responses.push_back(response);
            assert!(session.snapshot().is_err());
            assert_eq!(counts.borrow().transmissions, 1, "no SELECT retries");
            assert_eq!(counts.borrow().closes, 1);
        }
        let (mut session, counts) = setup();
        counts.borrow_mut().fail_transmit = true;
        assert_eq!(session.snapshot(), Err("qmi_transmit_error"));
        assert_eq!(counts.borrow().transmissions, 1);
        assert_eq!(counts.borrow().closes, 1);
    }
    #[test]
    fn repeated_ordinary_reads_close_each_channel_and_bridge_refuses_card() {
        let (mut session, counts) = setup();
        for _ in 0..2 {
            counts.borrow_mut().responses.push_back(vec![0x6a, 0x82]);
            assert_eq!(session.snapshot().unwrap()["card"]["kind"], "ordinary_sim");
        }
        assert_eq!((counts.borrow().opens, counts.borrow().closes), (2, 2));
        counts.borrow_mut().responses.push_back(vec![0x6a, 0x82]);
        assert_eq!(session.euicc_snapshot(), Err("card_not_euicc"));
        assert_eq!(counts.borrow().transmissions, 3);
    }
    #[test]
    fn explicit_select_cla_matches_each_owned_channel() {
        for channel in 1..=3 {
            let (mut session, counts) = setup();
            counts.borrow_mut().returned_channel = Some(channel);
            counts.borrow_mut().responses.push_back(vec![0x6a, 0x82]);
            assert_eq!(session.snapshot().unwrap()["card"]["kind"], "ordinary_sim");
            let c = counts.borrow();
            assert_eq!(&c.commands[0][..5], &[channel, 0xa4, 4, 0x0c, 16]);
            assert_eq!(&c.commands[0][5..], &es10::ISD_R_AID);
            assert_eq!((c.opens, c.closes, c.transmissions), (1, 1, 1));
        }
    }
    #[test]
    fn positive_card_uses_select_eid_profiles_in_order() {
        let (mut session, counts) = setup();
        let value = session.snapshot().unwrap();
        assert!(value.get("card").is_none());
        let commands = &counts.borrow().commands;
        assert_eq!(&commands[0][..5], &[1, 0xa4, 4, 0x0c, 16]);
        assert_eq!(&commands[0][5..], &es10::ISD_R_AID);
        assert_eq!(commands[1], es10::get_eid_request().unwrap());
        assert_eq!(commands[2], es10::get_profiles_request().unwrap());
        assert_eq!(commands.len(), 3);
    }
}
