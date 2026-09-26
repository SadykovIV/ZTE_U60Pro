use crate::profile::Result;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum PasswordMode {
    Main,
    Custom,
    Preserve,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub ssid: String,
    pub password_mode: PasswordMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            ssid: "ZTE-VPN".into(),
            password_mode: PasswordMode::Main,
            password: None,
        }
    }
}

impl Settings {
    pub fn validate(&self, configured: bool) -> Result<()> {
        if self.ssid.is_empty()
            || self.ssid.len() > 32
            || self.ssid.trim().is_empty()
            || self.ssid.chars().any(char::is_control)
        {
            return Err("VPN_INVALID_WIFI_SSID");
        }
        match self.password_mode {
            PasswordMode::Main => {
                if self.password.is_some() {
                    return Err("VPN_INVALID_WIFI_PASSWORD");
                }
            }
            PasswordMode::Preserve => {
                if !configured {
                    return Err("VPN_WIFI_NOT_CONFIGURED");
                }
                if self.password.is_some() {
                    return Err("VPN_INVALID_WIFI_PASSWORD");
                }
            }
            PasswordMode::Custom => {
                let p = self
                    .password
                    .as_deref()
                    .ok_or("VPN_INVALID_WIFI_PASSWORD")?;
                if !(((8..=63).contains(&p.len()) && p.bytes().all(|b| (32..=126).contains(&b)))
                    || (p.len() == 64 && p.bytes().all(|b| b.is_ascii_hexdigit())))
                {
                    return Err("VPN_INVALID_WIFI_PASSWORD");
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn new_defaults_are_generic_and_use_main_password() {
        let s = Settings::default();
        assert_eq!(s.ssid, "ZTE-VPN");
        assert_eq!(s.password_mode, PasswordMode::Main);
        assert!(s.password.is_none());
        assert!(s.validate(false).is_ok());
    }
    #[test]
    fn ssid_uses_octet_limit_and_rejects_controls_without_shell_rules() {
        for good in [
            "ZTE-VPN",
            "Моя сеть",
            "$(no shell); 'quoted'",
            "12345678901234567890123456789012",
        ] {
            assert!(Settings {
                ssid: good.into(),
                ..Settings::default()
            }
            .validate(false)
            .is_ok());
        }
        for bad in [
            "",
            "   ",
            "bad\nname",
            "bad\0name",
            "123456789012345678901234567890123",
            "абвгдежзийклмнопр",
        ] {
            assert_eq!(
                Settings {
                    ssid: bad.into(),
                    ..Settings::default()
                }
                .validate(false),
                Err("VPN_INVALID_WIFI_SSID")
            );
        }
    }
    #[test]
    fn password_modes_are_explicit_and_preserve_requires_existing_network() {
        let mut s = Settings::default();
        s.password_mode = PasswordMode::Preserve;
        assert_eq!(s.validate(false), Err("VPN_WIFI_NOT_CONFIGURED"));
        assert!(s.validate(true).is_ok());
        s.password = Some("dont-log-secret".into());
        assert_eq!(s.validate(true), Err("VPN_INVALID_WIFI_PASSWORD"));
        s.password_mode = PasswordMode::Main;
        assert_eq!(s.validate(true), Err("VPN_INVALID_WIFI_PASSWORD"));
    }
    #[test]
    fn custom_password_is_bounded_and_not_interpolated() {
        for good in [
            "eight123".into(),
            "$(quotes)'; spaces".into(),
            "A".repeat(63),
            "a".repeat(64),
        ] {
            let s = Settings {
                ssid: "ZTE-VPN".into(),
                password_mode: PasswordMode::Custom,
                password: Some(good),
            };
            assert!(s.validate(false).is_ok());
        }
        for bad in [
            None,
            Some("short".into()),
            Some("bad\nline123".into()),
            Some("я".repeat(8)),
            Some("x".repeat(64)),
            Some("a".repeat(65)),
        ] {
            let s = Settings {
                ssid: "ZTE-VPN".into(),
                password_mode: PasswordMode::Custom,
                password: bad,
            };
            assert_eq!(s.validate(false), Err("VPN_INVALID_WIFI_PASSWORD"));
        }
    }
}
