//! GSMA SGP.22 ES10 command construction and response parsing.
//!
//! Read-only commands only: ES10c `GetEID` and `GetProfilesInfo`. Nothing here
//! can change card state.

use super::bertlv::{self, Node};

/// The standard GSMA ISD-R application, confirmed present on this card.
pub const ISD_R_AID: [u8; 16] = [
    0xA0, 0x00, 0x00, 0x05, 0x59, 0x10, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x89, 0x00, 0x00, 0x01, 0x00,
];

const TAG_EID_RESPONSE: u32 = 0xBF3E;
const TAG_EID: u32 = 0x5A;
const TAG_PROFILE_LIST_RESPONSE: u32 = 0xBF2D;
const TAG_PROFILE_LIST_OK: u32 = 0xA0;
const TAG_PROFILE_INFO: u32 = 0xE3;
const TAG_ICCID: u32 = 0x5A;
const TAG_ISDP_AID: u32 = 0x4F;
const TAG_PROFILE_STATE: u32 = 0x9F70;
const TAG_NICKNAME: u32 = 0x90;
const TAG_SERVICE_PROVIDER: u32 = 0x91;
const TAG_PROFILE_NAME: u32 = 0x92;
const TAG_PROFILE_CLASS: u32 = 0x95;
const TAG_PROFILE_POLICY_RULES: u32 = 0x99;

/// Wrap an ES10 command in the ISD-R STORE DATA APDU.
///
/// `80 E2 91 00 <Lc> <command> 00` — a single-block command with Le=0. Every
/// read-only ES10 request used here is far short of the 255-byte block limit.
pub fn store_data(command: &[u8]) -> Result<Vec<u8>, String> {
    if command.is_empty() || command.len() > 255 {
        return Err(format!(
            "ES10 command length {} is out of range",
            command.len()
        ));
    }
    let mut apdu = vec![0x80, 0xE2, 0x91, 0x00, command.len() as u8];
    apdu.extend_from_slice(command);
    apdu.push(0x00);
    Ok(apdu)
}

/// ES10c `GetEIDRequest`: `BF3E 03 5C 01 5A`.
pub fn get_eid_request() -> Result<Vec<u8>, String> {
    store_data(&[0xBF, 0x3E, 0x03, 0x5C, 0x01, 0x5A])
}

/// ES10c `ProfileInfoListRequest`: `BF2D 00`, i.e. all profiles, all fields.
pub fn get_profiles_request() -> Result<Vec<u8>, String> {
    store_data(&[0xBF, 0x2D, 0x00])
}

/// GET RESPONSE for the `61 XX` chaining the card uses to return ES10 payloads.
pub fn get_response(length: u8) -> Vec<u8> {
    vec![0x80, 0xC0, 0x00, 0x00, length]
}

/// Split an APDU response into its data and SW1/SW2.
pub fn split_status(response: &[u8]) -> Result<(&[u8], u16), String> {
    if response.len() < 2 {
        return Err(format!(
            "APDU response is {} bytes, too short for a status word",
            response.len()
        ));
    }
    let split = response.len() - 2;
    let sw = u16::from_be_bytes([response[split], response[split + 1]]);
    Ok((&response[..split], sw))
}

/// Parse an ES10c `GetEIDResponse` into the 32-digit EID.
pub fn parse_eid(data: &[u8]) -> Result<String, String> {
    let root = bertlv::parse(data)?;
    let response = bertlv::find(&root, TAG_EID_RESPONSE).ok_or("EID response tag BF3E missing")?;
    let children = response.children()?;
    let eid = bertlv::find(&children, TAG_EID).ok_or("EID value tag 5A missing")?;
    if eid.value.len() != 16 {
        return Err(format!("EID is {} bytes, want 16", eid.value.len()));
    }
    Ok(bertlv::bcd_to_digits(&eid.value, false))
}

/// One profile as reported by the eUICC.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProfileInfo {
    pub iccid: Option<String>,
    pub isdp_aid: Option<String>,
    /// `0` = disabled, `1` = enabled.
    pub state: Option<u8>,
    /// `0` = test, `1` = provisioning, `2` = operational.
    pub class: Option<u8>,
    pub nickname: Option<String>,
    pub service_provider: Option<String>,
    pub name: Option<String>,
    /// Profile Policy Rules, if the profile carries any.
    ///
    /// Worth surfacing because they are the difference between "this operation
    /// failed" and "this operation can never succeed": an operator can ship a
    /// profile that the card will refuse to disable or delete for the life of
    /// the profile, and the only symptom otherwise is a bare
    /// `es10c_disable_profile` with no explanation.
    pub policy: ProfilePolicy,
}

/// SGP.22 `PprIds`, the subset that changes what a user can do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ProfilePolicy {
    /// PPR1 — disabling this profile is not allowed.
    pub disable_blocked: bool,
    /// PPR2 — deleting this profile is not allowed.
    pub delete_blocked: bool,
}

/// Decode the `PprIds` BIT STRING.
///
/// DER bit strings lead with a count of unused trailing bits, so the flags live
/// in the byte after that, most significant bit first:
/// `pprUpdateControl(0)`, `ppr1(1)`, `ppr2(2)`.
fn parse_policy_rules(value: &[u8]) -> ProfilePolicy {
    let Some(&bits) = value.get(1) else {
        return ProfilePolicy::default();
    };
    ProfilePolicy {
        disable_blocked: bits & 0x40 != 0,
        delete_blocked: bits & 0x20 != 0,
    }
}

impl ProfileInfo {
    pub fn state_label(&self) -> &'static str {
        match self.state {
            Some(0) => "disabled",
            Some(1) => "enabled",
            Some(_) => "unknown",
            None => "unknown",
        }
    }

    pub fn class_label(&self) -> &'static str {
        match self.class {
            Some(0) => "test",
            Some(1) => "provisioning",
            Some(2) => "operational",
            Some(_) => "unknown",
            None => "unknown",
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.state == Some(1)
    }
}

/// Parse an ES10c `ProfileInfoListResponse`.
///
/// An empty `A0` list is valid and means the eUICC has no profiles installed;
/// a missing `A0` means the card returned the error branch instead.
pub fn parse_profiles(data: &[u8]) -> Result<Vec<ProfileInfo>, String> {
    let root = bertlv::parse(data)?;
    let response =
        bertlv::find(&root, TAG_PROFILE_LIST_RESPONSE).ok_or("profile list tag BF2D missing")?;
    let children = response.children()?;
    let list = bertlv::find(&children, TAG_PROFILE_LIST_OK)
        .ok_or("eUICC returned a profile list error rather than a list")?;

    let mut profiles = Vec::new();
    for node in list.children()? {
        if node.tag != TAG_PROFILE_INFO {
            continue;
        }
        profiles.push(parse_profile_info(&node.children()?));
    }
    Ok(profiles)
}

fn parse_profile_info(fields: &[Node]) -> ProfileInfo {
    let text = |tag: u32| {
        bertlv::find(fields, tag)
            .map(|n| String::from_utf8_lossy(&n.value).trim().to_string())
            .filter(|s| !s.is_empty())
    };
    let byte = |tag: u32| bertlv::find(fields, tag).and_then(|n| n.value.first().copied());

    ProfileInfo {
        iccid: bertlv::find(fields, TAG_ICCID)
            .map(|n| bertlv::bcd_to_digits(&n.value, true))
            .filter(|s| !s.is_empty()),
        isdp_aid: bertlv::find(fields, TAG_ISDP_AID).map(|n| hex(&n.value)),
        state: byte(TAG_PROFILE_STATE),
        class: byte(TAG_PROFILE_CLASS),
        nickname: text(TAG_NICKNAME),
        service_provider: text(TAG_SERVICE_PROVIDER),
        name: text(TAG_PROFILE_NAME),
        policy: bertlv::find(fields, TAG_PROFILE_POLICY_RULES)
            .map(|n| parse_policy_rules(&n.value))
            .unwrap_or_default(),
    }
}

pub fn hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02X}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_profile_policy_rules() {
        // One unused bit, then ppr1 set: disabling refused, deleting allowed.
        assert_eq!(
            parse_policy_rules(&[0x01, 0x40]),
            ProfilePolicy { disable_blocked: true, delete_blocked: false }
        );
        assert_eq!(
            parse_policy_rules(&[0x01, 0x20]),
            ProfilePolicy { disable_blocked: false, delete_blocked: true }
        );
        assert_eq!(
            parse_policy_rules(&[0x01, 0x60]),
            ProfilePolicy { disable_blocked: true, delete_blocked: true }
        );
        // No rules at all, and a truncated value, both mean "nothing blocked".
        assert_eq!(parse_policy_rules(&[0x00]), ProfilePolicy::default());
        assert_eq!(parse_policy_rules(&[]), ProfilePolicy::default());
    }

    #[test]
    fn builds_read_only_requests() {
        assert_eq!(
            get_eid_request().unwrap(),
            vec![0x80, 0xE2, 0x91, 0x00, 0x06, 0xBF, 0x3E, 0x03, 0x5C, 0x01, 0x5A, 0x00]
        );
        assert_eq!(
            get_profiles_request().unwrap(),
            vec![0x80, 0xE2, 0x91, 0x00, 0x03, 0xBF, 0x2D, 0x00, 0x00]
        );
        assert_eq!(get_response(0x15), vec![0x80, 0xC0, 0x00, 0x00, 0x15]);
    }

    #[test]
    fn rejects_oversized_store_data() {
        assert!(store_data(&[]).is_err());
        assert!(store_data(&vec![0u8; 256]).is_err());
        assert!(store_data(&vec![0u8; 255]).is_ok());
    }

    #[test]
    fn splits_status_words() {
        let (data, sw) = split_status(&[0xAA, 0xBB, 0x90, 0x00]).unwrap();
        assert_eq!(data, &[0xAA, 0xBB]);
        assert_eq!(sw, 0x9000);
        let (data, sw) = split_status(&[0x61, 0x15]).unwrap();
        assert!(data.is_empty());
        assert_eq!(sw, 0x6115);
        assert!(split_status(&[0x90]).is_err());
    }

    /// Synthetic GetEIDResponse. The EID digits are placeholders, not the
    /// device's real EID.
    #[test]
    fn parses_eid() {
        let mut data = vec![0xBF, 0x3E, 0x12, 0x5A, 0x10];
        data.extend_from_slice(&[
            0x89, 0x04, 0x40, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12,
            0x34, 0x56,
        ]);
        assert_eq!(
            parse_eid(&data).unwrap(),
            "89044012345678901234567890123456"
        );
    }

    #[test]
    fn rejects_bad_eid_responses() {
        // Wrong outer tag.
        assert!(parse_eid(&[0xBF, 0x2D, 0x02, 0x5A, 0x00]).is_err());
        // 5A present but not 16 bytes.
        assert!(parse_eid(&[0xBF, 0x3E, 0x04, 0x5A, 0x02, 0xAA, 0xBB]).is_err());
        // No 5A at all.
        assert!(parse_eid(&[0xBF, 0x3E, 0x02, 0x4F, 0x00]).is_err());
    }

    /// A synthetic single-profile ProfileInfoListResponse shaped like the one
    /// the device returned. All identifiers are placeholders.
    fn profile_list_fixture() -> Vec<u8> {
        let mut info = Vec::new();
        // iccid — nibble-swapped BCD of 89490102186110201029
        info.extend_from_slice(&[
            0x5A, 0x0A, 0x98, 0x94, 0x10, 0x20, 0x81, 0x16, 0x01, 0x02, 0x01, 0x92,
        ]);
        // isdpAid
        info.extend_from_slice(&[0x4F, 0x04, 0xA0, 0x00, 0x00, 0x05]);
        // profileState = 1 (enabled)
        info.extend_from_slice(&[0x9F, 0x70, 0x01, 0x01]);
        // nickname
        info.extend_from_slice(&[0x90, 0x04]);
        info.extend_from_slice(b"Home");
        // serviceProviderName
        info.extend_from_slice(&[0x91, 0x03]);
        info.extend_from_slice(b"MLS");
        // profileName
        info.extend_from_slice(&[0x92, 0x07]);
        info.extend_from_slice(b"Mobitel");
        // profileClass = 2 (operational)
        info.extend_from_slice(&[0x95, 0x01, 0x02]);

        let mut e3 = vec![0xE3, info.len() as u8];
        e3.extend_from_slice(&info);
        let mut a0 = vec![0xA0, e3.len() as u8];
        a0.extend_from_slice(&e3);
        let mut out = vec![0xBF, 0x2D, a0.len() as u8];
        out.extend_from_slice(&a0);
        out
    }

    #[test]
    fn parses_profile_list() {
        let profiles = parse_profiles(&profile_list_fixture()).unwrap();
        assert_eq!(profiles.len(), 1);
        let p = &profiles[0];
        assert_eq!(p.iccid.as_deref(), Some("89490102186110201029"));
        assert_eq!(p.isdp_aid.as_deref(), Some("A0000005"));
        assert!(p.is_enabled());
        assert_eq!(p.state_label(), "enabled");
        assert_eq!(p.class_label(), "operational");
        assert_eq!(p.nickname.as_deref(), Some("Home"));
        assert_eq!(p.service_provider.as_deref(), Some("MLS"));
        assert_eq!(p.name.as_deref(), Some("Mobitel"));
    }

    #[test]
    fn parses_empty_profile_list() {
        // BF2D { A0 {} } — a commissioned eUICC with nothing installed.
        assert_eq!(parse_profiles(&[0xBF, 0x2D, 0x02, 0xA0, 0x00]).unwrap(), vec![]);
    }

    #[test]
    fn reports_profile_list_error_branch() {
        // BF2D { A1 ... } is the error branch, not a list.
        let err = parse_profiles(&[0xBF, 0x2D, 0x03, 0xA1, 0x01, 0x02]).unwrap_err();
        assert!(err.contains("error"), "{err}");
    }

    #[test]
    fn tolerates_profiles_missing_optional_fields() {
        // BF2D(12) { A0(10) { E3(8) { 5A 02 9894, 9F70 01 00 } } }
        let data = [
            0xBF, 0x2D, 0x0C, 0xA0, 0x0A, 0xE3, 0x08, 0x5A, 0x02, 0x98, 0x94, 0x9F, 0x70, 0x01,
            0x00,
        ];
        let profiles = parse_profiles(&data).unwrap();
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].iccid.as_deref(), Some("8949"));
        assert_eq!(profiles[0].state_label(), "disabled");
        assert_eq!(profiles[0].class_label(), "unknown");
        assert_eq!(profiles[0].name, None);
        assert_eq!(profiles[0].nickname, None);
    }
}
