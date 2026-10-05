//! QMI UIM service: card status and the logical-channel/APDU transport that
//! ES10 commands ride on.
//!
//! `UIM_SWITCH_SLOT` is deliberately absent — this agent never remaps slots, so
//! an eUICC probe can never disturb the active SIM. Powering the card off and
//! on is a different thing and is implemented: it is confined to the slot the
//! card is already in, changes no persistent state, and is the only way to make
//! the modem re-read a card whose enabled profile has changed underneath it.

use std::time::Duration;

use super::qrtr::{QrtrClient, SERVICE_UIM};
use super::tlv::{self, Tlv};

const MSG_GET_CARD_STATUS: u16 = 0x002F;
const MSG_GET_SLOT_STATUS: u16 = 0x0047;
const MSG_SEND_APDU: u16 = 0x003B;
const MSG_CLOSE_LOGICAL_CHANNEL: u16 = 0x003F;
const MSG_OPEN_LOGICAL_CHANNEL: u16 = 0x0042;
const MSG_POWER_OFF_SIM: u16 = 0x0030;
const MSG_POWER_ON_SIM: u16 = 0x0031;

/// Logical slot. This agent only ever talks to slot 1: the card is reported as
/// a physical UICC there and slot 2 is not populated on this unit.
const SLOT: u8 = 1;

/// UIM operations are slow (an ES10 exchange is several APDUs) but must not
/// wedge a request thread forever.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

/// Rejection and uncertain ownership must not collapse into a string error.
/// A well-formed failure can still follow a successful card-side Open: the
/// Qualcomm reference implementation can fail allocating its response (2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenChannelError {
    Rejected {
        qmi_result: u16,
        qmi_error: u16,
    },
    Unknown {
        qmi_result: Option<u16>,
        qmi_error: Option<u16>,
    },
}
impl OpenChannelError {
    pub fn unknown() -> Self {
        Self::Unknown {
            qmi_result: None,
            qmi_error: None,
        }
    }
}

fn parse_open_response(tlvs: &[Tlv]) -> Result<u8, OpenChannelError> {
    let results: Vec<_> = tlvs.iter().filter(|t| t.tag == tlv::TLV_RESULT).collect();
    if results.len() != 1 || results[0].value.len() != 4 {
        return Err(OpenChannelError::unknown());
    }
    let value = &results[0].value;
    let result = u16::from_le_bytes([value[0], value[1]]);
    let error = u16::from_le_bytes([value[2], value[3]]);
    let unknown = OpenChannelError::Unknown {
        qmi_result: Some(result),
        qmi_error: Some(error),
    };
    // MSM8909 ca418616 qmi_uim.c:36761..36796 rejects malformed/disabled
    // requests before dispatch; :21308..21312 denies access before Open.
    // NoMemory (2), Internal (3), card failures and unknown errors are NOT
    // proof of no channel. Optional channel/card payload contradicts the
    // narrow pre-operation response shape, so remains uncertain too.
    if result == 1 && matches!(error, 1 | 71 | 82) && tlvs.len() == 1 {
        return Err(OpenChannelError::Rejected {
            qmi_result: result,
            qmi_error: error,
        });
    }
    if result != 0 || error != 0 {
        return Err(unknown);
    }
    for tag in [0x10, 0x11, 0x12] {
        let fields: Vec<_> = tlvs.iter().filter(|t| t.tag == tag).collect();
        if fields.len() > 1 {
            return Err(unknown);
        }
        if let Some(field) = fields.first() {
            let v = &field.value;
            let valid = match tag {
                0x10 => v.len() == 1 && v[0] != 0,
                0x11 => v.len() == 2,
                0x12 => !v.is_empty() && v.len() == 1 + v[0] as usize,
                _ => unreachable!(),
            };
            if !valid {
                return Err(unknown);
            }
        }
    }
    tlv::find(tlvs, 0x10)
        .and_then(|v| v.first())
        .copied()
        .ok_or(unknown)
}

fn unique_field(values: &[Tlv], tag: u8) -> Result<&[u8], String> {
    let mut fields = values.iter().filter(|t| t.tag == tag);
    let first = fields.next().ok_or("required TLV missing")?;
    if fields.next().is_some() {
        return Err("duplicate TLV".into());
    }
    Ok(&first.value)
}
fn checked_result(values: &[Tlv]) -> Result<(), String> {
    if unique_field(values, 2)? != [0, 0, 0, 0] {
        return Err("QMI operation failed".into());
    }
    Ok(())
}
fn open_request() -> [Tlv; 1] {
    [tlv::u8_tlv(0x01, SLOT)]
}

fn selected_slot1(data: &[u8]) -> Result<(), String> {
    let count = *data.first().ok_or("slot status empty")?;
    if !(1..=8).contains(&count) {
        return Err("slot count invalid".into());
    }
    let mut position = 1;
    let mut matched = false;
    for physical in 1..=count {
        let row = data
            .get(position..position + 10)
            .ok_or("slot status truncated")?;
        let card = u32::from_le_bytes(row[..4].try_into().unwrap());
        let active = u32::from_le_bytes(row[4..8].try_into().unwrap());
        let logical = row[8];
        let size = row[9] as usize;
        position += 10;
        data.get(position..position + size)
            .ok_or("slot identifier truncated")?;
        position += size;
        if card > 2 || active > 1 {
            return Err("slot status invalid".into());
        }
        if physical == 1 {
            matched = card == 2 && active == 1 && logical == 1;
        } else if active == 1 && logical == 1 {
            return Err("alternate slot selected".into());
        }
    }
    if position != data.len() || !matched {
        return Err("physical slot1 not selected".into());
    }
    Ok(())
}

pub struct UimClient {
    qmi: QrtrClient,
}

/// One application reported inside a card's status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardApplication {
    pub app_type: u8,
    pub state: u8,
    pub aid: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Card {
    pub state: u8,
    pub error: u8,
    pub applications: Vec<CardApplication>,
}

impl Card {
    /// Card state 1 is "present".
    pub fn is_present(&self) -> bool {
        self.state == 1
    }
}

impl UimClient {
    pub fn connect() -> Result<Self, String> {
        Ok(Self {
            qmi: QrtrClient::connect(SERVICE_UIM, DEFAULT_TIMEOUT)?,
        })
    }

    /// `UIM_GET_CARD_STATUS` — read-only.
    pub fn card_status(&mut self) -> Result<Vec<Card>, String> {
        let tlvs = self.qmi.request_exact(MSG_GET_CARD_STATUS, &[])?;
        checked_result(&tlvs)?;
        let value = unique_field(&tlvs, 0x10)?;
        parse_card_status(value)
    }

    /// No vendor cache/ubus dependency: validate the actual physical-to-logical route.
    pub fn selected_physical_slot1(&mut self) -> Result<(), String> {
        let response = self.qmi.request_exact(MSG_GET_SLOT_STATUS, &[])?;
        checked_result(&response)?;
        selected_slot1(unique_field(&response, 0x10)?)
    }

    pub fn slot1_ready(&mut self) -> Result<bool, String> {
        let cards = self.card_status()?;
        Ok(cards.first().is_some_and(|card| {
            card.is_present()
                && card
                    .applications
                    .iter()
                    .any(|app| matches!(app.app_type, 1 | 2) && app.state == 7)
        }))
    }

    /// `UIM_OPEN_LOGICAL_CHANNEL` with omitted AID allocates an owned channel
    /// without selecting ISD-R. A later explicit SELECT can return 6A82 without
    /// obscuring ownership. Qualcomm qmi_uimi_open_logical_channel documents
    /// the omitted-AID behavior; sending an empty AID TLV is not equivalent.
    ///
    /// The caller owns the returned channel and must close it on every path;
    /// the card has a small fixed number of channels and a leaked one is only
    /// recovered by a modem reset.
    pub fn open_logical_channel(&mut self) -> Result<u8, OpenChannelError> {
        let tlvs = self
            .qmi
            .request_exact(MSG_OPEN_LOGICAL_CHANNEL, &open_request())
            .map_err(|_| OpenChannelError::unknown())?;
        parse_open_response(&tlvs)
    }

    /// `UIM_CLOSE_LOGICAL_CHANNEL`.
    pub fn close_logical_channel(&mut self, channel: u8) -> Result<(), String> {
        let tlvs = self.qmi.request_exact(
            MSG_CLOSE_LOGICAL_CHANNEL,
            &[
                tlv::u8_tlv(0x01, SLOT),
                Tlv {
                    tag: 0x11,
                    value: vec![channel],
                },
            ],
        )?;
        checked_result(&tlvs)
    }

    /// `UIM_POWER_OFF_SIM` — deactivates the card in its slot.
    ///
    /// The card stays physically where it is; only the modem's session with it
    /// ends. Any logical channel is dropped with it, so nothing may hold one
    /// across this call.
    pub fn power_off_card(&mut self) -> Result<(), String> {
        let tlvs = self
            .qmi
            .request(MSG_POWER_OFF_SIM, &[tlv::u8_tlv(0x01, SLOT)])?;
        tlv::check_result(&tlvs)
    }

    /// `UIM_POWER_ON_SIM` — brings the card back up and re-runs card init.
    ///
    /// This is the step that makes a profile switch visible: the modem selects
    /// the card's applications afresh, so it picks up whichever profile the
    /// eUICC now has enabled.
    pub fn power_on_card(&mut self) -> Result<(), String> {
        let tlvs = self
            .qmi
            .request(MSG_POWER_ON_SIM, &[tlv::u8_tlv(0x01, SLOT)])?;
        tlv::check_result(&tlvs)
    }

    /// `UIM_SEND_APDU` — returns the raw response including SW1/SW2.
    pub fn send_apdu(&mut self, channel: u8, command: &[u8]) -> Result<Vec<u8>, String> {
        let tlvs = self.qmi.request_exact(
            MSG_SEND_APDU,
            &[
                tlv::u8_tlv(0x10, channel),
                tlv::seq16_tlv(0x02, command),
                tlv::u8_tlv(0x01, SLOT),
            ],
        )?;
        checked_result(&tlvs)?;
        let value = unique_field(&tlvs, 0x10)?;
        let bytes = tlv::read_seq16(value)?;
        if value.len() != bytes.len() + 2 {
            return Err("APDU trailing bytes".into());
        }
        Ok(bytes.to_vec())
    }
}

/// Parse the `UIM_GET_CARD_STATUS` payload.
///
/// Layout: four u16 index fields, then a card count, then per card
/// `{state, upin_state, upin_retries, upuk_retries, error, app_count}` followed
/// by each application.
fn parse_card_status(data: &[u8]) -> Result<Vec<Card>, String> {
    let mut r = Reader::new(data);
    for _ in 0..4 {
        r.u16()?;
    }
    let card_count = r.u8()?;
    if card_count == 0 || card_count > 8 {
        return Err("card count invalid".into());
    }
    let mut cards = Vec::with_capacity(card_count as usize);
    for _ in 0..card_count {
        let state = r.u8()?;
        r.u8()?; // upin state
        r.u8()?; // upin retries
        r.u8()?; // upuk retries
        let error = r.u8()?;
        let app_count = r.u8()?;
        if app_count > 32 {
            return Err("application count invalid".into());
        }
        let mut applications = Vec::with_capacity(app_count as usize);
        for _ in 0..app_count {
            let app_type = r.u8()?;
            let app_state = r.u8()?;
            r.u8()?; // personalization state
            r.u8()?; // personalization feature
            r.u8()?; // personalization retries
            r.u8()?; // personalization unblock retries
            let aid_len = r.u8()? as usize;
            let aid = r.bytes(aid_len)?.to_vec();
            r.u8()?; // upin replaces pin1
            r.u8()?; // pin1 state
            r.u8()?; // pin1 retries
            r.u8()?; // puk1 retries
            r.u8()?; // pin2 state
            r.u8()?; // pin2 retries
            r.u8()?; // puk2 retries
            applications.push(CardApplication {
                app_type,
                state: app_state,
                aid,
            });
        }
        cards.push(Card {
            state,
            error,
            applications,
        });
    }
    if r.pos != data.len() {
        return Err("trailing card status".into());
    }
    Ok(cards)
}

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn bytes(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self
            .pos
            .checked_add(n)
            .ok_or("card status: length overflow")?;
        let slice = self
            .data
            .get(self.pos..end)
            .ok_or_else(|| format!("card status: truncated at byte {}", self.pos))?;
        self.pos = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.bytes(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, String> {
        let b = self.bytes(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result_tlv(result: u16, error: u16) -> Tlv {
        Tlv {
            tag: 2,
            value: [result.to_le_bytes(), error.to_le_bytes()].concat(),
        }
    }
    #[test]
    fn only_proven_pre_operation_codes_release_open_ownership() {
        for error in [1, 71, 82] {
            assert_eq!(
                parse_open_response(&[result_tlv(1, error)]),
                Err(OpenChannelError::Rejected {
                    qmi_result: 1,
                    qmi_error: error
                })
            );
        }
        // Exhaust all other numeric codes; never silently broaden the list.
        for error in 0..=u16::MAX {
            if [1, 71, 82].contains(&error) {
                continue;
            }
            assert!(matches!(
                parse_open_response(&[result_tlv(1, error)]),
                Err(OpenChannelError::Unknown { .. })
            ));
        }
    }
    #[test]
    fn no_memory_can_follow_allocated_channel_and_remains_unknown() {
        for code in [2, 3, 37, 52, 68, 80, 90, 94] {
            for channel in [false, true] {
                let mut tlvs = vec![result_tlv(1, code)];
                if channel {
                    tlvs.push(tlv::u8_tlv(0x10, 1));
                }
                assert!(matches!(
                    parse_open_response(&tlvs),
                    Err(OpenChannelError::Unknown { .. })
                ));
            }
        }
    }
    #[test]
    fn malformed_or_contradictory_open_response_is_unknown() {
        let cases = vec![
            vec![],
            vec![Tlv {
                tag: 2,
                value: vec![1, 0, 82],
            }],
            vec![Tlv {
                tag: 2,
                value: vec![1, 0, 82, 0, 0],
            }],
            vec![result_tlv(1, 82), result_tlv(1, 82)],
            vec![result_tlv(1, 82), tlv::u8_tlv(0x10, 1)],
            vec![
                result_tlv(1, 82),
                Tlv {
                    tag: 0x11,
                    value: vec![0x90, 0],
                },
            ],
            vec![result_tlv(0, 82), tlv::u8_tlv(0x10, 1)],
            vec![result_tlv(2, 82)],
            vec![result_tlv(0, 0)],
            vec![result_tlv(0, 0), tlv::u8_tlv(0x10, 0)],
            vec![
                result_tlv(0, 0),
                Tlv {
                    tag: 0x10,
                    value: vec![1, 2],
                },
            ],
            vec![result_tlv(0, 0), tlv::u8_tlv(0x10, 1), tlv::u8_tlv(0x10, 1)],
            vec![
                result_tlv(0, 0),
                tlv::u8_tlv(0x10, 1),
                Tlv {
                    tag: 0x12,
                    value: vec![2, 0],
                },
            ],
        ];
        for tlvs in cases {
            assert!(matches!(
                parse_open_response(&tlvs),
                Err(OpenChannelError::Unknown { .. })
            ));
        }
    }
    #[test]
    fn success_preserves_returned_channel_for_owned_close() {
        for channel in [1, 3, 4, 19, 255] {
            assert_eq!(
                parse_open_response(&[result_tlv(0, 0), tlv::u8_tlv(0x10, channel)]),
                Ok(channel)
            );
        }
    }

    /// A single present card with one ready USIM application. AID bytes are a
    /// placeholder, not a capture from the device.
    fn one_card_status() -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&0u16.to_le_bytes()); // index gw primary
        v.extend_from_slice(&0u16.to_le_bytes()); // index 1x primary
        v.extend_from_slice(&0xFFFFu16.to_le_bytes()); // index gw secondary
        v.extend_from_slice(&0xFFFFu16.to_le_bytes()); // index 1x secondary
        v.push(1); // card count
        v.extend_from_slice(&[1, 0, 0, 0, 0]); // state=present, pin fields, error=0
        v.push(1); // app count
        v.extend_from_slice(&[2, 1, 0, 0, 0, 0]); // type=USIM, state=ready, perso
        v.push(3); // aid length
        v.extend_from_slice(&[0xA0, 0x00, 0x01]);
        v.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0]); // upin/pin1/pin2 fields
        v
    }

    #[test]
    fn parses_card_status() {
        let cards = parse_card_status(&one_card_status()).unwrap();
        assert_eq!(cards.len(), 1);
        assert!(cards[0].is_present());
        assert_eq!(cards[0].error, 0);
        assert_eq!(cards[0].applications.len(), 1);
        assert_eq!(cards[0].applications[0].app_type, 2);
        assert_eq!(cards[0].applications[0].state, 1);
        assert_eq!(cards[0].applications[0].aid, vec![0xA0, 0x00, 0x01]);
    }

    #[test]
    fn parses_absent_card() {
        let mut v = vec![0u8; 8];
        v.push(1); // card count
        v.extend_from_slice(&[0, 0, 0, 0, 0]); // state=absent
        v.push(0); // no applications
        let cards = parse_card_status(&v).unwrap();
        assert!(!cards[0].is_present());
        assert!(cards[0].applications.is_empty());
    }

    #[test]
    fn rejects_truncated_card_status() {
        let full = one_card_status();
        // Every prefix short of the whole payload must fail rather than
        // silently returning a half-parsed card.
        for cut in 1..full.len() {
            assert!(
                parse_card_status(&full[..cut]).is_err(),
                "prefix of {cut} bytes parsed but should not"
            );
        }
    }

    #[test]
    fn rejects_empty_card_status() {
        assert!(parse_card_status(&[]).is_err());
    }
    #[test]
    fn open_has_only_slot_no_empty_aid_or_fci() {
        assert_eq!(tlv::encode(&open_request()), vec![1, 1, 0, 1]);
    }
    fn slot_rows(rows: &[(u32, u32, u8)]) -> Vec<u8> {
        let mut data = vec![rows.len() as u8];
        for (present, active, logical) in rows {
            data.extend(present.to_le_bytes());
            data.extend(active.to_le_bytes());
            data.extend([*logical, 0]);
        }
        data
    }
    #[test]
    fn physical_route_requires_selected_present_slot1_and_no_competing_route() {
        let good = slot_rows(&[(2, 1, 1), (1, 0, 0)]);
        assert!(selected_slot1(&good).is_ok()); // no ICCID needed for empty eUICC
        for rows in [
            vec![(2, 0, 1)],
            vec![(1, 1, 1)],
            vec![(2, 1, 2)],
            vec![(2, 1, 1), (2, 1, 1)],
            vec![(9, 1, 1)],
        ] {
            assert!(selected_slot1(&slot_rows(&rows)).is_err());
        }
        for end in 0..good.len() {
            assert!(selected_slot1(&good[..end]).is_err());
        }
        let mut trailing = good.clone();
        trailing.push(0);
        assert!(selected_slot1(&trailing).is_err());
    }
    #[test]
    fn result_and_payload_duplicates_are_not_capability_proof() {
        for response in [
            vec![],
            vec![result_tlv(0, 3)],
            vec![result_tlv(0, 0), result_tlv(0, 0)],
        ] {
            assert!(checked_result(&response).is_err());
        }
        assert!(unique_field(&[tlv::u8_tlv(0x10, 1), tlv::u8_tlv(0x10, 1)], 0x10).is_err());
    }
}
