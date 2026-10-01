//! QMI TLV encoding/decoding.
//!
//! Wire format is `{u8 type}{u16 len, little-endian}{value}`, repeated until
//! the message payload is exhausted.

/// The standard QMI result TLV present on every response.
pub const TLV_RESULT: u8 = 0x02;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tlv {
    pub tag: u8,
    pub value: Vec<u8>,
}

/// Serialize TLVs into a QMI message payload.
pub fn encode(tlvs: &[Tlv]) -> Vec<u8> {
    let mut out = Vec::new();
    for tlv in tlvs {
        out.push(tlv.tag);
        out.extend_from_slice(&(tlv.value.len() as u16).to_le_bytes());
        out.extend_from_slice(&tlv.value);
    }
    out
}

/// Parse a QMI message payload into TLVs.
///
/// A truncated trailing TLV is an error rather than a silent drop: a partially
/// read APDU response would otherwise look like a short-but-valid one.
pub fn decode(mut data: &[u8]) -> Result<Vec<Tlv>, String> {
    let mut out = Vec::new();
    while !data.is_empty() {
        if data.len() < 3 {
            return Err(format!("truncated TLV header ({} bytes left)", data.len()));
        }
        let tag = data[0];
        let len = u16::from_le_bytes([data[1], data[2]]) as usize;
        if data.len() < 3 + len {
            return Err(format!(
                "TLV 0x{tag:02X} declares {len} bytes, {} available",
                data.len() - 3
            ));
        }
        out.push(Tlv {
            tag,
            value: data[3..3 + len].to_vec(),
        });
        data = &data[3 + len..];
    }
    Ok(out)
}

/// Find a TLV by tag.
pub fn find<'a>(tlvs: &'a [Tlv], tag: u8) -> Option<&'a [u8]> {
    tlvs.iter().find(|t| t.tag == tag).map(|t| t.value.as_slice())
}

/// A single-byte TLV.
pub fn u8_tlv(tag: u8, value: u8) -> Tlv {
    Tlv {
        tag,
        value: vec![value],
    }
}

/// A TLV whose value is `{u8 len}{bytes}` — QMI's 8-bit-length sequence.
pub fn seq8_tlv(tag: u8, bytes: &[u8]) -> Tlv {
    let mut value = Vec::with_capacity(1 + bytes.len());
    value.push(bytes.len() as u8);
    value.extend_from_slice(bytes);
    Tlv { tag, value }
}

/// A TLV whose value is `{u16 len, little-endian}{bytes}`.
pub fn seq16_tlv(tag: u8, bytes: &[u8]) -> Tlv {
    let mut value = Vec::with_capacity(2 + bytes.len());
    value.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
    value.extend_from_slice(bytes);
    Tlv { tag, value }
}

/// Read a `{u16 len}{bytes}` sequence out of a TLV value.
pub fn read_seq16(value: &[u8]) -> Result<&[u8], String> {
    if value.len() < 2 {
        return Err("sequence shorter than its 2-byte length prefix".into());
    }
    let len = u16::from_le_bytes([value[0], value[1]]) as usize;
    value
        .get(2..2 + len)
        .ok_or_else(|| format!("sequence declares {len} bytes, {} available", value.len() - 2))
}

/// Check the standard result TLV. `Ok(())` means the request succeeded.
pub fn check_result(tlvs: &[Tlv]) -> Result<(), String> {
    let value = find(tlvs, TLV_RESULT).ok_or("response has no result TLV")?;
    if value.len() < 4 {
        return Err(format!("result TLV is {} bytes, want 4", value.len()));
    }
    let result = u16::from_le_bytes([value[0], value[1]]);
    let error = u16::from_le_bytes([value[2], value[3]]);
    if result == 0 {
        Ok(())
    } else {
        Err(format!("QMI error {error} ({})", qmi_error_name(error)))
    }
}

/// Names for the QMI errors this agent can plausibly provoke. Anything else is
/// reported by number.
fn qmi_error_name(code: u16) -> &'static str {
    match code {
        1 => "malformed message",
        2 => "no memory",
        3 => "internal",
        5 => "client ids exhausted",
        16 => "invalid transition",
        17 => "no effect",
        22 => "device in use",
        26 => "not supported",
        29 => "no such element",
        31 => "insufficient resources",
        49 => "invalid arguments",
        52 => "invalid index",
        61 => "sim file not found",
        90 => "card error",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_tlvs() {
        let tlvs = vec![u8_tlv(0x01, 0x01), seq16_tlv(0x02, &[0xAA, 0xBB])];
        let encoded = encode(&tlvs);
        assert_eq!(encoded, vec![0x01, 0x01, 0x00, 0x01, 0x02, 0x04, 0x00, 0x02, 0x00, 0xAA, 0xBB]);
        assert_eq!(decode(&encoded).unwrap(), tlvs);
    }

    #[test]
    fn rejects_truncated_tlv() {
        // Declares 4 bytes but only 2 follow.
        assert!(decode(&[0x10, 0x04, 0x00, 0xAA, 0xBB]).is_err());
        assert!(decode(&[0x10, 0x04]).is_err());
    }

    #[test]
    fn decodes_empty_payload() {
        assert_eq!(decode(&[]).unwrap(), vec![]);
    }

    #[test]
    fn reads_result_tlv() {
        // result=0 (success), error=0
        let ok = vec![Tlv { tag: TLV_RESULT, value: vec![0, 0, 0, 0] }];
        assert!(check_result(&ok).is_ok());
        // result=1 (failure), error=26 (not supported)
        let err = vec![Tlv { tag: TLV_RESULT, value: vec![1, 0, 26, 0] }];
        let message = check_result(&err).unwrap_err();
        assert!(message.contains("26"), "{message}");
        assert!(message.contains("not supported"), "{message}");
    }

    #[test]
    fn result_tlv_must_be_present_and_sized() {
        assert!(check_result(&[]).is_err());
        assert!(check_result(&[Tlv { tag: TLV_RESULT, value: vec![0, 0] }]).is_err());
    }

    #[test]
    fn reads_length_prefixed_sequences() {
        assert_eq!(read_seq16(&[0x02, 0x00, 0xAA, 0xBB]).unwrap(), &[0xAA, 0xBB]);
        // Trailing bytes past the declared length are ignored.
        assert_eq!(read_seq16(&[0x01, 0x00, 0xAA, 0xBB]).unwrap(), &[0xAA]);
        assert!(read_seq16(&[0x05, 0x00, 0xAA]).is_err());
        assert!(read_seq16(&[0x00]).is_err());
    }
}
