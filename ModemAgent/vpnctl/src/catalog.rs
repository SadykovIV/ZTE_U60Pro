//! A complete profile/subscription update is committed by one private-file rename.
use crate::{profile, profile::Result, subscription};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Catalog {
    pub schema_version: u32,
    pub profiles: Vec<Value>,
    pub subscriptions: Vec<Value>,
}
impl Catalog {
    pub fn legacy(profiles: Vec<Value>) -> Self {
        Self { schema_version: 2, profiles, subscriptions: vec![] }
    }
    pub fn check(&self) -> Result<()> {
        if self.schema_version != 2 || self.profiles.len() > subscription::PROFILE_LIMIT { return Err("VPN_INVALID_STATE"); }
        let mut ids = BTreeSet::new();
        for p in &self.profiles {
            if !p["id"].as_str().is_some_and(profile::valid_id) || !ids.insert(p["id"].as_str())
                || !p["proxy"].is_object() || profile::name(p["name"].as_str().unwrap_or("")).is_err() {
                return Err("VPN_INVALID_STATE");
            }
        }
        ids.clear();
        for s in &self.subscriptions {
            if !s["id"].as_str().is_some_and(profile::valid_id) || !ids.insert(s["id"].as_str())
                || subscription::host(s["url"].as_str().unwrap_or("")).is_err() {
                return Err("VPN_INVALID_STATE");
            }
        }
        Ok(())
    }
    pub fn profile(&self, id: &str) -> Result<&Value> {
        if !profile::valid_id(id) { return Err("VPN_INVALID_PROFILE_ID"); }
        self.profiles.iter().find(|p| p["id"] == id).ok_or("VPN_PROFILE_NOT_FOUND")
    }
    pub fn subscription(&self, id: &str) -> Result<&Value> {
        if !profile::valid_id(id) { return Err("VPN_SUBSCRIPTION_NOT_FOUND"); }
        self.subscriptions.iter().find(|s| s["id"] == id).ok_or("VPN_SUBSCRIPTION_NOT_FOUND")
    }
    pub fn detach(&mut self, id: &str) -> Result<()> {
        self.subscription(id)?;
        self.subscriptions.retain(|s| s["id"] != id);
        for p in &mut self.profiles {
            if p["subscription_id"] == id {
                for field in ["subscription_id", "source_key", "removed_from_subscription"] { p.as_object_mut().unwrap().remove(field); }
            }
        }
        Ok(())
    }
    pub fn update(&mut self, subscription: Value, parsed: subscription::Parsed, active: &str,
        mut new_id: impl FnMut() -> Result<String>) -> Result<Value> {
        let sid = subscription["id"].as_str().ok_or("VPN_INVALID_STATE")?;
        let mut remaining: Vec<Value> = self.profiles.iter().filter(|p| p["subscription_id"] == sid).cloned().collect();
        let mut profiles: Vec<Value> = self.profiles.iter().filter(|p| p["subscription_id"] != sid).cloned().collect();
        let (mut added, mut updated, mut removed, mut retained_active) = (0, 0, 0, 0);
        let mut occurrences = BTreeMap::new();
        for mut p in parsed.profiles {
            let label = format!("{}\n{}", p["protocol"].as_str().unwrap_or("vless"), p["name"].as_str().unwrap_or(""));
            let occurrence = occurrences.entry(label.clone()).or_insert(0usize);
            *occurrence += 1;
            let key = crate::hash(format!("{label}\n{occurrence}").as_bytes());
            let matched = remaining.iter().position(|old| old["proxy"] == p["proxy"])
                .or_else(|| remaining.iter().position(|old| old["source_key"] == key));
            let id = if let Some(index) = matched {
                let old = remaining.remove(index);
                if old["proxy"] != p["proxy"] || old["name"] != p["name"] { updated += 1; }
                if old["custom_name"] == true { p["name"] = old["name"].clone(); p["custom_name"] = json!(true); }
                old["id"].as_str().ok_or("VPN_INVALID_STATE")?.to_owned()
            } else { added += 1; new_id()? };
            p["id"] = json!(id); p["subscription_id"] = json!(sid); p["source_key"] = json!(key);
            p.as_object_mut().unwrap().remove("source_index");
            profiles.push(p);
        }
        // A partially understood feed must not silently erase its previous nodes.
        for mut old in remaining {
            if old["id"] == active || !parsed.skipped.is_empty() {
                if old["id"] == active { retained_active += 1; }
                old["removed_from_subscription"] = json!(true);
                profiles.push(old);
            } else { removed += 1; }
        }
        if profiles.len() > subscription::PROFILE_LIMIT { return Err("VPN_PROFILE_LIMIT"); }
        self.profiles = profiles;
        self.subscriptions.retain(|s| s["id"] != sid);
        self.subscriptions.push(subscription);
        Ok(json!({"added":added,"updated":updated,"removed":removed,"duplicates":parsed.duplicates,"retained_active":retained_active,"skipped":parsed.skipped}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SID: &str = "10000000-0000-0000-0000-000000000000";
    fn sub() -> Value { json!({"id":SID,"name":"Test","host":"example.org","url":"https://example.org/private"}) }
    fn parsed(server: &str) -> subscription::Parsed {
        subscription::Parsed { profiles:vec![json!({"name":"Node","protocol":"hysteria2","proxy":{"name":"VPN","type":"hysteria2","server":server},"warnings":[]})],skipped:vec![],duplicates:0 }
    }
    #[test] fn refresh_preserves_identity_custom_name_and_active_removed_node() {
        let mut catalog = Catalog::legacy(vec![]);
        let id = "20000000-0000-0000-0000-000000000000";
        catalog.update(sub(), parsed("one.example"), "", || Ok(id.into())).unwrap();
        catalog.profiles[0]["name"] = json!("Personal name");
        catalog.profiles[0]["custom_name"] = json!(true);
        let summary = catalog.update(sub(), parsed("two.example"), id, || panic!("stable node id")).unwrap();
        assert_eq!(summary["updated"], 1);
        assert_eq!(catalog.profiles[0]["id"], id);
        assert_eq!(catalog.profiles[0]["name"], "Personal name");
        let mut next = parsed("three.example"); next.profiles[0]["name"] = json!("New node");
        let summary = catalog.update(sub(), next, id, || Ok("30000000-0000-0000-0000-000000000000".into())).unwrap();
        assert_eq!(summary["retained_active"], 1);
        assert_eq!(catalog.profiles.len(), 2);
        catalog.detach(SID).unwrap();
        assert!(catalog.subscriptions.is_empty());
        assert_eq!(catalog.profiles.len(), 2);
        assert!(catalog.profiles.iter().all(|p| p.get("subscription_id").is_none()));
        catalog.check().unwrap();
    }
    #[test] fn malformed_feed_cannot_partially_erase_existing_nodes() {
        let mut catalog = Catalog::legacy(vec![]);
        catalog.update(sub(), parsed("one.example"), "", || Ok("20000000-0000-0000-0000-000000000000".into())).unwrap();
        let mut next = parsed("two.example"); next.profiles[0]["name"] = json!("Another");
        next.skipped.push(json!({"index":2,"code":"VPN_UNSUPPORTED_PROTOCOL"}));
        let summary = catalog.update(sub(), next, "", || Ok("30000000-0000-0000-0000-000000000000".into())).unwrap();
        assert_eq!(summary["removed"], 0); assert_eq!(catalog.profiles.len(), 2);
    }
}
