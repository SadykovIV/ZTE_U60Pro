//! Explicit card route selected by the caller; never inferred from network selection.
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    Removable,
    Internal,
}

impl Target {
    pub fn parse(value: &Value) -> Option<Self> {
        match value.as_str()? {
            "removable-euicc-slot1" => Some(Self::Removable),
            "internal-euicc-slot2" => Some(Self::Internal),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Removable => "removable-euicc-slot1",
            Self::Internal => "internal-euicc-slot2",
        }
    }

    pub fn physical_slot(self) -> u8 {
        match self {
            Self::Removable => 1,
            Self::Internal => 2,
        }
    }

    pub fn logical_slot(self) -> u8 {
        self.physical_slot()
    }
}
