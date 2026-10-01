//! QMI flight-mode and slot1 power cycle after the APDU bridge has closed.
//! Mode and ICCID are freshly queried, never inferred from no-service.
use super::{Error, Relay, Result};
use std::time::{Duration, Instant};

pub(super) trait Device {
    fn mode(&mut self) -> Result<u8>;
    fn set(&mut self, online: bool) -> Result<()>;
    fn iccid(&mut self) -> Result<String>;
    fn card_ready(&mut self, expected: &str, deadline: Instant) -> Result<bool>;
    fn selection(&mut self) -> Result<()>;
    fn card_power(&mut self, on: bool) -> Result<()>;
    fn pause(&mut self);
}
pub(super) struct B31;
impl Device for B31 {
    fn mode(&mut self) -> Result<u8> {
        super::radio_qmi::mode()
    }
    fn iccid(&mut self) -> Result<String> {
        super::radio_qmi::iccid()
    }
    fn card_ready(&mut self, expected: &str, deadline: Instant) -> Result<bool> {
        super::radio_qmi::card_ready(expected, deadline)
    }
    fn selection(&mut self) -> Result<()> {
        // A profile may already be enabled while the modem retains the old
        // ICCID. Require the exact slot route, not the new ICCID at this point.
        super::radio_qmi::iccid()
            .map(|_| ())
            .map_err(|_| Error::new("card_reset_failed"))
    }
    fn card_power(&mut self, on: bool) -> Result<()> {
        super::radio_qmi::card_power(on)
    }
    fn pause(&mut self) {
        std::thread::sleep(Duration::from_secs(1));
    }
    fn set(&mut self, online: bool) -> Result<()> {
        if super::radio_qmi::set_mode(online)? != (0, 0) {
            return Err(Error::new("radio_set_failed"));
        }
        Ok(())
    }
}
pub fn ready() -> Result<()> {
    if super::radio_qmi::mode()? != 0 {
        return Err(Error::new("radio_not_online"));
    }
    Ok(())
}
fn wait_mode(device: &mut impl Device, desired: u8) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(20);
    for _ in 0..20 {
        if device.mode().is_ok_and(|m| m == desired) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            break;
        }
        device.pause();
    }
    Err(Error::new(if desired == 0 {
        "radio_restore_failed"
    } else {
        "radio_offline_failed"
    }))
}
struct Restore<'a, D: Device> {
    device: &'a mut D,
    needed: bool,
    card_power_needed: bool,
}
impl<D: Device> Restore<'_, D> {
    fn power_on(&mut self) -> Result<()> {
        if !self.card_power_needed {
            return Ok(());
        }
        // Mark before dispatch, just as for radio: never silently send a
        // second power-on after an uncertain reply or from Drop.
        self.card_power_needed = false;
        self.device
            .card_power(true)
            .map_err(|_| Error::new("card_power_restore_failed"))
    }
    fn reset_card(&mut self) -> Result<()> {
        self.device
            .selection()
            .map_err(|_| Error::new("card_reset_failed"))?;
        self.card_power_needed = true;
        let off = self.device.card_power(false);
        // Power-on precedes radio restoration even when PowerOff was rejected
        // or its reply was lost. There is no callback while recovery is owed.
        self.power_on()?;
        off.map_err(|_| Error::new("card_reset_failed"))
    }
    fn online(&mut self) -> Result<()> {
        // Mark before calling: normal failure must not launch a second hidden
        // retry from Drop. The verified status determines restoration.
        self.needed = false;
        let _sent = self.device.set(true);
        // A lost/rejected setter reply does not override a fresh mode0 readback.
        wait_mode(self.device, 0)
    }
}
impl<D: Device> Drop for Restore<'_, D> {
    fn drop(&mut self) {
        let _ = self.power_on();
        if self.needed {
            let _ = self.online();
        }
    }
}
pub fn refresh(expected: &str, relay: &mut dyn Relay) -> Result<()> {
    cycle(&mut B31, expected, relay)
}
fn wait_card_ready(device: &mut impl Device, expected: &str) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    // Each sample sends at most GetSlotStatus + GetCardStatus (30 queries
    // maximum). No APDU, PIN operation, or additional radio/profile mutation.
    for attempt in 0..15 {
        if Instant::now() >= deadline {
            break;
        }
        if device
            .card_ready(expected, deadline)
            .is_ok_and(|ready| ready)
        {
            return Ok(());
        }
        if attempt == 14 || Instant::now() >= deadline {
            break;
        }
        device.pause();
    }
    Err(Error::new("card_not_ready").radio(true))
}
fn cycle(device: &mut impl Device, expected: &str, relay: &mut dyn Relay) -> Result<()> {
    if device.mode()? != 0 {
        return Err(Error::new("radio_not_online"));
    }
    relay.progress("radio_offline")?;
    let mut recovery = Restore {
        device,
        needed: true,
        card_power_needed: false,
    };
    let _sent = recovery.device.set(false);
    // Even when the setter reply is uncertain, wait for the requested state
    // before attempting online; do not race a delayed low-power transition.
    let offline = wait_mode(recovery.device, 1);
    // DMS low-power alone does not make this modem reread the enabled profile.
    // Only reset the SIM after an actual offline readback and exact slot check.
    let card_reset = if offline.is_ok() {
        recovery.reset_card()
    } else {
        Ok(())
    };
    // No pipe/HTTP/user callback runs while recovery is due: even a connected
    // caller that stops reading progress must not hold the modem in flight mode.
    // The online stage confirms the transition after bounded mode verification.
    let online = recovery.online();
    if let Err(error) = card_reset {
        return Err(error.radio(online.is_ok()));
    }
    online.map_err(|e| e.radio(false))?;
    let progress = relay.progress("radio_online");
    offline.map_err(|_| Error::new("radio_offline_failed").radio(true))?;
    progress.map_err(|e| e.radio(true))?;
    relay.progress("reading_modem").map_err(|e| e.radio(true))?;
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut had_value = false;
    for _ in 0..30 {
        match recovery.device.iccid() {
            Ok(value) if value == expected => return wait_card_ready(recovery.device, expected),
            Ok(_) => had_value = true,
            Err(e) if e.code == "modem_slot_mismatch" => return Err(e.radio(true)),
            Err(_) => (),
        }
        if Instant::now() >= deadline {
            break;
        }
        recovery.device.pause();
    }
    Err(Error::new(if had_value {
        "modem_iccid_mismatch"
    } else {
        "modem_readback_failed"
    })
    .radio(true))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    struct Mock {
        modes: VecDeque<Result<u8>>,
        sets: Vec<bool>,
        fail_offline: bool,
        fail_online: bool,
        bad_iccid: bool,
        iccid_values: VecDeque<Result<String>>,
        iccid_calls: usize,
        card_states: VecDeque<Result<bool>>,
        readiness_calls: usize,
        power_sets: Vec<bool>,
        actions: Vec<&'static str>,
        fail_selection: bool,
        fail_power_off: bool,
        fail_power_on: bool,
    }
    impl Device for Mock {
        fn mode(&mut self) -> Result<u8> {
            self.modes.pop_front().unwrap_or(Ok(0))
        }
        fn set(&mut self, online: bool) -> Result<()> {
            self.actions
                .push(if online { "radio_on" } else { "radio_off" });
            self.sets.push(online);
            if (!online && self.fail_offline) || (online && self.fail_online) {
                Err(Error::new("radio_set_failed"))
            } else {
                Ok(())
            }
        }
        fn iccid(&mut self) -> Result<String> {
            self.iccid_calls += 1;
            if let Some(value) = self.iccid_values.pop_front() {
                return value;
            }
            Ok(if self.bad_iccid { "other" } else { "expected" }.into())
        }
        fn pause(&mut self) {}
        fn card_ready(&mut self, expected: &str, _: Instant) -> Result<bool> {
            assert_eq!(expected, "expected");
            self.readiness_calls += 1;
            self.card_states.pop_front().unwrap_or(Ok(true))
        }
        fn selection(&mut self) -> Result<()> {
            self.actions.push("selection");
            if self.fail_selection {
                Err(Error::new("modem_slot_mismatch"))
            } else {
                Ok(())
            }
        }
        fn card_power(&mut self, on: bool) -> Result<()> {
            self.actions.push(if on { "power_on" } else { "power_off" });
            self.power_sets.push(on);
            if (!on && self.fail_power_off) || (on && self.fail_power_on) {
                Err(Error::new("synthetic_power_failure"))
            } else {
                Ok(())
            }
        }
    }
    struct RelayMock {
        fail_online: bool,
    }
    impl Relay for RelayMock {
        fn http(&mut self, _: &serde_json::Value) -> Result<serde_json::Value> {
            unreachable!()
        }
        fn progress(&mut self, s: &'static str) -> Result<()> {
            if s == "radio_online" && self.fail_online {
                Err(Error::new("stream_write_failed"))
            } else {
                Ok(())
            }
        }
    }
    fn mock() -> Mock {
        Mock {
            modes: vec![Ok(0), Ok(1), Ok(0)].into(),
            sets: vec![],
            fail_offline: false,
            fail_online: false,
            bad_iccid: false,
            iccid_values: VecDeque::new(),
            iccid_calls: 0,
            card_states: VecDeque::new(),
            readiness_calls: 0,
            power_sets: vec![],
            actions: vec![],
            fail_selection: false,
            fail_power_off: false,
            fail_power_on: false,
        }
    }
    #[test]
    fn cycle_verifies_two_modes_and_modem_identity() {
        let mut m = mock();
        cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap();
        assert_eq!(m.sets, [false, true]);
        assert_eq!(m.power_sets, [false, true]);
        assert_eq!(
            m.actions,
            [
                "radio_off",
                "selection",
                "power_off",
                "power_on",
                "radio_on"
            ]
        );
    }
    #[test]
    fn failed_offline_and_progress_still_restore_once() {
        let mut m = mock();
        m.fail_offline = true;
        m.modes = vec![Ok(0), Ok(0)].into();
        assert_eq!(
            cycle(&mut m, "expected", &mut RelayMock { fail_online: false })
                .unwrap_err()
                .code,
            "radio_offline_failed"
        );
        assert_eq!(m.sets, [false, true]);
        assert!(m.power_sets.is_empty());
        let mut m = mock();
        assert_eq!(
            cycle(&mut m, "expected", &mut RelayMock { fail_online: true })
                .unwrap_err()
                .code,
            "stream_write_failed"
        );
        assert_eq!(m.sets, [false, true]);
    }
    #[test]
    fn online_failure_has_priority_and_never_retries_profile() {
        let mut m = mock();
        m.modes = vec![Ok(0), Ok(1)].into();
        m.modes.extend((0..20).map(|_| Ok(1)));
        assert_eq!(
            cycle(&mut m, "expected", &mut RelayMock { fail_online: false })
                .unwrap_err()
                .code,
            "radio_restore_failed"
        );
        assert_eq!(m.sets, [false, true]);
    }
    #[test]
    fn stale_modem_iccid_is_not_success() {
        let mut m = mock();
        m.bad_iccid = true;
        assert_eq!(
            cycle(&mut m, "expected", &mut RelayMock { fail_online: false })
                .unwrap_err()
                .code,
            "modem_iccid_mismatch"
        );
        assert_eq!(m.sets, [false, true]);
    }
    #[test]
    fn transient_powerup_state_retries_reads_but_rerouting_stops_without_new_writes() {
        let mut m = mock();
        m.iccid_values = vec![
            Err(Error::new("modem_readback_failed")),
            Err(Error::new("modem_readback_failed")),
            Ok("expected".into()),
        ]
        .into();
        cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap();
        assert_eq!(m.iccid_calls, 3);
        assert_eq!(m.sets, [false, true]);
        assert_eq!(m.power_sets, [false, true]);
        let mut m = mock();
        m.iccid_values = vec![
            Err(Error::new("modem_slot_mismatch")),
            Ok("expected".into()),
        ]
        .into();
        let error = cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap_err();
        assert_eq!(error.code, "modem_slot_mismatch");
        assert_eq!(error.radio_restored, Some(true));
        assert_eq!(m.iccid_calls, 1);
        assert_eq!(m.sets, [false, true]);
        assert_eq!(m.power_sets, [false, true]);
    }
    #[test]
    fn actual_mode_readback_wins_over_uncertain_setter_reply() {
        let mut m = mock();
        m.fail_offline = true;
        m.fail_online = true;
        cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap();
        assert_eq!(m.sets, [false, true]);
    }
    #[test]
    fn online_and_matching_iccid_wait_for_application_ready() {
        let mut m = mock();
        m.card_states = vec![Ok(false), Err(Error::new("card_not_ready")), Ok(true)].into();
        cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap();
        assert_eq!(m.readiness_calls, 3);
        assert_eq!(m.sets, [false, true]);
    }
    #[test]
    fn readiness_timeout_keeps_radio_online_without_extra_writes() {
        let mut m = mock();
        m.card_states = (0..15).map(|_| Ok(false)).collect();
        let error = cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap_err();
        assert_eq!(error.code, "card_not_ready");
        assert_eq!(error.radio_restored, Some(true));
        assert_eq!(error.modem_verified, Some(false));
        assert_eq!(m.readiness_calls, 15);
        assert_eq!(m.sets, [false, true]);
        assert_eq!(m.power_sets, [false, true]);
    }
    #[test]
    fn slot_guard_failure_restores_radio_without_powering_any_card() {
        let mut m = mock();
        m.fail_selection = true;
        let error = cycle(&mut m, "expected", &mut RelayMock { fail_online: false }).unwrap_err();
        assert_eq!(error.code, "card_reset_failed");
        assert_eq!(error.radio_restored, Some(true));
        assert_eq!(m.actions, ["radio_off", "selection", "radio_on"]);
        assert!(m.power_sets.is_empty());
        assert_eq!(m.readiness_calls, 0);
    }
    #[test]
    fn every_power_failure_attempts_on_then_radio_exactly_once() {
        for fail_off in [false, true] {
            for fail_on in [false, true] {
                if !fail_off && !fail_on {
                    continue;
                }
                for fail_radio_readback in [false, true] {
                    let mut m = mock();
                    m.fail_power_off = fail_off;
                    m.fail_power_on = fail_on;
                    if fail_radio_readback {
                        m.modes = vec![Ok(0), Ok(1)].into();
                        m.modes.extend((0..20).map(|_| Ok(1)));
                    }
                    let error = cycle(&mut m, "expected", &mut RelayMock { fail_online: false })
                        .unwrap_err();
                    assert_eq!(
                        error.code,
                        if fail_on {
                            "card_power_restore_failed"
                        } else {
                            "card_reset_failed"
                        }
                    );
                    assert_eq!(error.radio_restored, Some(!fail_radio_readback));
                    assert_eq!(error.modem_verified, Some(false));
                    assert_eq!(
                        m.actions,
                        [
                            "radio_off",
                            "selection",
                            "power_off",
                            "power_on",
                            "radio_on"
                        ]
                    );
                    assert_eq!(m.sets, [false, true]);
                    assert_eq!(m.power_sets, [false, true]);
                    assert_eq!(m.readiness_calls, 0);
                }
            }
        }
    }
    #[test]
    fn drop_restores_power_before_radio_without_retrying_a_failed_power_on() {
        for explicit_attempt in [false, true] {
            let mut m = mock();
            m.fail_power_on = explicit_attempt;
            {
                let mut recovery = Restore {
                    device: &mut m,
                    needed: true,
                    card_power_needed: true,
                };
                if explicit_attempt {
                    assert!(recovery.power_on().is_err());
                }
            }
            assert_eq!(m.actions, ["power_on", "radio_on"]);
            assert_eq!(m.power_sets, [true]);
            assert_eq!(m.sets, [true]);
        }
    }
}
