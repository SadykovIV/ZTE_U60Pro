//! DMS/UIM radio status and constrained temporary low-power/online transitions.
mod qrtr;
mod tlv;
use super::target::{Availability, Target, TARGETS};
use super::{Error, Result};
use std::time::{Duration, Instant};

fn field(values: &[tlv::Tlv], tag: u8) -> Result<&[u8]> {
    let mut found = values.iter().filter(|x| x.tag == tag);
    let first = found.next().ok_or(Error::new("radio_read_failed"))?;
    if found.next().is_some() {
        return Err(Error::new("radio_read_failed"));
    }
    Ok(&first.value)
}
fn read(service: u32, message: u16) -> Result<Vec<tlv::Tlv>> {
    if !matches!((service, message), (2, 0x2d) | (11, 0x47) | (11, 0x2f)) {
        return Err(Error::new("radio_read_failed"));
    }
    let mut client = qrtr::QrtrClient::connect(service, Duration::from_secs(2))
        .map_err(|_| Error::new("radio_read_failed"))?;
    let values = client
        .request(message, &[])
        .map_err(|_| Error::new("radio_read_failed"))?;
    if field(&values, 2)? != [0, 0, 0, 0] {
        return Err(Error::new("radio_read_failed"));
    }
    Ok(values)
}
pub fn mode() -> Result<u8> {
    let values = read(2, 0x2d)?;
    let data = field(&values, 1)?;
    if data.len() != 1 {
        return Err(Error::new("radio_read_failed"));
    }
    Ok(data[0])
}
fn mode_request(online: bool) -> [tlv::Tlv; 1] {
    [tlv::u8_tlv(1, if online { 0 } else { 1 })]
}
pub fn set_online() -> Result<(u16, u16)> {
    set_mode(true)
}
pub fn set_mode(online: bool) -> Result<(u16, u16)> {
    let mut client = qrtr::QrtrClient::connect(2, Duration::from_secs(2))
        .map_err(|_| Error::new("radio_set_failed"))?;
    let values = client
        .request(0x2e, &mode_request(online))
        .map_err(|_| Error::new("radio_set_failed"))?;
    let result = field(&values, 2).map_err(|_| Error::new("radio_set_failed"))?;
    if result.len() != 4 {
        return Err(Error::new("radio_set_failed"));
    }
    Ok((
        u16::from_le_bytes([result[0], result[1]]),
        u16::from_le_bytes([result[2], result[3]]),
    ))
}

fn card_power_request(target: Target, on: bool) -> (u16, [tlv::Tlv; 1]) {
    // QMI UIM Power Down/Up: required slot enum, one byte, the request's immutable logical slot.
    // No optional ignore-hotswap or non-telecom-card mode is requested.
    (
        if on { 0x31 } else { 0x30 },
        [tlv::u8_tlv(1, target.slot())],
    )
}
fn card_power_result(response: &[tlv::Tlv], on: bool) -> Result<()> {
    let fail = || {
        Error::new(if on {
            "card_power_restore_failed"
        } else {
            "card_reset_failed"
        })
    };
    if field(response, 2).map_err(|_| fail())? != [0, 0, 0, 0] {
        return Err(fail());
    }
    Ok(())
}
pub fn card_power(target: Target, on: bool) -> Result<()> {
    let fail = || {
        Error::new(if on {
            "card_power_restore_failed"
        } else {
            "card_reset_failed"
        })
    };
    // Match the reviewed card helper's bounded 10s timeout: power-up may wait
    // for card initialization. Ordinary status/DMS requests retain 2s.
    let mut client = qrtr::QrtrClient::connect(qrtr::SERVICE_UIM, Duration::from_secs(10))
        .map_err(|_| fail())?;
    let (message, request) = card_power_request(target, on);
    let response = client.request(message, &request).map_err(|_| fail())?;
    card_power_result(&response, on)
}
fn bcd_iccid(data: &[u8]) -> Result<String> {
    if data.len() != 10 {
        return Err(Error::new("modem_readback_failed"));
    }
    let mut digits = String::with_capacity(20);
    for i in 0..20 {
        let nibble = (data[i / 2] >> ((i % 2) * 4)) & 15;
        if i == 19 && nibble == 15 {
            break;
        }
        if nibble > 9 {
            return Err(Error::new("modem_readback_failed"));
        }
        digits.push((b'0' + nibble) as char);
    }
    Ok(digits)
}
fn target_iccid_bytes(target: Target, data: &[u8]) -> Result<&[u8]> {
    let Some(&count) = data.first() else {
        return Err(Error::new("modem_readback_failed"));
    };
    if count == 0 || count > 8 {
        return Err(Error::new("modem_readback_failed"));
    }
    let mut pos = 1;
    let mut selected = None;
    let mut alternate_target_route = false;
    let mut invalid_enum = false;
    for physical in 1..=count {
        let header = data
            .get(pos..pos + 10)
            .ok_or(Error::new("modem_readback_failed"))?;
        let card = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let active = u32::from_le_bytes(header[4..8].try_into().unwrap());
        let logical = header[8];
        let len = header[9] as usize;
        invalid_enum |= card > 2 || active > 1 || logical > 8;
        pos += 10;
        let iccid = data
            .get(pos..pos + len)
            .ok_or(Error::new("modem_readback_failed"))?;
        pos += len;
        if physical == target.slot() {
            selected = Some((card, active, logical, iccid));
        } else if active == 1 && logical == target.slot() {
            alternate_target_route = true;
        }
    }
    if pos != data.len() {
        return Err(Error::new("modem_readback_failed"));
    }
    let (card, active, logical, iccid) = selected.ok_or(Error::new("modem_slot_mismatch"))?;
    // Inspect all rows first: target-card initialization must not hide an
    // alternate physical card taking the target logical slot.
    if alternate_target_route {
        return Err(Error::new("modem_slot_mismatch"));
    }
    if invalid_enum {
        return Err(Error::new("modem_readback_failed"));
    }
    // Power-up may temporarily clear the target's active/logical assignment.
    // This does not prove rerouting. A different assignment still fails hard.
    if active == 0 && (logical == 0 || logical == target.slot()) {
        return Err(Error::new("modem_readback_failed"));
    }
    if active != 1 || logical != target.slot() {
        return Err(Error::new("modem_slot_mismatch"));
    }
    if card != 2 {
        return Err(Error::new("modem_readback_failed"));
    }
    Ok(iccid)
}
fn target_iccid(target: Target, data: &[u8]) -> Result<String> {
    bcd_iccid(target_iccid_bytes(target, data)?)
}
fn selected_target_slot(target: Target, data: &[u8]) -> Result<()> {
    let iccid = target_iccid_bytes(target, data)?;
    // An eUICC with no enabled profile can have no ICCID yet.
    // The physical/logical route still has to be present and unambiguous.
    if !iccid.is_empty() {
        bcd_iccid(iccid)?;
    }
    Ok(())
}
#[derive(Debug)]
struct SlotRow {
    physical: u8,
    card: u32,
    active: u32,
    logical: u8,
}
fn slot_rows(data: &[u8]) -> Result<Vec<SlotRow>> {
    let fail = || Error::new("modem_readback_failed");
    let count = *data.first().ok_or_else(fail)?;
    if !(1..=8).contains(&count) {
        return Err(fail());
    }
    let mut rows = Vec::new();
    let mut pos = 1;
    let mut mapped = std::collections::BTreeSet::new();
    for physical in 1..=count {
        let h = data.get(pos..pos + 10).ok_or_else(fail)?;
        let card = u32::from_le_bytes(h[..4].try_into().unwrap());
        let active = u32::from_le_bytes(h[4..8].try_into().unwrap());
        let logical = h[8];
        let len = usize::from(h[9]);
        pos += 10;
        data.get(pos..pos + len).ok_or_else(fail)?;
        pos += len;
        if card > 2
            || active > 1
            || logical > 8
            || (active == 1 && logical != 0 && !mapped.insert(logical))
        {
            return Err(fail());
        }
        rows.push(SlotRow {
            physical,
            card,
            active,
            logical,
        });
    }
    if pos != data.len() {
        return Err(fail());
    }
    Ok(rows)
}
fn route_availability(rows: &[SlotRow], target: Target) -> Availability {
    match rows.iter().find(|r| r.physical == target.slot()) {
        None => Availability::Absent,
        Some(r) if r.card == 1 => Availability::Absent,
        Some(r) if r.card == 2 && r.active == 1 && r.logical == target.slot() => {
            Availability::Available
        }
        _ => Availability::Unavailable,
    }
}
pub fn inventory() -> Result<Vec<(Target, Availability)>> {
    let values = read(qrtr::SERVICE_UIM, 0x47)?;
    let rows = slot_rows(field(&values, 0x10)?)?;
    if rows.iter().any(|r| r.physical > 2 && r.card != 1) {
        return Err(Error::new("target_unavailable"));
    }
    Ok(TARGETS
        .into_iter()
        .map(|t| (t, route_availability(&rows, t)))
        .collect())
}
fn sole_present(rows: &[SlotRow], target: Target) -> bool {
    route_availability(rows, target) == Availability::Available
        && rows
            .iter()
            .all(|r| r.physical == target.slot() || r.card == 1)
}
fn power_route(data: &[u8], target: Target, restoring: bool) -> Result<()> {
    let rows = slot_rows(data)?;
    let row = rows
        .iter()
        .find(|r| r.physical == target.slot())
        .ok_or(Error::new("modem_slot_mismatch"))?;
    if rows
        .iter()
        .any(|r| r.physical != target.slot() && r.active == 1 && r.logical == target.slot())
    {
        return Err(Error::new("modem_slot_mismatch"));
    }
    if (row.active == 1 && row.logical == target.slot() && (restoring || row.card == 2))
        || (restoring && row.active == 0 && (row.logical == 0 || row.logical == target.slot()))
    {
        Ok(())
    } else {
        Err(Error::new("modem_slot_mismatch"))
    }
}
pub fn power_selection(target: Target, restoring: bool) -> Result<()> {
    let values = read(qrtr::SERVICE_UIM, 0x47)?;
    power_route(field(&values, 0x10)?, target, restoring)
}
pub fn sole_subscription(target: Target) -> Result<bool> {
    let values = read(qrtr::SERVICE_UIM, 0x47)?;
    let rows = slot_rows(field(&values, 0x10)?)?;
    if !sole_present(&rows, target) {
        return Ok(false);
    }
    let cards = read(qrtr::SERVICE_UIM, 0x2f)?;
    let data = field(&cards, 0x10)?;
    if data.len() < 8 {
        return Err(Error::new("radio_read_failed"));
    }
    for index in data[..8]
        .chunks_exact(2)
        .map(|v| u16::from_le_bytes([v[0], v[1]]))
    {
        if index != 0xffff && (index >> 8) != u16::from(target.slot() - 1) {
            return Ok(false);
        }
    }
    selected_usim_ready_inner(target, data, true)
}

pub fn selection(target: Target) -> Result<()> {
    let values = read(qrtr::SERVICE_UIM, 0x47).map_err(|_| Error::new("modem_readback_failed"))?;
    selected_target_slot(
        target,
        field(&values, 0x10).map_err(|_| Error::new("modem_readback_failed"))?,
    )
}
pub fn iccid(target: Target) -> Result<String> {
    let values = read(qrtr::SERVICE_UIM, 0x47).map_err(|_| Error::new("modem_readback_failed"))?;
    target_iccid(
        target,
        field(&values, 0x10).map_err(|_| Error::new("modem_readback_failed"))?,
    )
}

// QMI UIM GetCardStatus (0x2f), TLV 0x10. Qualcomm IDL defines
// card PRESENT=1, USIM=2, DETECTED=1 and application READY=7. Provisioning
// indices are (zero-based logical slot << 8) | zero-based app, or 0xffff.
// Primary sources: libqmi/data/qmi-service-uim.json and qmi-enums-uim.h;
// saved Qualcomm user_identity_module_v01.h uim_card_status_type_v01.
// Parse every row before accepting a match; neither AIDs nor PIN data escape.
fn selected_usim_ready(target: Target, data: &[u8]) -> Result<bool> {
    selected_usim_ready_inner(target, data, false)
}
fn selected_usim_ready_inner(target: Target, data: &[u8], sole: bool) -> Result<bool> {
    let fail = || Error::new("card_not_ready");
    if data.len() < 9 || data[8] == 0 || data[8] > 8 {
        return Err(fail());
    }
    let indices: Vec<u16> = data[..8]
        .chunks_exact(2)
        .map(|x| u16::from_le_bytes([x[0], x[1]]))
        .collect();
    let mut cards = Vec::new();
    let mut pos = 9;
    for _ in 0..data[8] {
        let card = data.get(pos..pos + 6).ok_or_else(fail)?;
        if card[0] > 2 {
            return Err(fail());
        }
        let app_count = card[5];
        if app_count > 32 {
            return Err(fail());
        }
        pos += 6;
        let mut apps = Vec::new();
        for _ in 0..app_count {
            let app = data.get(pos..pos + 7).ok_or_else(fail)?;
            let aid_len = app[6] as usize;
            if aid_len > 32 {
                return Err(fail());
            }
            apps.push((app[0], app[1]));
            pos += 7;
            // AID plus UPIN/PIN1/PIN2 status and retry bytes.
            data.get(pos..pos + aid_len + 7).ok_or_else(fail)?;
            pos += aid_len + 7;
        }
        cards.push((card[0], apps));
    }
    if pos != data.len() {
        return Err(fail());
    }
    // A hot-insert between GetSlotStatus and GetCardStatus must not preserve
    // a stale sole-card permission for a global radio transition.
    if sole
        && cards
            .iter()
            .enumerate()
            .any(|(i, (state, _))| *state != 0 && i != usize::from(target.slot() - 1))
    {
        return Ok(false);
    }
    let mut seen = std::collections::BTreeSet::new();
    let mut ready = false;
    for (kind, index) in indices.into_iter().enumerate() {
        if index == 0xffff {
            continue;
        }
        if !seen.insert(index) {
            return Err(fail());
        }
        let slot = (index >> 8) as usize;
        let app_index = (index & 0xff) as usize;
        let (state, apps) = cards.get(slot).ok_or_else(fail)?;
        let &(app_type, app_state) = apps.get(app_index).ok_or_else(fail)?;
        // Only GW primary/secondary provisioning selects a USIM. Optional ISIM
        // need not be READY; waiting for IMS would reject otherwise usable cards.
        if matches!(kind, 0 | 2)
            && slot == usize::from(target.slot() - 1)
            && *state == 1
            && app_type == 2
            && app_state == 7
        {
            ready = true;
        }
    }
    if sole {
        // No enabled profile may mean no USIM/provisioning entry yet. With
        // every other physical card absent, a present target remains the only
        // possible subscription. Never require READY before its first Enable.
        Ok(cards
            .get(usize::from(target.slot() - 1))
            .is_some_and(|(state, _)| *state == 1))
    } else {
        Ok(ready)
    }
}

pub fn card_ready(target: Target, expected_iccid: &str, deadline: Instant) -> Result<bool> {
    let fail = || Error::new("card_not_ready");
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(fail());
    }
    let mut client =
        qrtr::QrtrClient::connect(qrtr::SERVICE_UIM, remaining.min(Duration::from_secs(2)))
            .map_err(|_| fail())?;
    // At most two empty, read-only requests in this sample, on the same UIM
    // endpoint. Recheck the immutable route and expected ICCID before readiness.
    let slots = client
        .request_until(0x47, &[], deadline)
        .map_err(|_| fail())?;
    if field(&slots, 2).map_err(|_| fail())? != [0, 0, 0, 0] {
        return Err(fail());
    }
    if target_iccid(target, field(&slots, 0x10).map_err(|_| fail())?).map_err(|_| fail())?
        != expected_iccid
    {
        return Ok(false);
    }
    let cards = client
        .request_until(0x2f, &[], deadline)
        .map_err(|_| fail())?;
    if field(&cards, 2).map_err(|_| fail())? != [0, 0, 0, 0] {
        return Err(fail());
    }
    selected_usim_ready(target, field(&cards, 0x10).map_err(|_| fail())?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_and_cycle_have_exact_allowed_mode_tlv() {
        assert_eq!(tlv::encode(&mode_request(true)), [1, 1, 0, 0]);
        assert_eq!(tlv::encode(&mode_request(false)), [1, 1, 0, 1]);
    }
    #[test]
    fn card_power_has_only_exact_slot2_tlv_and_strict_result() {
        for on in [false, true] {
            let (message, request) = card_power_request(Target::Internal, on);
            assert_eq!(message, if on { 0x31 } else { 0x30 });
            assert_eq!(tlv::encode(&request), [1, 1, 0, 2]);
            let result = tlv::Tlv {
                tag: 2,
                value: vec![0, 0, 0, 0],
            };
            card_power_result(&[result.clone()], on).unwrap();
            for values in [
                vec![],
                vec![result.clone(), result.clone()],
                vec![tlv::Tlv {
                    tag: 2,
                    value: vec![0, 0, 0],
                }],
                vec![tlv::Tlv {
                    tag: 2,
                    value: vec![1, 0, 82, 0],
                }],
            ] {
                assert_eq!(
                    card_power_result(&values, on).unwrap_err().code,
                    if on {
                        "card_power_restore_failed"
                    } else {
                        "card_reset_failed"
                    }
                );
            }
        }
    }
    fn row(logical: u8, bytes: &[u8]) -> Vec<u8> {
        let mut v = [2u32.to_le_bytes(), 1u32.to_le_bytes()].concat();
        v.extend([logical, bytes.len() as u8]);
        v.extend(bytes);
        v
    }
    fn target_rows(
        card: u32,
        active: u32,
        logical: u8,
        bytes: &[u8],
        other_logical: u8,
    ) -> Vec<u8> {
        let mut v = vec![2];
        v.extend(row(other_logical, &[0x76; 10]));
        v.extend(card.to_le_bytes());
        v.extend(active.to_le_bytes());
        v.extend([logical, bytes.len() as u8]);
        v.extend(bytes);
        v
    }
    #[test]
    fn exact_slot_and_bcd_no_guessing() {
        let v = target_rows(2, 1, 2, &[0x98; 10], 1);
        assert_eq!(
            target_iccid(Target::Internal, &v).unwrap(),
            "89898989898989898989"
        );
        assert_ne!(
            target_iccid(Target::Internal, &v).unwrap(),
            "67676767676767676767"
        );
        for v in [
            target_rows(2, 1, 1, &[0x98; 10], 2),
            target_rows(2, 1, 2, &[0x98; 10], 2),
        ] {
            assert_eq!(
                target_iccid(Target::Internal, &v).unwrap_err().code,
                "modem_slot_mismatch"
            );
        }
        let mut only_external = vec![1];
        only_external.extend(row(1, &[0x98; 10]));
        assert_eq!(
            target_iccid(Target::Internal, &only_external)
                .unwrap_err()
                .code,
            "modem_slot_mismatch"
        );
        assert!(bcd_iccid(&[0x98; 9]).is_err());
        let mut x = [0x98; 10];
        x[9] = 0xf8;
        assert_eq!(bcd_iccid(&x).unwrap().len(), 19);
        x[0] = 0xf8;
        assert!(bcd_iccid(&x).is_err());
    }
    #[test]
    fn empty_profile_route_is_valid_but_iccid_readback_still_requires_digits() {
        let value = target_rows(2, 1, 2, &[], 1);
        assert!(selected_target_slot(Target::Internal, &value).is_ok());
        assert!(target_iccid(Target::Internal, &value).is_err());
        for value in [target_rows(2, 1, 1, &[], 1), target_rows(2, 1, 2, &[], 2)] {
            assert_eq!(
                selected_target_slot(Target::Internal, &value)
                    .unwrap_err()
                    .code,
                "modem_slot_mismatch"
            );
        }
        assert!(
            selected_target_slot(Target::Internal, &target_rows(2, 1, 2, &[0x98; 9], 1)).is_err()
        );
    }
    #[test]
    fn external_slot_can_be_present_or_absent_without_redirecting_target() {
        for (card, active, logical) in [(2u32, 1u32, 1u8), (0, 0, 0), (1, 0, 0)] {
            let mut v = vec![2];
            v.extend(card.to_le_bytes());
            v.extend(active.to_le_bytes());
            v.extend([logical, 0]);
            v.extend(row(2, &[0x98; 10]));
            assert_eq!(
                target_iccid(Target::Internal, &v).unwrap(),
                "89898989898989898989"
            );
        }
        for (card, active, logical) in [(9u32, 1u32, 1u8), (2, 9, 1), (2, 1, 9)] {
            let mut v = vec![2];
            v.extend(card.to_le_bytes());
            v.extend(active.to_le_bytes());
            v.extend([logical, 0]);
            v.extend(row(2, &[0x98; 10]));
            assert!(target_iccid(Target::Internal, &v).is_err());
        }
    }
    #[test]
    fn refuses_truncation_duplicates_and_trailing_data() {
        let mut v = target_rows(2, 1, 2, &[0x98; 10], 1);
        for size in 0..v.len() {
            assert!(target_iccid(Target::Internal, &v[..size]).is_err());
        }
        v.push(0);
        assert!(target_iccid(Target::Internal, &v).is_err());
        assert_eq!(
            target_iccid(Target::Internal, &target_rows(2, 1, 2, &[0x98; 10], 2))
                .unwrap_err()
                .code,
            "modem_slot_mismatch"
        );
        assert!(field(&[tlv::u8_tlv(1, 0), tlv::u8_tlv(1, 0)], 1).is_err());
    }
    #[test]
    fn powerup_transient_card_state_is_retryable_but_never_hides_wrong_route() {
        for (card, active, logical, bytes) in [
            (0, 1, 2, vec![]),
            (1, 1, 2, vec![]),
            (3, 1, 2, vec![]),
            (2, 1, 2, vec![]),
            (2, 0, 0, vec![]),
            (2, 0, 2, vec![0x98; 10]),
        ] {
            assert_eq!(
                target_iccid(
                    Target::Internal,
                    &target_rows(card, active, logical, &bytes, 1)
                )
                .unwrap_err()
                .code,
                "modem_readback_failed"
            );
            // Even an absent/initializing target cannot conceal this conflict.
            assert_eq!(
                target_iccid(
                    Target::Internal,
                    &target_rows(card, active, logical, &bytes, 2)
                )
                .unwrap_err()
                .code,
                "modem_slot_mismatch"
            );
        }
        for (active, logical) in [(1, 0), (1, 1), (0, 1)] {
            assert_eq!(
                target_iccid(
                    Target::Internal,
                    &target_rows(2, active, logical, &[0x98; 10], 1)
                )
                .unwrap_err()
                .code,
                "modem_slot_mismatch"
            );
        }
        assert_eq!(
            target_iccid(Target::Internal, &target_rows(2, 1, 2, &[0x98; 10], 1)).unwrap(),
            "89898989898989898989"
        );
    }
    fn application(kind: u8, state: u8) -> Vec<u8> {
        // Empty AID, followed by seven unrelated PIN fields.
        let mut v = vec![kind, state, 0, 0, 0, 0, 0];
        v.extend([0; 7]);
        v
    }
    fn card(state: u8, apps: &[Vec<u8>]) -> Vec<u8> {
        let mut v = vec![state, 0, 0, 0, 0, apps.len() as u8];
        for app in apps {
            v.extend(app);
        }
        v
    }
    fn card_status(indices: [u16; 4], cards: &[Vec<u8>]) -> Vec<u8> {
        let mut v: Vec<u8> = indices.into_iter().flat_map(u16::to_le_bytes).collect();
        v.push(cards.len() as u8);
        for card in cards {
            v.extend(card);
        }
        v
    }
    #[test]
    fn readiness_requires_selected_internal_usim_ready_seven_not_detected_one() {
        for state in 0..=8 {
            let v = card_status(
                [0x100, 0xffff, 0xffff, 0xffff],
                &[
                    card(1, &[application(2, 7)]),
                    card(1, &[application(2, state), application(5, 1)]),
                ],
            );
            assert_eq!(
                selected_usim_ready(Target::Internal, &v).unwrap(),
                state == 7
            );
        }
        // A not-ready optional ISIM does not block the provisioned internal USIM.
        let v = card_status(
            [0xffff, 0xffff, 0x101, 0xffff],
            &[
                card(0, &[]),
                card(1, &[application(5, 1), application(2, 7)]),
            ],
        );
        assert!(selected_usim_ready(Target::Internal, &v).unwrap());
    }
    #[test]
    fn readiness_does_not_infer_selection_from_any_ready_application() {
        let target = card(1, &[application(2, 1), application(2, 7)]);
        assert!(!selected_usim_ready(
            Target::Internal,
            &card_status([0x100, 0xffff, 0xffff, 0xffff], &[card(0, &[]), target])
        )
        .unwrap());
        for indices in [[0xffff; 4], [0xffff, 0x100, 0xffff, 0xffff]] {
            assert!(!selected_usim_ready(
                Target::Internal,
                &card_status(indices, &[card(0, &[]), card(1, &[application(2, 7)])])
            )
            .unwrap());
        }
        for kind in [0, 1, 3, 4, 5, 255] {
            assert!(!selected_usim_ready(
                Target::Internal,
                &card_status(
                    [0x100, 0xffff, 0xffff, 0xffff],
                    &[card(0, &[]), card(1, &[application(kind, 7)])]
                )
            )
            .unwrap());
        }
        // External SIM readiness/provisioning never verifies the internal card.
        let v = card_status(
            [0, 0xffff, 0xffff, 0xffff],
            &[card(1, &[application(2, 7)]), card(1, &[application(2, 7)])],
        );
        assert!(!selected_usim_ready(Target::Internal, &v).unwrap());
        for state in [0, 2, 255] {
            assert!(!selected_usim_ready(
                Target::Internal,
                &card_status(
                    [0x100, 0xffff, 0xffff, 0xffff],
                    &[card(0, &[]), card(state, &[application(2, 7)])]
                )
            )
            .unwrap_or(false));
        }
    }
    #[test]
    fn readiness_rejects_duplicate_indices_bad_lengths_and_out_of_range_refs() {
        let v = card_status(
            [0x100, 0xffff, 0xffff, 0xffff],
            &[card(0, &[]), card(1, &[application(2, 7)])],
        );
        assert!(selected_usim_ready(Target::Internal, &v).unwrap());
        for length in 0..v.len() {
            assert!(selected_usim_ready(Target::Internal, &v[..length]).is_err());
        }
        let mut trailing = v.clone();
        trailing.push(0);
        assert!(selected_usim_ready(Target::Internal, &trailing).is_err());
        for indices in [
            [0x100, 0xffff, 0x100, 0xffff],
            [0x101, 0xffff, 0xffff, 0xffff],
            [0x200, 0xffff, 0xffff, 0xffff],
        ] {
            assert!(selected_usim_ready(
                Target::Internal,
                &card_status(indices, &[card(0, &[]), card(1, &[application(2, 7)])])
            )
            .is_err());
        }
        for (offset, value) in [(8, 9), (20, 33), (27, 33)] {
            let mut bad = v.clone();
            bad[offset] = value;
            assert!(selected_usim_ready(Target::Internal, &bad).is_err());
        }
    }
}

#[cfg(test)]
mod unified_route_tests {
    use super::*;
    fn rows(values: &[(u32, u32, u8)]) -> Vec<u8> {
        let mut b = vec![values.len() as u8];
        for (card, active, logical) in values {
            b.extend(card.to_le_bytes());
            b.extend(active.to_le_bytes());
            b.extend([*logical, 0]);
        }
        b
    }
    fn cards(target: Target, other_present: bool, provisioned: bool) -> Vec<u8> {
        let mut b = vec![255; 8];
        if provisioned {
            let index = u16::from(target.slot() - 1) << 8;
            b[..2].copy_from_slice(&index.to_le_bytes());
        }
        b.push(2);
        for i in 1..=2 {
            let present = i == target.slot() || other_present;
            b.extend([
                u8::from(present),
                0,
                0,
                0,
                0,
                u8::from(provisioned && i == target.slot()),
            ]);
            if provisioned && i == target.slot() {
                b.extend([2, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
            }
        }
        b
    }
    #[test]
    fn both_explicit_routes_encode_only_their_own_power_target() {
        let b = rows(&[(2, 1, 1), (2, 1, 2)]);
        for target in TARGETS {
            assert!(selected_target_slot(target, &b).is_ok());
            for on in [false, true] {
                let (id, tlvs) = card_power_request(target, on);
                assert_eq!(id, if on { 0x31 } else { 0x30 });
                assert_eq!(tlv::encode(&tlvs), [1, 1, 0, target.slot()]);
            }
        }
        for b in [rows(&[(2, 1, 2), (2, 1, 1)]), rows(&[(2, 1, 1), (2, 1, 1)])] {
            for target in TARGETS {
                assert!(selected_target_slot(target, &b).is_err());
            }
        }
    }
    #[test]
    fn two_rows_with_absent_second_card_are_single_present_not_dual_active() {
        let b = rows(&[(2, 1, 1), (1, 1, 2)]);
        let r = slot_rows(&b).unwrap();
        assert!(sole_present(&r, Target::Removable));
        assert!(!sole_present(&r, Target::Internal));
        assert_eq!(
            route_availability(&r, Target::Internal),
            Availability::Absent
        );
        let r = slot_rows(&rows(&[(1, 1, 1), (2, 1, 2)])).unwrap();
        assert!(sole_present(&r, Target::Internal));
        for rowspec in [[(2, 1, 1), (2, 1, 2)], [(2, 1, 1), (0, 1, 2)]] {
            let r = slot_rows(&rows(&rowspec)).unwrap();
            for target in TARGETS {
                assert!(!sole_present(&r, target));
            }
        }
    }
    #[test]
    fn recovery_never_follows_a_remap_and_only_allows_own_transient_route() {
        for target in TARGETS {
            let mut values = [(2, 1, 1), (2, 1, 2)];
            let i = usize::from(target.slot() - 1);
            values[i] = (0, 0, 0);
            assert!(power_route(&rows(&values), target, true).is_ok());
            assert!(power_route(&rows(&values), target, false).is_err());
            values[1 - i] = (2, 1, target.slot());
            assert!(power_route(&rows(&values), target, true).is_err());
        }
        for target in TARGETS {
            assert!(power_route(&rows(&[(2, 1, 2), (2, 1, 1)]), target, true).is_err());
        }
    }
    #[test]
    fn sole_card_can_enable_its_first_profile_but_never_another_present_card() {
        for target in TARGETS {
            for provisioned in [true, false] {
                assert!(selected_usim_ready_inner(
                    target,
                    &cards(target, false, provisioned),
                    true
                )
                .unwrap());
                assert!(!selected_usim_ready_inner(
                    target,
                    &cards(target, true, provisioned),
                    true
                )
                .unwrap());
            }
            assert!(selected_usim_ready(target, &cards(target, false, true)).unwrap());
            assert!(!selected_usim_ready(target, &cards(target, false, false)).unwrap());
            let other = if target == Target::Internal {
                Target::Removable
            } else {
                Target::Internal
            };
            assert!(!selected_usim_ready(target, &cards(other, false, true)).unwrap());
        }
    }
    #[test]
    fn single_card_permission_requires_other_cards_explicitly_absent() {
        for target in TARGETS {
            // Empty applications keep the two six-byte card records fixed.
            let other_state_offset = if target == Target::Internal { 9 } else { 15 };
            for state in [1, 2, 255] {
                let mut status = cards(target, false, false);
                status[other_state_offset] = state;
                assert!(!selected_usim_ready_inner(target, &status, true).unwrap_or(false));
            }
        }
    }
    #[test]
    fn malformed_inventory_never_yields_partial_discovery_or_single_card_permission() {
        let b = rows(&[(2, 1, 1), (1, 1, 2)]);
        for end in 0..b.len() {
            assert!(slot_rows(&b[..end]).is_err());
        }
        let mut trailing = b.clone();
        trailing.push(0);
        assert!(slot_rows(&trailing).is_err());
        for bad in [
            rows(&[(2, 1, 1), (1, 1, 1)]),
            rows(&[(3, 1, 1)]),
            rows(&[(2, 2, 1)]),
            rows(&[(2, 1, 9)]),
        ] {
            assert!(slot_rows(&bad).is_err());
        }
    }
}
