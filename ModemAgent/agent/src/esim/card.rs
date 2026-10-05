//! Card capability evidence from the existing operation, never a new probe.
//!
//! A validated EID and profile inventory, including an empty inventory, prove
//! accessible eUICC management only after the caller has completed cleanup.
//! Only an explicit SELECT 6A82 on an owned channel, ready SIM and confirmed
//! Close produce ordinary_sim/unavailable. QMI errors never identify card type.

use super::Error;
use serde::Serialize;

#[derive(Serialize)]
pub(super) struct Status {
    kind: &'static str,
    management: &'static str,
    reason: &'static str,
    cleanup_confirmed: bool,
}

impl Status {
    /// Called only for a validated final snapshot after operation cleanup.
    pub(super) fn confirmed() -> Self {
        Self {
            kind: "euicc_confirmed",
            management: "available",
            reason: "eid_and_profiles_read",
            cleanup_confirmed: true,
        }
    }

    pub(super) fn ordinary() -> Self {
        Self {
            kind: "ordinary_sim",
            management: "unavailable",
            reason: "isdr_not_found",
            cleanup_confirmed: true,
        }
    }

    pub(super) fn failed(error: &Error) -> Self {
        let codes = [Some(error.code), error.component_error];
        let has = |wanted: &[&str]| codes.iter().flatten().any(|code| wanted.contains(code));
        let reason = if has(&[
            "card_cleanup_unknown",
            "qmi_open_unknown",
            "channel_open_outcome_unknown",
            "channel_close_failed",
            "lock_ownership_changed",
            "lock_release_failed",
            "lock_retained",
            "snapshot_cleanup_failed",
            "bridge_cleanup_failed",
            "notification_cleanup_failed",
            "resource_cleanup_failed",
            "resource_ownership_changed",
        ]) {
            "cleanup_unknown"
        } else if has(&["esim_busy", "card_busy", "lock_unavailable"]) {
            "busy"
        } else if has(&["card_open_rejected", "qmi_open_rejected"]) {
            "open_rejected"
        } else if has(&["card_not_ready"]) {
            "not_ready"
        } else if has(&["unsupported_device", "unsupported_firmware"]) {
            "unsupported_device"
        } else if has(&[
            "snapshot_failed",
            "snapshot_missing",
            "invalid_snapshot",
            "qmi_connect_error",
            "qmi_transmit_error",
            "short_apdu_response",
            "snapshot_card_status_error",
            "snapshot_response_too_large",
            "snapshot_continuation_limit",
            "eid_parse_error",
            "profiles_parse_error",
            "selection_read_failed",
            "job_deadline_exceeded",
        ]) {
            "read_failed"
        } else {
            "operation_failed"
        };
        Self {
            kind: "unknown",
            management: "unknown",
            reason,
            // Error paths do not carry a separate positive channel-cleanup
            // receipt. False means unconfirmed, not proof of a leaked channel.
            cleanup_confirmed: false,
        }
    }
}
