//! DMS/UIM radio status and constrained temporary low-power/online transitions.
mod qrtr;
mod tlv;
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
    if !matches!((service, message), (2, 0x2d) | (11, 0x47)) {
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

fn card_power_request(on: bool) -> (u16, [tlv::Tlv; 1]) {
    // QMI UIM Power Down/Up: required slot enum, one byte, slot1 only.
    // No optional ignore-hotswap or non-telecom-card mode is requested.
    (if on { 0x31 } else { 0x30 }, [tlv::u8_tlv(1, 1)])
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
pub fn card_power(on: bool) -> Result<()> {
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
    let (message, request) = card_power_request(on);
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
fn slot1(data: &[u8]) -> Result<String> {
    let Some(&count) = data.first() else {
        return Err(Error::new("modem_readback_failed"));
    };
    if count == 0 || count > 8 {
        return Err(Error::new("modem_readback_failed"));
    }
    let mut pos = 1;
    let mut selected = None;
    let mut alternate_logical1 = false;
    for physical in 1..=count {
        let header = data
            .get(pos..pos + 10)
            .ok_or(Error::new("modem_readback_failed"))?;
        let card = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let active = u32::from_le_bytes(header[4..8].try_into().unwrap());
        let logical = header[8];
        let len = header[9] as usize;
        pos += 10;
        let iccid = data
            .get(pos..pos + len)
            .ok_or(Error::new("modem_readback_failed"))?;
        pos += len;
        if physical == 1 {
            selected = Some((card, active, logical, iccid));
        } else if active == 1 && logical == 1 {
            alternate_logical1 = true;
        }
    }
    if pos != data.len() {
        return Err(Error::new("modem_readback_failed"));
    }
    let (card, active, logical, iccid) = selected.ok_or(Error::new("modem_readback_failed"))?;
    // Inspect all rows first: target-card initialization must not hide an
    // alternate physical card taking logical slot1.
    if alternate_logical1 {
        return Err(Error::new("modem_slot_mismatch"));
    }
    // Power-up may temporarily clear the target's active/logical assignment.
    // This does not prove rerouting. A different assignment still fails hard.
    if active == 0 && matches!(logical, 0 | 1) {
        return Err(Error::new("modem_readback_failed"));
    }
    if active != 1 || logical != 1 {
        return Err(Error::new("modem_slot_mismatch"));
    }
    if card != 2 {
        return Err(Error::new("modem_readback_failed"));
    }
    bcd_iccid(iccid)
}
pub fn iccid() -> Result<String> {
    let values = read(qrtr::SERVICE_UIM, 0x47).map_err(|_| Error::new("modem_readback_failed"))?;
    slot1(field(&values, 0x10).map_err(|_| Error::new("modem_readback_failed"))?)
}

// QMI UIM GetCardStatus (0x2f), TLV 0x10. Qualcomm IDL defines
// card PRESENT=1, USIM=2, DETECTED=1 and application READY=7. Provisioning
// indices are (zero-based logical slot << 8) | zero-based app, or 0xffff.
// Primary sources: libqmi/data/qmi-service-uim.json and qmi-enums-uim.h;
// saved Qualcomm user_identity_module_v01.h uim_card_status_type_v01.
// Parse every row before accepting a match; neither AIDs nor PIN data escape.
fn selected_usim_ready(data: &[u8]) -> Result<bool> {
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
        let present = card[0] == 1;
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
        cards.push((present, apps));
    }
    if pos != data.len() {
        return Err(fail());
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
        let (present, apps) = cards.get(slot).ok_or_else(fail)?;
        let &(app_type, app_state) = apps.get(app_index).ok_or_else(fail)?;
        // Only GW primary/secondary provisioning selects a USIM. Optional ISIM
        // need not be READY; waiting for IMS would reject otherwise usable cards.
        if matches!(kind, 0 | 2) && slot == 0 && *present && app_type == 2 && app_state == 7 {
            ready = true;
        }
    }
    Ok(ready)
}

pub fn card_ready(expected_iccid: &str, deadline: Instant) -> Result<bool> {
    let fail = || Error::new("card_not_ready");
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(fail());
    }
    let mut client =
        qrtr::QrtrClient::connect(qrtr::SERVICE_UIM, remaining.min(Duration::from_secs(2)))
            .map_err(|_| fail())?;
    // At most two empty, read-only requests in this sample, on the same UIM
    // endpoint. Recheck physical1/logical1 and expected ICCID before readiness.
    let slots = client
        .request_until(0x47, &[], deadline)
        .map_err(|_| fail())?;
    if field(&slots, 2).map_err(|_| fail())? != [0, 0, 0, 0] {
        return Err(fail());
    }
    if slot1(field(&slots, 0x10).map_err(|_| fail())?).map_err(|_| fail())? != expected_iccid {
        return Ok(false);
    }
    let cards = client
        .request_until(0x2f, &[], deadline)
        .map_err(|_| fail())?;
    if field(&cards, 2).map_err(|_| fail())? != [0, 0, 0, 0] {
        return Err(fail());
    }
    selected_usim_ready(field(&cards, 0x10).map_err(|_| fail())?)
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
    fn card_power_has_only_exact_slot1_tlv_and_strict_result() {
        for on in [false, true] {
            let (message, request) = card_power_request(on);
            assert_eq!(message, if on { 0x31 } else { 0x30 });
            assert_eq!(tlv::encode(&request), [1, 1, 0, 1]);
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
    #[test]
    fn exact_slot_and_bcd_no_guessing() {
        let mut v = vec![2];
        v.extend(row(1, &[0x98; 10]));
        v.extend(row(2, &[0x76; 10]));
        assert_eq!(slot1(&v).unwrap(), "89898989898989898989");
        v[9] = 2;
        assert_eq!(slot1(&v).unwrap_err().code, "modem_slot_mismatch");
        assert!(bcd_iccid(&[0x98; 9]).is_err());
        let mut x = [0x98; 10];
        x[9] = 0xf8;
        assert_eq!(bcd_iccid(&x).unwrap().len(), 19);
        x[0] = 0xf8;
        assert!(bcd_iccid(&x).is_err());
    }
    #[test]
    fn refuses_truncation_duplicates_and_trailing_data() {
        let mut v = vec![1];
        v.extend(row(1, &[0x98; 10]));
        for size in 0..v.len() {
            assert!(slot1(&v[..size]).is_err());
        }
        v.push(0);
        assert!(slot1(&v).is_err());
        let mut v = vec![2];
        v.extend(row(1, &[0x98; 10]));
        v.extend(row(1, &[0x98; 10]));
        assert_eq!(slot1(&v).unwrap_err().code, "modem_slot_mismatch");
        assert!(field(&[tlv::u8_tlv(1, 0), tlv::u8_tlv(1, 0)], 1).is_err());
    }
    #[test]
    fn powerup_transient_card_state_is_retryable_but_never_hides_wrong_route() {
        let build = |card: u32, active: u32, logical: u8, bytes: &[u8], other_logical: u8| {
            let mut v = vec![2];
            v.extend(card.to_le_bytes());
            v.extend(active.to_le_bytes());
            v.extend([logical, bytes.len() as u8]);
            v.extend(bytes);
            v.extend(row(other_logical, &[0x76; 10]));
            v
        };
        for (card, active, logical, bytes) in [
            (0, 1, 1, vec![]),
            (1, 1, 1, vec![]),
            (3, 1, 1, vec![]),
            (2, 1, 1, vec![]),
            (2, 0, 0, vec![]),
            (2, 0, 1, vec![0x98; 10]),
        ] {
            assert_eq!(
                slot1(&build(card, active, logical, &bytes, 2))
                    .unwrap_err()
                    .code,
                "modem_readback_failed"
            );
            // Even an absent/initializing target cannot conceal this conflict.
            assert_eq!(
                slot1(&build(card, active, logical, &bytes, 1))
                    .unwrap_err()
                    .code,
                "modem_slot_mismatch"
            );
        }
        for (active, logical) in [(1, 0), (1, 2), (0, 2)] {
            assert_eq!(
                slot1(&build(2, active, logical, &[0x98; 10], 2))
                    .unwrap_err()
                    .code,
                "modem_slot_mismatch"
            );
        }
        assert_eq!(
            slot1(&build(2, 1, 1, &[0x98; 10], 2)).unwrap(),
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
    fn readiness_requires_selected_usim_ready_seven_not_detected_one() {
        for state in 0..=8 {
            let v = card_status(
                [0, 0xffff, 0xffff, 0xffff],
                &[card(1, &[application(2, state), application(5, 1)])],
            );
            assert_eq!(selected_usim_ready(&v).unwrap(), state == 7);
        }
        // An optional, not-ready ISIM does not block the selected ready USIM.
        let v = card_status(
            [0xffff, 0xffff, 1, 0xffff],
            &[card(1, &[application(5, 1), application(2, 7)])],
        );
        assert!(selected_usim_ready(&v).unwrap());
    }
    #[test]
    fn readiness_does_not_infer_selection_from_any_ready_application() {
        let target = card(1, &[application(2, 1), application(2, 7)]);
        assert!(
            !selected_usim_ready(&card_status([0, 0xffff, 0xffff, 0xffff], &[target])).unwrap()
        );
        for indices in [[0xffff; 4], [0xffff, 0, 0xffff, 0xffff]] {
            assert!(
                !selected_usim_ready(&card_status(indices, &[card(1, &[application(2, 7)])]))
                    .unwrap()
            );
        }
        for kind in [0, 1, 3, 4, 5, 255] {
            assert!(!selected_usim_ready(&card_status(
                [0, 0xffff, 0xffff, 0xffff],
                &[card(1, &[application(kind, 7)])]
            ))
            .unwrap());
        }
        // Slot two is ready and provisioned, but this operation targets slot one.
        let v = card_status(
            [0x100, 0xffff, 0xffff, 0xffff],
            &[card(1, &[application(2, 7)]), card(1, &[application(2, 7)])],
        );
        assert!(!selected_usim_ready(&v).unwrap());
        for state in [0, 2, 255] {
            assert!(!selected_usim_ready(&card_status(
                [0, 0xffff, 0xffff, 0xffff],
                &[card(state, &[application(2, 7)])]
            ))
            .unwrap());
        }
    }
    #[test]
    fn readiness_rejects_duplicate_indices_bad_lengths_and_out_of_range_refs() {
        let v = card_status(
            [0, 0xffff, 0xffff, 0xffff],
            &[card(1, &[application(2, 7)])],
        );
        for length in 0..v.len() {
            assert!(selected_usim_ready(&v[..length]).is_err());
        }
        let mut trailing = v.clone();
        trailing.push(0);
        assert!(selected_usim_ready(&trailing).is_err());
        for indices in [
            [0, 0xffff, 0, 0xffff],
            [1, 0xffff, 0xffff, 0xffff],
            [0x100, 0xffff, 0xffff, 0xffff],
        ] {
            assert!(
                selected_usim_ready(&card_status(indices, &[card(1, &[application(2, 7)])]))
                    .is_err()
            );
        }
        for (offset, value) in [(8, 9), (14, 33), (21, 33)] {
            let mut bad = v.clone();
            bad[offset] = value;
            assert!(selected_usim_ready(&bad).is_err());
        }
    }
}
