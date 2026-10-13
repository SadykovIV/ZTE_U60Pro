//! Read-only QMI survey. No card/channel/profile/radio mutation API is exposed.
#[path = "../../removable-euicc/device/src/qmi/qrtr.rs"]
#[allow(dead_code)]
mod qrtr;
#[path = "../../removable-euicc/device/src/qmi/tlv.rs"]
#[allow(dead_code)]
mod tlv;
use serde_json::{json, Value};
use std::time::Duration;
use tlv::Tlv;
const QUERIES: [(u32, u16, &str); 3] = [
    (2, 0x2d, "operating_mode"),
    (11, 0x2f, "card_status"),
    (11, 0x47, "slot_status"),
];
fn unique(v: &[Tlv], tag: u8) -> Result<&[u8], &'static str> {
    let mut found = v.iter().filter(|t| t.tag == tag);
    let value = found.next().ok_or("missing_field")?;
    if found.next().is_some() {
        return Err("duplicate_field");
    }
    Ok(&value.value)
}
struct Read<'a> {
    bytes: &'a [u8],
    at: usize,
}
impl<'a> Read<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], &'static str> {
        let end = self.at.checked_add(n).ok_or("length_overflow")?;
        let b = self.bytes.get(self.at..end).ok_or("truncated_field")?;
        self.at = end;
        Ok(b)
    }
    fn byte(&mut self) -> Result<u8, &'static str> {
        Ok(self.take(1)?[0])
    }
    fn word(&mut self) -> Result<u32, &'static str> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn end(&self) -> Result<(), &'static str> {
        if self.at == self.bytes.len() {
            Ok(())
        } else {
            Err("trailing_bytes")
        }
    }
}
fn cards(data: &[u8]) -> Result<Value, &'static str> {
    let mut r = Read { bytes: data, at: 0 };
    r.take(8)?;
    let count = r.byte()?;
    if count > 8 {
        return Err("card_count");
    }
    let mut cards = Vec::new();
    for index in 0..count {
        let state = r.byte()?;
        r.take(3)?;
        let error = r.byte()?;
        let apps = r.byte()?;
        if apps > 32 {
            return Err("application_count");
        }
        let mut applications = Vec::new();
        for _ in 0..apps {
            let kind = r.byte()?;
            let state = r.byte()?;
            r.take(4)?;
            let length = r.byte()? as usize;
            r.take(length)?;
            r.take(7)?;
            applications.push(json!({"type":kind,"state":state,"aid_length":length}));
        }
        cards.push(json!({"logical_index":index+1,"state":state,"error":error,"applications":applications}));
    }
    r.end()?;
    Ok(json!(cards))
}
fn slots(v: &[Tlv]) -> Result<Value, &'static str> {
    let data = unique(v, 0x10)?;
    let mut r = Read { bytes: data, at: 0 };
    let count = r.byte()?;
    if count > 32 {
        return Err("slot_count");
    }
    let mut slots = Vec::new();
    for index in 0..count {
        let card = r.word()?;
        let active = r.word()?;
        let logical = r.byte()?;
        let length = r.byte()? as usize;
        r.take(length)?;
        if card > 2 || active > 1 {
            return Err("slot_enum");
        }
        slots.push(json!({"physical_index":index+1,"card_state":card,"slot_state":active,"logical_slot":logical,"iccid_length":length}));
    }
    r.end()?;
    for tag in [0x11, 0x12] {
        if !v.iter().any(|t| t.tag == tag) {
            continue;
        }
        let mut r = Read {
            bytes: unique(v, tag)?,
            at: 0,
        };
        if r.byte()? != count {
            return Err("slot_array_count");
        }
        for slot in &mut slots {
            if tag == 0x11 {
                let protocol = r.word()?;
                let apps = r.byte()?;
                let len = r.byte()? as usize;
                r.take(len)?;
                let euicc = r.byte()?;
                if euicc > 1 {
                    return Err("euicc_enum");
                }
                slot["protocol"] = json!(protocol);
                slot["application_count"] = json!(apps);
                slot["atr_length"] = json!(len);
                slot["is_euicc"] = json!(euicc == 1);
            } else {
                let length = r.byte()? as usize;
                r.take(length)?;
                slot["eid_length"] = json!(length);
            }
        }
        r.end()?;
    }
    Ok(json!(slots))
}
fn response(message: u16, v: &[Tlv]) -> Result<Value, &'static str> {
    if !QUERIES.iter().any(|(_, id, _)| *id == message) {
        return Err("operation_not_readonly");
    }
    let result = unique(v, 2)?;
    if result.len() != 4 {
        return Err("result_length");
    }
    let status = u16::from_le_bytes([result[0], result[1]]);
    let error = u16::from_le_bytes([result[2], result[3]]);
    let mut out = json!({"status":"observed","qmi_result":status,"qmi_error":error});
    if status != 0 || error != 0 {
        return Ok(out);
    }
    match message {
        0x2d => {
            let mode = unique(v, 1)?;
            if mode.len() != 1 {
                return Err("mode_length");
            }
            out["mode"] = json!(mode[0]);
        }
        0x2f => {
            let data = unique(v, 0x10)?;
            out["cards"] = cards(data)?;
            for (index, name) in [
                "primary_gw_index",
                "primary_1x_index",
                "secondary_gw_index",
                "secondary_1x_index",
            ]
            .into_iter()
            .enumerate()
            {
                out[name] = json!(u16::from_le_bytes([data[index * 2], data[index * 2 + 1]]));
            }
        }
        0x47 => out["slots"] = slots(v)?,
        _ => return Err("operation_not_readonly"),
    }
    Ok(out)
}
fn survey(mut request: impl FnMut(u32, u16) -> Result<Vec<Tlv>, &'static str>) -> Value {
    let mut observations = serde_json::Map::new();
    for (service, message, name) in QUERIES {
        let value = match request(service, message).and_then(|v| response(message, &v)) {
            Ok(v) => v,
            Err(code) => json!({"status":"not_assessed","reason":code}),
        };
        observations.insert(name.into(), value);
    }
    json!({"schema":1,"observations":observations,"identifiers_exported":false,"radio_reset":false,"slot_switch":false,"apdu_performed":false,"profile_mutation":false,"provisioning_proven":false})
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.as_slice() != ["--inspect-current-card"] {
        eprintln!("usage: zte-support-qmi --inspect-current-card");
        std::process::exit(2);
    }
    std::panic::set_hook(Box::new(|_| eprintln!("SUPPORT_QMI_PANIC")));
    let result = survey(|service, message| {
        let mut client = qrtr::QrtrClient::connect(service, Duration::from_secs(5))
            .map_err(|_| "service_unavailable")?;
        client
            .request_exact(message, &[])
            .map_err(|_| "request_failed")
    });
    println!("{result}");
}
#[cfg(test)]
mod tests {
    use super::*;
    fn item(tag: u8, value: Vec<u8>) -> Tlv {
        Tlv { tag, value }
    }
    fn ok() -> Tlv {
        item(2, vec![0, 0, 0, 0])
    }
    #[test]
    fn only_three_read_messages_with_no_mutation() {
        let mut calls = vec![];
        let v = survey(|s, m| {
            calls.push((s, m));
            Err("fixture_unavailable")
        });
        assert_eq!(calls, vec![(2, 45), (11, 47), (11, 71)]);
        assert_eq!(v["profile_mutation"], false);
        assert_eq!(v["apdu_performed"], false);
    }
    #[test]
    fn identifiers_are_discarded() {
        let mut data = vec![1];
        data.extend_from_slice(&2u32.to_le_bytes());
        data.extend_from_slice(&1u32.to_le_bytes());
        data.extend_from_slice(&[1, 10]);
        data.extend_from_slice(b"SECRET_SIM");
        let v = response(
            0x47,
            &[
                ok(),
                item(0x10, data),
                item(0x11, vec![1, 0, 0, 0, 0, 1, 3, 1, 2, 3, 1]),
                item(0x12, [vec![1, 16], b"PRIVATE_EID_1234".to_vec()].concat()),
            ],
        )
        .unwrap();
        let s = v.to_string();
        assert!(!s.contains("SECRET") && !s.contains("PRIVATE"));
        assert_eq!(v["slots"][0]["is_euicc"], true);
        assert_eq!(v["slots"][0]["eid_length"], 16);
    }
    #[test]
    fn card_application_has_only_type_state_length() {
        let mut data = vec![0; 8];
        data.extend_from_slice(&[1, 1, 0, 0, 0, 0, 1, 2, 7, 0, 0, 0, 0, 6]);
        data.extend_from_slice(b"SECRET");
        data.extend_from_slice(&[0; 7]);
        let v = cards(&data).unwrap();
        assert!(!v.to_string().contains("SECRET"));
        assert_eq!(v[0]["applications"][0]["aid_length"], 6);
    }
    #[test]
    fn malformed_arrays_fail_without_partial_card_claims() {
        for n in 0..11 {
            let data = vec![0; n];
            assert!(cards(&data).is_err() || n == 9);
        }
        assert!(response(0x47, &[ok(), item(0x10, vec![1, 2])]).is_err());
        assert!(response(0x2d, &[ok(), ok(), item(1, vec![0])]).is_err());
    }
    #[test]
    fn qmi_error_retains_numeric_reason_without_raw_body() {
        let v = response(
            0x47,
            &[item(2, vec![1, 0, 94, 0]), item(0x10, b"SECRET".to_vec())],
        )
        .unwrap();
        assert_eq!(v["qmi_error"], 94);
        assert!(!v.to_string().contains("SECRET"));
    }
    fn slot_rows(rows: &[(u32, u32, u8, &[u8])]) -> Vec<u8> {
        let mut out = vec![rows.len() as u8];
        for (card, active, logical, id) in rows {
            out.extend_from_slice(&card.to_le_bytes());
            out.extend_from_slice(&active.to_le_bytes());
            out.push(*logical);
            out.push(id.len() as u8);
            out.extend_from_slice(id);
        }
        out
    }
    fn full_slots() -> Vec<Tlv> {
        vec![
            ok(),
            item(
                0x10,
                slot_rows(&[
                    (2, 0, 0, b"REMOVABLE_PRIVATE"),
                    (2, 1, 2, b"EMBEDDED_PRIVATE"),
                ]),
            ),
            item(
                0x11,
                vec![2, 0, 0, 0, 0, 1, 2, 0xab, 0xcd, 0, 1, 0, 0, 0, 2, 0, 1],
            ),
            item(0x12, [vec![2, 0, 16], vec![0xab; 16]].concat()),
        ]
    }
    #[test]
    fn success_with_error_never_exposes_card_state() {
        for message in [0x2d, 0x2f, 0x47] {
            let v = response(
                message,
                &[
                    item(2, vec![0, 0, 3, 0]),
                    item(1, vec![0]),
                    item(0x10, vec![0]),
                ],
            )
            .unwrap();
            assert_eq!(v["qmi_error"], 3);
            assert!(
                v.get("mode").is_none() && v.get("cards").is_none() && v.get("slots").is_none()
            );
        }
        assert_eq!(
            response(0x31, &[item(2, vec![1, 0, 3, 0])]),
            Err("operation_not_readonly")
        );
    }
    #[test]
    fn all_slot_array_truncations_and_trailing_bytes_are_rejected() {
        let fixture = full_slots();
        assert!(response(0x47, &fixture).is_ok());
        for index in 1..fixture.len() {
            for n in 0..fixture[index].value.len() {
                let mut v = fixture.clone();
                v[index].value.truncate(n);
                assert!(
                    response(0x47, &v).is_err(),
                    "tag={} length={n}",
                    fixture[index].tag
                );
            }
            let mut v = fixture.clone();
            v[index].value.push(0);
            assert!(response(0x47, &v).is_err());
            let mut v = fixture.clone();
            v.push(fixture[index].clone());
            assert_eq!(response(0x47, &v), Err("duplicate_field"));
        }
    }
    #[test]
    fn embedded_route_observation_never_falls_back_to_first_physical_slot() {
        let result = response(0x47, &full_slots()).unwrap();
        let rows = result["slots"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["slot_state"], 0);
        assert_eq!(rows[1]["physical_index"], 2);
        assert_eq!(rows[1]["logical_slot"], 2);
        assert_eq!(rows[1]["is_euicc"], true);
        assert!(result.get("selected_card").is_none());
        assert!(result.get("card_kind").is_none());
        assert!(!result.to_string().contains("PRIVATE"));
    }
    #[test]
    fn absent_optional_capabilities_remain_unknown() {
        let result = response(0x47, &[ok(), item(0x10, slot_rows(&[(2, 1, 1, b"")]))]).unwrap();
        assert_eq!(result["slots"][0]["iccid_length"], 0);
        for key in ["is_euicc", "eid_length", "atr_length"] {
            assert!(result["slots"][0].get(key).is_none());
        }
    }
    #[test]
    fn array_counts_enums_and_duplicate_results_are_rejected() {
        let mut fixture = full_slots();
        fixture[2].value[0] = 1;
        assert_eq!(response(0x47, &fixture), Err("slot_array_count"));
        fixture = full_slots();
        fixture[3].value[0] = 1;
        assert_eq!(response(0x47, &fixture), Err("slot_array_count"));
        fixture = full_slots();
        fixture[2].value[9] = 2;
        assert_eq!(response(0x47, &fixture), Err("euicc_enum"));
        fixture = full_slots();
        fixture.push(ok());
        assert_eq!(response(0x47, &fixture), Err("duplicate_field"));
        assert_eq!(
            response(0x47, &[ok(), item(0x10, slot_rows(&[(3, 1, 1, b"")]))]),
            Err("slot_enum")
        );
        assert_eq!(
            response(0x47, &[ok(), item(0x10, slot_rows(&[(2, 2, 1, b"")]))]),
            Err("slot_enum")
        );
    }
    #[test]
    fn every_card_field_truncation_is_rejected() {
        let mut data = vec![0, 0, 255, 255, 255, 255, 255, 255];
        data.extend_from_slice(&[1, 1, 0, 0, 0, 0, 1, 2, 7, 0, 0, 0, 0, 6]);
        data.extend_from_slice(b"SECRET");
        data.extend_from_slice(&[0; 7]);
        assert!(cards(&data).is_ok());
        for n in 0..data.len() {
            assert!(cards(&data[..n]).is_err(), "length={n}");
        }
        data.push(0);
        assert_eq!(cards(&data), Err("trailing_bytes"));
    }
    #[test]
    fn provisioning_indices_are_numeric_and_absent_sentinel_is_preserved() {
        let data = vec![0, 0, 255, 255, 3, 1, 2, 2, 0];
        let result = response(0x2f, &[ok(), item(0x10, data)]).unwrap();
        assert_eq!(result["primary_gw_index"], 0);
        assert_eq!(result["primary_1x_index"], 65535);
        assert_eq!(result["secondary_gw_index"], 259);
        assert_eq!(result["secondary_1x_index"], 514);
        assert_eq!(result["cards"], json!([]));
    }
    #[test]
    fn survey_keeps_independent_queries_when_one_parser_fails() {
        let result = survey(|_, message| {
            Ok(match message {
                0x2d => vec![ok(), item(1, vec![0])],
                0x2f => vec![ok(), item(0x10, vec![1])],
                _ => full_slots(),
            })
        });
        assert_eq!(result["observations"]["operating_mode"]["mode"], 0);
        assert_eq!(
            result["observations"]["card_status"]["status"],
            "not_assessed"
        );
        assert_eq!(
            result["observations"]["slot_status"]["slots"][1]["logical_slot"],
            2
        );
    }
}
