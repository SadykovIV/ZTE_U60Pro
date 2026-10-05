use super::{Error, Result, MAX_BODY};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub iccid: String,
    pub isdp_aid: Option<String>,
    pub state: String,
    pub enabled: bool,
    pub nickname: Option<String>,
    pub service_provider: Option<String>,
    pub name: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub ok: bool,
    pub eid: String,
    pub profiles: Vec<Profile>,
}

/// A read may prove an ordinary SIM without inventing an eUICC inventory.
#[derive(Clone, Debug, PartialEq)]
pub enum Inspection {
    Euicc(Snapshot),
    Ordinary,
}
impl Inspection {
    pub fn parse(value: Value) -> Result<Self> {
        if value.get("card").is_some() {
            let expected = serde_json::json!({"ok":true,"card":{
                "kind":"ordinary_sim","management":"unavailable",
                "reason":"isdr_not_found","cleanup_confirmed":true}});
            if value != expected {
                return Err(Error::new("invalid_snapshot"));
            }
            Ok(Self::Ordinary)
        } else {
            Snapshot::parse(value).map(Self::Euicc)
        }
    }
    pub fn require_euicc(self) -> Result<Snapshot> {
        match self {
            Self::Euicc(snapshot) => Ok(snapshot),
            Self::Ordinary => Err(Error::new("card_not_euicc")),
        }
    }
}

fn decimal(s: &str, lo: usize, hi: usize) -> bool {
    (lo..=hi).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit())
}
pub fn hex(s: &str, max_bytes: usize) -> bool {
    s.len() % 2 == 0 && s.len() / 2 <= max_bytes && s.bytes().all(|b| b.is_ascii_hexdigit())
}

impl Snapshot {
    pub fn parse(v: Value) -> Result<Self> {
        let s: Self = serde_json::from_value(v).map_err(|_| Error::new("invalid_snapshot"))?;
        s.validate()?;
        Ok(s)
    }
    pub fn validate(&self) -> Result<()> {
        if !self.ok || !decimal(&self.eid, 32, 32) || self.profiles.len() > 1024 {
            return Err(Error::new("invalid_snapshot"));
        }
        let (mut iccids, mut aids) = (BTreeSet::new(), BTreeSet::new());
        for p in &self.profiles {
            if !decimal(&p.iccid, 18, 20)
                || !iccids.insert(&p.iccid)
                || !matches!(p.state.as_str(), "enabled" | "disabled" | "unknown")
                || p.enabled != (p.state == "enabled")
            {
                return Err(Error::new("invalid_snapshot"));
            }
            if let Some(aid) = &p.isdp_aid {
                if aid.is_empty() || !hex(aid, 32) || !aids.insert(aid.to_ascii_lowercase()) {
                    return Err(Error::new("invalid_snapshot"));
                }
            }
            if [&p.name, &p.nickname, &p.service_provider]
                .into_iter()
                .any(|x| x.as_ref().is_some_and(|s| s.len() > 4096))
            {
                return Err(Error::new("invalid_snapshot"));
            }
        }
        Ok(())
    }
    pub fn inventory(&self) -> BTreeSet<(String, String, String)> {
        self.profiles
            .iter()
            .map(|p| {
                (
                    p.iccid.clone(),
                    p.isdp_aid.clone().unwrap_or_default().to_ascii_lowercase(),
                    p.state.clone(),
                )
            })
            .collect()
    }
    pub fn matches(&self, other: &Self) -> bool {
        self.eid == other.eid && self.inventory() == other.inventory()
    }
    pub fn target(&self, iccid: &str) -> Result<&Profile> {
        self.profiles
            .iter()
            .find(|p| p.iccid == iccid)
            .ok_or(Error::new("profile_not_found"))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Operation {
    List,
    Download,
    Enable,
    Delete,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub protocol: u8,
    pub operation: Operation,
    pub expected_snapshot: Option<Snapshot>,
    pub activation_code: Option<String>,
    pub confirmation_code: Option<String>,
    pub iccid: Option<String>,
    pub confirm_delete: Option<bool>,
}

pub fn domain(host: &str) -> bool {
    if host.is_empty()
        || host.len() > 253
        || !host.is_ascii()
        || host.parse::<std::net::IpAddr>().is_ok()
    {
        return false;
    }
    let labels: Vec<_> = host.split('.').collect();
    labels.len() >= 2
        && labels.iter().all(|s| {
            !s.is_empty()
                && s.len() <= 63
                && !s.starts_with('-')
                && !s.ends_with('-')
                && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
        && labels
            .last()
            .is_some_and(|s| s.bytes().any(|b| b.is_ascii_alphabetic()))
}

impl Request {
    pub fn validate(&self) -> Result<()> {
        if self.protocol != 1 {
            return Err(Error::new("unsupported_protocol"));
        }
        if self.operation == Operation::List {
            if self.expected_snapshot.is_some()
                || self.activation_code.is_some()
                || self.confirmation_code.is_some()
                || self.iccid.is_some()
                || self.confirm_delete.is_some()
            {
                return Err(Error::new("invalid_request"));
            }
            return Ok(());
        }
        self.expected_snapshot
            .as_ref()
            .ok_or(Error::new("snapshot_required"))?
            .validate()?;
        match self.operation {
            Operation::Download => {
                let code = self
                    .activation_code
                    .as_ref()
                    .ok_or(Error::new("invalid_activation_code"))?;
                let fields: Vec<_> = code.split('$').collect();
                if code.len() > 512
                    || !code.is_ascii()
                    || code
                        .bytes()
                        .any(|b| b.is_ascii_whitespace() || b.is_ascii_control())
                    || fields.len() < 3
                    || fields[0] != "LPA:1"
                    || !domain(fields[1])
                    || fields[2].is_empty()
                    || self.iccid.is_some()
                    || self.confirm_delete.is_some()
                {
                    return Err(Error::new("invalid_activation_code"));
                }
                if self.confirmation_code.as_ref().is_some_and(|s| {
                    s.is_empty()
                        || s.len() > 512
                        || s.starts_with('-')
                        || s.chars().any(|c| c.is_whitespace() || c.is_control())
                }) {
                    return Err(Error::new("invalid_confirmation_code"));
                }
            }
            Operation::Enable | Operation::Delete => {
                if !self.iccid.as_ref().is_some_and(|s| decimal(s, 18, 20))
                    || self.activation_code.is_some()
                    || self.confirmation_code.is_some()
                {
                    return Err(Error::new("invalid_request"));
                }
                if self.operation == Operation::Delete && self.confirm_delete != Some(true) {
                    return Err(Error::new("delete_confirmation_required"));
                }
                if self.operation == Operation::Enable && self.confirm_delete.is_some() {
                    return Err(Error::new("invalid_request"));
                }
            }
            Operation::List => unreachable!(),
        }
        Ok(())
    }
    pub fn arguments(&self, before: &Snapshot) -> Result<Vec<String>> {
        match self.operation {
            Operation::Download => {
                let mut a = vec![
                    "profile".into(),
                    "download".into(),
                    "-a".into(),
                    self.activation_code.clone().unwrap(),
                ];
                if let Some(code) = &self.confirmation_code {
                    a.extend(["-c".into(), code.clone()]);
                }
                Ok(a)
            }
            Operation::Enable | Operation::Delete => {
                let p = before.target(self.iccid.as_deref().unwrap_or_default())?;
                if self.operation == Operation::Delete && p.state != "disabled" {
                    return Err(Error::new("profile_not_disabled"));
                }
                let id = p
                    .isdp_aid
                    .as_ref()
                    .filter(|x| x.len() == 32 && hex(x, 16))
                    .unwrap_or(&p.iccid)
                    .clone();
                let mut a = vec![
                    "profile".into(),
                    if self.operation == Operation::Enable {
                        "enable"
                    } else {
                        "delete"
                    }
                    .into(),
                    id,
                ];
                if self.operation == Operation::Enable {
                    // The gated physical-eUICC path requests no card REFRESH.
                    // perform() owns the later radio cycle, after confirmed
                    // bridge cleanup and the profile-state postcondition.
                    a.push("0".into());
                }
                Ok(a)
            }
            Operation::List => Err(Error::new("invalid_request")),
        }
    }
    pub fn postcondition(&self, before: &Snapshot, after: &Snapshot) -> bool {
        if before.eid != after.eid {
            return false;
        }
        let b = before.inventory();
        let a = after.inventory();
        match self.operation {
            Operation::Download => {
                let added: Vec<_> = a.difference(&b).collect();
                b.is_subset(&a)
                    && added.len() == 1
                    && added[0].2 == "disabled"
                    && !before.profiles.iter().any(|p| p.iccid == added[0].0)
            }
            Operation::Enable => {
                let target = self.iccid.as_deref().unwrap_or_default();
                let identifiers = |s: &Snapshot| {
                    s.inventory()
                        .into_iter()
                        .map(|(i, a, _)| (i, a))
                        .collect::<BTreeSet<_>>()
                };
                identifiers(before) == identifiers(after)
                    && after.target(target).is_ok_and(|p| p.state == "enabled")
                    && after
                        .profiles
                        .iter()
                        .filter(|p| p.iccid != target)
                        .all(|p| p.state == "disabled")
            }
            Operation::Delete => {
                let target = self.iccid.as_deref().unwrap_or_default();
                let expected = b
                    .into_iter()
                    .filter(|(i, _, _)| i != target)
                    .collect::<BTreeSet<_>>();
                a == expected && after.target(target).is_err()
            }
            Operation::List => before.matches(after),
        }
    }
}

pub fn sequence_numbers(result: &Value) -> Result<BTreeSet<u32>> {
    let rows = result
        .get("data")
        .and_then(Value::as_array)
        .ok_or(Error::new("invalid_notifications"))?;
    let mut numbers = BTreeSet::new();
    for row in rows {
        let n = row
            .get("seqNumber")
            .and_then(Value::as_u64)
            .filter(|n| *n <= u32::MAX as u64)
            .ok_or(Error::new("invalid_notifications"))? as u32;
        if !numbers.insert(n) {
            return Err(Error::new("invalid_notifications"));
        }
    }
    Ok(numbers)
}

pub fn notification_arguments(
    previous: &BTreeSet<u32>,
    fresh: &BTreeSet<u32>,
) -> Option<Vec<String>> {
    if fresh.contains(&0) && previous.is_empty() {
        Some(
            ["notification", "process", "-a", "-r"]
                .map(str::to_owned)
                .to_vec(),
        )
    } else {
        let ids: Vec<_> = fresh
            .iter()
            .filter(|n| **n != 0)
            .map(u32::to_string)
            .collect();
        if ids.is_empty() {
            None
        } else {
            let mut a = ["notification", "process", "-r"]
                .map(str::to_owned)
                .to_vec();
            a.extend(ids);
            Some(a)
        }
    }
}

pub fn validate_http_payload(v: &Value) -> Result<()> {
    let url = v
        .get("url")
        .and_then(Value::as_str)
        .ok_or(Error::new("invalid_http_request"))?;
    if url.len() > 8192
        || !url.is_ascii()
        || url
            .bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
        || url.contains(['#', '\\'])
    {
        return Err(Error::new("invalid_http_request"));
    }
    let rest = url
        .strip_prefix("https://")
        .ok_or(Error::new("invalid_http_request"))?;
    let authority = rest.split(['/', '?']).next().unwrap_or_default();
    let host = authority.strip_suffix(":443").unwrap_or(authority);
    if !domain(host) {
        return Err(Error::new("invalid_http_request"));
    }
    let tx = v
        .get("tx")
        .and_then(Value::as_str)
        .ok_or(Error::new("invalid_http_request"))?;
    if !hex(tx, MAX_BODY) {
        return Err(Error::new("invalid_http_request"));
    }
    let headers = v
        .get("headers")
        .and_then(Value::as_array)
        .ok_or(Error::new("invalid_http_request"))?;
    if headers.len() > 16 {
        return Err(Error::new("invalid_http_request"));
    }
    let mut names = BTreeSet::new();
    for header in headers {
        let s = header.as_str().ok_or(Error::new("invalid_http_request"))?;
        if s.len() > 8192 || s.contains(['\r', '\n']) || s.chars().any(|c| c.is_control()) {
            return Err(Error::new("invalid_http_request"));
        }
        let (name, _) = s
            .split_once(':')
            .ok_or(Error::new("invalid_http_request"))?;
        let name = name.to_ascii_lowercase();
        if !matches!(
            name.as_str(),
            "content-type" | "user-agent" | "x-admin-protocol"
        ) || !names.insert(name)
        {
            return Err(Error::new("invalid_http_request"));
        }
    }
    Ok(())
}
