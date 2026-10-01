//! Minimal BER-TLV reader for GSMA ES10 responses.
//!
//! Only what the eUICC actually sends is supported: multi-byte tags and
//! definite lengths up to three length octets. Indefinite lengths are rejected
//! rather than guessed at — a misparse here would be reported to the user as
//! profile data.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub tag: u32,
    pub value: Vec<u8>,
}

impl Node {
    /// Parse this node's value as a nested TLV sequence.
    pub fn children(&self) -> Result<Vec<Node>, String> {
        parse(&self.value)
    }
}

/// Parse a sequence of BER-TLV nodes.
pub fn parse(data: &[u8]) -> Result<Vec<Node>, String> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < data.len() {
        // Skip filler bytes, which some cards use to pad.
        if data[pos] == 0x00 || data[pos] == 0xFF {
            pos += 1;
            continue;
        }
        let (tag, next) = read_tag(data, pos)?;
        let (len, next) = read_len(data, next)?;
        let end = next.checked_add(len).ok_or("BER-TLV: length overflow")?;
        let value = data
            .get(next..end)
            .ok_or_else(|| format!("BER-TLV: tag {tag:X} declares {len} bytes past end of data"))?;
        out.push(Node {
            tag,
            value: value.to_vec(),
        });
        pos = end;
    }
    Ok(out)
}

fn read_tag(data: &[u8], mut pos: usize) -> Result<(u32, usize), String> {
    let first = *data.get(pos).ok_or("BER-TLV: truncated tag")?;
    pos += 1;
    let mut tag = first as u32;
    // Low 5 bits all set means the tag continues into subsequent octets.
    if first & 0x1F == 0x1F {
        loop {
            let b = *data.get(pos).ok_or("BER-TLV: truncated multi-byte tag")?;
            pos += 1;
            tag = tag
                .checked_mul(256)
                .ok_or("BER-TLV: tag longer than 4 bytes")?
                | b as u32;
            if b & 0x80 == 0 {
                break;
            }
        }
    }
    Ok((tag, pos))
}

fn read_len(data: &[u8], mut pos: usize) -> Result<(usize, usize), String> {
    let first = *data.get(pos).ok_or("BER-TLV: truncated length")?;
    pos += 1;
    if first & 0x80 == 0 {
        return Ok((first as usize, pos));
    }
    let count = (first & 0x7F) as usize;
    if count == 0 {
        return Err("BER-TLV: indefinite length is not supported".into());
    }
    if count > 3 {
        return Err(format!("BER-TLV: {count}-octet length is not supported"));
    }
    let mut len = 0usize;
    for _ in 0..count {
        let b = *data.get(pos).ok_or("BER-TLV: truncated long length")?;
        pos += 1;
        len = (len << 8) | b as usize;
    }
    Ok((len, pos))
}

/// Find the first child with `tag`.
pub fn find(nodes: &[Node], tag: u32) -> Option<&Node> {
    nodes.iter().find(|n| n.tag == tag)
}

/// Decode a BCD octet string into digits, trimming the trailing `F` padding.
///
/// `swap` selects ICCID-style nibble swapping (EF-ICCID stores each digit pair
/// reversed); EIDs are stored unswapped.
///
/// Only *trailing* `F` nibbles are removed. An `F` in the middle is invalid BCD
/// and is left in the output as `f` rather than silently shortening the value,
/// so a corrupt read is visible instead of looking like a shorter ICCID.
pub fn bcd_to_digits(data: &[u8], swap: bool) -> String {
    let mut out = String::with_capacity(data.len() * 2);
    for byte in data {
        let (first, second) = if swap {
            (byte & 0x0F, byte >> 4)
        } else {
            (byte >> 4, byte & 0x0F)
        };
        for nibble in [first, second] {
            out.push(char::from_digit(nibble as u32, 16).unwrap_or('?'));
        }
    }
    out.trim_end_matches('f').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_tlv() {
        let nodes = parse(&[0x5A, 0x02, 0xAA, 0xBB]).unwrap();
        assert_eq!(nodes, vec![Node { tag: 0x5A, value: vec![0xAA, 0xBB] }]);
    }

    #[test]
    fn parses_multi_byte_tag() {
        // 9F70 is the ES10c profileState tag.
        let nodes = parse(&[0x9F, 0x70, 0x01, 0x01]).unwrap();
        assert_eq!(nodes[0].tag, 0x9F70);
        assert_eq!(nodes[0].value, vec![0x01]);
    }

    #[test]
    fn parses_long_form_length() {
        let mut data = vec![0xBF, 0x2D, 0x81, 0x80];
        data.extend(std::iter::repeat(0x41).take(0x80));
        let nodes = parse(&data).unwrap();
        assert_eq!(nodes[0].tag, 0xBF2D);
        assert_eq!(nodes[0].value.len(), 0x80);

        let mut two_byte = vec![0x5A, 0x82, 0x01, 0x00];
        two_byte.extend(std::iter::repeat(0x42).take(256));
        assert_eq!(parse(&two_byte).unwrap()[0].value.len(), 256);
    }

    #[test]
    fn walks_nested_structures() {
        // BF2D { A0 { E3 { 5A 02 AABB } } }
        let data = [0xBF, 0x2D, 0x08, 0xA0, 0x06, 0xE3, 0x04, 0x5A, 0x02, 0xAA, 0xBB];
        let root = parse(&data).unwrap();
        let list = find(&root, 0xBF2D).unwrap().children().unwrap();
        let ok = find(&list, 0xA0).unwrap().children().unwrap();
        let info = find(&ok, 0xE3).unwrap().children().unwrap();
        assert_eq!(find(&info, 0x5A).unwrap().value, vec![0xAA, 0xBB]);
    }

    #[test]
    fn rejects_malformed_input() {
        // Declares more bytes than are present.
        assert!(parse(&[0x5A, 0x04, 0xAA]).is_err());
        // Indefinite length.
        assert!(parse(&[0xBF, 0x2D, 0x80, 0x00]).is_err());
        // Truncated multi-byte tag.
        assert!(parse(&[0x9F]).is_err());
        // Length octet missing.
        assert!(parse(&[0x5A]).is_err());
    }

    #[test]
    fn decodes_bcd() {
        // EID style — no swap, trailing F padding trimmed.
        assert_eq!(bcd_to_digits(&[0x89, 0x04, 0x4F], false), "89044");
        assert_eq!(bcd_to_digits(&[0x89, 0x04, 0x40], false), "890440");
        // ICCID style — each digit pair is stored reversed.
        assert_eq!(bcd_to_digits(&[0x98, 0x40], true), "8904");
        // Odd-length ICCID: the final F is padding.
        assert_eq!(bcd_to_digits(&[0x98, 0xF1], true), "891");
        assert_eq!(bcd_to_digits(&[], false), "");
    }

    #[test]
    fn keeps_interior_invalid_nibbles_visible() {
        // A mid-value F is not padding — surfacing it beats silently returning
        // a shorter, plausible-looking identifier.
        assert_eq!(bcd_to_digits(&[0x1F, 0x23], false), "1f23");
    }
}
