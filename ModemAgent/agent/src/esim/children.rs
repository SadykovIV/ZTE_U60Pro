//! Pinned local children; EOF and wait are mandatory. Never signal the QMI bridge.
use super::{Error, Result, MAX_LINE};
use serde_json::Value;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::thread::JoinHandle;

const MAX_DIAGNOSTIC_LINE: usize = 1024;

/// Only fixed helper-owned codes survive this parser. Dependency text and
/// private stdout are never diagnostics, and raw stderr is never retained.
#[derive(Default, Debug)]
struct HelperDiagnostics {
    first_error: Option<&'static str>,
    cleanup_unknown: bool,
    lock_retained: bool,
    read_failed: bool,
}

impl HelperDiagnostics {
    fn remember(&mut self, code: &'static str) {
        if self.first_error.is_none() {
            self.first_error = Some(code);
        }
    }

    fn line(&mut self, bytes: &[u8]) {
        let Ok(value) = serde_json::from_slice::<Value>(bytes) else {
            return;
        };
        match value.get("event").and_then(Value::as_str) {
            Some("qmi_open_result") => match value.get("outcome").and_then(Value::as_str) {
                Some("rejected") => self.remember("qmi_open_rejected"),
                Some("unknown") => {
                    self.cleanup_unknown = true;
                    self.remember("qmi_open_unknown");
                }
                _ => (),
            },
            Some("cleanup_unknown") if value["stage"] == "channel_open" => {
                self.cleanup_unknown = true;
                self.remember("channel_open_outcome_unknown");
            }
            Some("cleanup_failed") if value["stage"] == "channel_close" => {
                self.cleanup_unknown = true;
                self.remember("channel_close_failed");
            }
            Some("lock_retained") if value["reason"] == "channel_cleanup_unknown" => {
                self.lock_retained = true;
                self.remember("lock_retained");
            }
            Some("error" | "operation_failed") => {
                if let Some(code) = value
                    .get("code")
                    .and_then(Value::as_str)
                    .and_then(known_helper_code)
                {
                    if matches!(
                        code,
                        "qmi_open_unknown"
                            | "channel_open_outcome_unknown"
                            | "channel_close_failed"
                            | "card_cleanup_unknown"
                            | "lock_ownership_changed"
                            | "lock_release_failed"
                    ) {
                        self.cleanup_unknown = true;
                    }
                    if code == "lock_retained" {
                        self.lock_retained = true;
                    }
                    self.remember(code);
                }
            }
            _ => (),
        }
    }

    fn failure(&self, fallback: &'static str) -> Option<Error> {
        // Later cleanup uncertainty wins over an earlier ordinary failure.
        if self.cleanup_unknown || self.lock_retained {
            return Some(Error::new("card_cleanup_unknown").component(self.first_error));
        }
        if self.read_failed {
            return Some(Error::new(fallback).component(self.first_error));
        }
        self.first_error.map(|code| {
            Error::new(match code {
                "lock_unavailable" => "card_busy",
                "qmi_open_rejected" => "card_open_rejected",
                "card_not_euicc" => "card_not_euicc",
                "card_not_ready" => "card_not_ready",
                _ => fallback,
            })
            .component(self.first_error)
        })
    }
}

fn known_helper_code(code: &str) -> Option<&'static str> {
    // Do not return a borrowed/owned copy of any child-provided string.
    const CODES: &[&str] = &[
        "lock_unavailable",
        "lock_random_failed",
        "lock_owner_failed",
        "lock_metadata_failed",
        "lock_release_failed",
        "lock_ownership_changed",
        "lock_retained",
        "selection_read_failed",
        "selection_mismatch",
        "qmi_connect_error",
        "qmi_open_rejected",
        "qmi_open_unknown",
        "channel_open_outcome_unknown",
        "channel_close_failed",
        "card_cleanup_unknown",
        "card_not_ready",
        "card_not_euicc",
        "unsupported_channel",
        "qmi_transmit_error",
        "short_apdu_response",
        "snapshot_response_too_large",
        "snapshot_continuation_limit",
        "snapshot_card_status_error",
        "eid_command_error",
        "eid_parse_error",
        "eid_mismatch",
        "profiles_command_error",
        "profiles_parse_error",
        "stdout_error",
        "stdin_error",
        "unterminated_json_line",
        "input_line_too_large",
        "invalid_json_line",
        "invalid_header",
        "invalid_expected_eid",
        "missing_header",
        "invalid_arguments",
        "bridge_operation_failed",
        "already_connected",
        "already_open",
        "session_failed",
        "not_connected",
        "not_open",
        "missing_owned_connection",
        "empty_read_command",
        "invalid_envelope",
        "invalid_function",
        "invalid_aid",
        "aid_not_allowed",
        "invalid_apdu",
        "invalid_hex",
        "unsupported_function",
    ];
    CODES.iter().copied().find(|known| *known == code)
}

fn drain_stderr(input: &mut impl Read, helper: bool) -> HelperDiagnostics {
    let mut diagnostics = HelperDiagnostics::default();
    let mut buffer = [0u8; 8192];
    let mut line = Vec::with_capacity(MAX_DIAGNOSTIC_LINE);
    let mut discard = false;
    loop {
        match input.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                if !helper {
                    continue;
                }
                for &byte in &buffer[..n] {
                    if byte == b'\n' {
                        if !discard {
                            diagnostics.line(&line);
                        }
                        line.clear();
                        discard = false;
                    } else if !discard {
                        if line.len() == MAX_DIAGNOSTIC_LINE {
                            line.clear();
                            discard = true;
                        } else {
                            line.push(byte);
                        }
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => {
                diagnostics.read_failed = true;
                break;
            }
        }
    }
    // An unterminated trailing fragment is not an authenticated helper event.
    diagnostics
}

pub fn read_json(input: &mut impl BufRead) -> Result<Option<Value>> {
    let mut bytes = Vec::new();
    loop {
        let buffer = input
            .fill_buf()
            .map_err(|_| Error::new("stream_read_failed"))?;
        if buffer.is_empty() {
            return if bytes.is_empty() {
                Ok(None)
            } else {
                Err(Error::new("unterminated_message"))
            };
        }
        let size = buffer
            .iter()
            .position(|b| *b == b'\n')
            .map(|i| i + 1)
            .unwrap_or(buffer.len());
        if bytes.len().saturating_add(size) > MAX_LINE {
            return Err(Error::new("message_too_large"));
        }
        let complete = buffer[size - 1] == b'\n';
        bytes.extend_from_slice(&buffer[..size]);
        input.consume(size);
        if complete {
            return serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|_| Error::new("invalid_json"));
        }
    }
}

pub fn emit(output: &mut impl Write, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| Error::new("invalid_output"))?;
    if bytes.len() + 1 > MAX_LINE {
        return Err(Error::new("message_too_large"));
    }
    output
        .write_all(&bytes)
        .and_then(|_| output.write_all(b"\n"))
        .and_then(|_| output.flush())
        .map_err(|_| Error::new("stream_write_failed"))
}

pub struct ChildPipe {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
    stderr: Option<JoinHandle<HelperDiagnostics>>,
    diagnostics: HelperDiagnostics,
    finished: bool,
}

impl ChildPipe {
    pub fn spawn(path: &Path, args: &[String], lpac: bool) -> Result<Self> {
        let mut cmd = Command::new(path);
        cmd.args(args)
            .env_clear()
            .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if lpac {
            cmd.env("LPAC_APDU", "stdio").env("LPAC_HTTP", "stdio");
        }
        let mut child = cmd
            .spawn()
            .map_err(|_| Error::new("component_start_failed"))?;
        let input = child.stdin.take();
        let output = BufReader::new(child.stdout.take().expect("piped stdout"));
        let mut stderr = child.stderr.take().expect("piped stderr");
        let drain = std::thread::spawn(move || drain_stderr(&mut stderr, !lpac));
        Ok(Self {
            child,
            input,
            output,
            stderr: Some(drain),
            diagnostics: HelperDiagnostics::default(),
            finished: false,
        })
    }
    pub fn send(&mut self, message: &Value) -> Result<()> {
        emit(
            self.input.as_mut().ok_or(Error::new("component_closed"))?,
            message,
        )
    }
    pub fn read(&mut self) -> Result<Option<Value>> {
        read_json(&mut self.output)
    }
    pub fn exchange(&mut self, message: &Value) -> Result<Value> {
        self.send(message)?;
        self.read()?.ok_or(Error::new("component_eof"))
    }
    pub fn finish(&mut self) -> Result<()> {
        if self.finished {
            return Err(Error::new("component_already_closed"));
        }
        self.input.take(); // EOF allows a bridge-owned channel to close normally.
        let mut buffer = [0u8; 8192];
        let mut read_ok = true;
        loop {
            match self.output.read(&mut buffer) {
                Ok(0) => break,
                Ok(_) => (),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    read_ok = false;
                    break;
                }
            }
        }
        let status = self.child.wait();
        self.finished = true;
        let drain_ok = match self.stderr.take().map(|t| t.join()) {
            Some(Ok(diagnostics)) => {
                self.diagnostics = diagnostics;
                !self.diagnostics.read_failed
            }
            Some(Err(_)) => false,
            None => true,
        };
        if read_ok && drain_ok && status.is_ok_and(|s| s.success()) {
            Ok(())
        } else {
            Err(Error::new("component_exit_failed"))
        }
    }
    fn finish_helper(&mut self, fallback: &'static str) -> Result<()> {
        let finished = self.finish();
        if let Some(error) = self.diagnostics.failure(fallback) {
            return Err(error);
        }
        finished.map_err(|_| Error::new(fallback))
    }
}
impl Drop for ChildPipe {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.finish();
        }
    }
}

pub struct LocalRuntime {
    pub helper: PathBuf,
    pub lpac: PathBuf,
    bridge: Option<ChildPipe>,
    deadline: Option<std::time::Instant>,
    trace: Option<super::trace::Trace>,
    bridge_started: Option<std::time::Instant>,
}
impl LocalRuntime {
    pub fn new(helper: PathBuf, lpac: PathBuf) -> Self {
        Self {
            helper,
            lpac,
            bridge: None,
            deadline: None,
            trace: None,
            bridge_started: None,
        }
    }
    pub fn with_deadline(helper: PathBuf, lpac: PathBuf, deadline: std::time::Instant) -> Self {
        Self {
            helper,
            lpac,
            bridge: None,
            deadline: Some(deadline),
            trace: None,
            bridge_started: None,
        }
    }
    pub fn set_trace(&mut self, trace: super::trace::Trace) {
        self.trace = Some(trace);
    }
    fn event(&self, event: super::trace::Event) {
        if let Some(trace) = &self.trace {
            let _ = trace.event(event);
        }
    }
    fn check_deadline(&self) -> Result<()> {
        if self
            .deadline
            .is_some_and(|d| std::time::Instant::now() >= d)
        {
            Err(Error::new("job_deadline_exceeded"))
        } else {
            Ok(())
        }
    }
}

impl super::Runtime for LocalRuntime {
    fn radio_ready(&mut self) -> Result<()> {
        self.check_deadline()?;
        if self.bridge.is_some() {
            return Err(Error::new("bridge_already_open"));
        }
        super::radio::ready()
    }
    fn refresh_modem(&mut self, expected_iccid: &str, relay: &mut dyn super::Relay) -> Result<()> {
        self.check_deadline()?;
        if self.bridge.is_some() {
            return Err(Error::new("bridge_already_open"));
        }
        super::radio::refresh(expected_iccid, relay)
    }
    fn snapshot(&mut self) -> Result<super::model::Snapshot> {
        self.inspect()?.require_euicc()
    }
    fn inspect(&mut self) -> Result<super::model::Inspection> {
        self.check_deadline()?;
        let started = std::time::Instant::now();
        self.event(super::trace::Event::ComponentStart(
            super::trace::Component::Snapshot,
        ));
        let mut child = ChildPipe::spawn(&self.helper, &["snapshot".into()], false)?;
        let result = (|| {
            let value = child.read()?.ok_or(Error::new("snapshot_missing"))?;
            let snapshot = super::model::Inspection::parse(value)?;
            if child.read()?.is_some() {
                return Err(Error::new("unexpected_component_output"));
            }
            Ok(snapshot)
        })();
        let closed = child.finish_helper("snapshot_cleanup_failed");
        self.event(super::trace::Event::ComponentExit(
            super::trace::Component::Snapshot,
            result.is_ok() && closed.is_ok(),
            super::trace::millis(started),
        ));
        closed?;
        result
    }
    fn begin(&mut self, expected: &super::model::Snapshot) -> Result<()> {
        self.check_deadline()?;
        if self.bridge.is_some() {
            return Err(Error::new("bridge_already_open"));
        }
        let started = std::time::Instant::now();
        self.event(super::trace::Event::ComponentStart(
            super::trace::Component::Bridge,
        ));
        let mut child = ChildPipe::spawn(&self.helper, &["bridge".into()], false)?;
        let result = (|| {
            let v = child.exchange(&serde_json::json!({"expected_eid": expected.eid}))?;
            let actual = super::model::Snapshot::parse(v)?;
            if !expected.matches(&actual) {
                return Err(Error::new("snapshot_changed"));
            }
            Ok(())
        })();
        if let Err(error) = result {
            let closed = child.finish_helper("bridge_cleanup_failed");
            self.event(super::trace::Event::ComponentExit(
                super::trace::Component::Bridge,
                false,
                super::trace::millis(started),
            ));
            closed?;
            return Err(error);
        }
        self.bridge = Some(child);
        self.bridge_started = Some(started);
        Ok(())
    }
    fn command(&mut self, arguments: &[String], http: &mut dyn super::Relay) -> Result<Value> {
        self.check_deadline()?;
        let deadline = self.deadline;
        let trace = self.trace.clone();
        let started = std::time::Instant::now();
        self.event(super::trace::Event::ComponentStart(
            super::trace::Component::Lpac,
        ));
        let bridge = self.bridge.as_mut().ok_or(Error::new("bridge_missing"))?;
        let mut child = ChildPipe::spawn(&self.lpac, arguments, true)?;
        let mut final_result = None;
        let result = (|| {
            let mut messages = 0usize;
            while let Some(message) = child.read()? {
                messages += 1;
                if deadline.is_some_and(|d| std::time::Instant::now() >= d) {
                    return Err(Error::new("job_deadline_exceeded"));
                }
                if deadline.is_some() && messages > 16384 {
                    return Err(Error::new("job_message_limit"));
                }
                let reply = match message.get("type").and_then(Value::as_str) {
                    Some("apdu") => {
                        let transmit = message["payload"]["func"] == "transmit";
                        let apdu_started = std::time::Instant::now();
                        if transmit {
                            if let Some(trace) = &trace {
                                trace.event(super::trace::Event::ApduSent)?;
                            }
                        }
                        let response = bridge.exchange(&message);
                        if transmit {
                            if let Some(trace) = &trace {
                                let ok = response
                                    .as_ref()
                                    .is_ok_and(|v| v["payload"]["ecode"].as_i64() == Some(0));
                                let bytes = response
                                    .as_ref()
                                    .ok()
                                    .and_then(|v| v["payload"]["data"].as_str())
                                    .map_or(0, |s| s.len() / 2);
                                let _ = trace.event(super::trace::Event::ApduReply(
                                    ok,
                                    bytes,
                                    super::trace::millis(apdu_started),
                                ));
                            }
                        }
                        let reply = response?;
                        if reply.get("type").and_then(Value::as_str) != Some("apdu")
                            || !reply.get("payload").is_some_and(Value::is_object)
                        {
                            return Err(Error::new("invalid_apdu_reply"));
                        }
                        reply
                    }
                    Some("http") => serde_json::json!({"type":"http", "payload":http.http(
                        message.get("payload").ok_or(Error::new("invalid_http_request"))?)?}),
                    Some("lpa") => {
                        if final_result.is_some() {
                            return Err(Error::new("multiple_lpac_results"));
                        }
                        final_result = message.get("payload").cloned();
                        if !final_result.as_ref().is_some_and(Value::is_object) {
                            return Err(Error::new("invalid_lpac_result"));
                        }
                        continue;
                    }
                    // Dependency progress strings may contain secrets and are discarded.
                    Some("progress") => continue,
                    _ => return Err(Error::new("invalid_lpac_message")),
                };
                child.send(&reply)?;
            }
            let value = final_result
                .take()
                .ok_or(Error::new("lpac_result_missing"))?;
            if value.get("code").and_then(Value::as_i64) != Some(0) {
                return Err(Error::new("lpac_failed"));
            }
            Ok(value)
        })();
        // Even an ordinary parse/HTTP error closes stdin and drains the child.
        // Its final close/disconnect requests may be unread here; bridge EOF
        // at end() remains the owner of actual card cleanup.
        let status = child.finish();
        self.event(super::trace::Event::ComponentExit(
            super::trace::Component::Lpac,
            result.is_ok() && status.is_ok(),
            super::trace::millis(started),
        ));
        result.and_then(|v| {
            status?;
            Ok(v)
        })
    }
    fn end(&mut self) -> Result<()> {
        if let Some(mut child) = self.bridge.take() {
            let started = std::time::Instant::now();
            self.event(super::trace::Event::CleanupStart);
            let result = child.finish_helper("bridge_cleanup_failed");
            self.event(super::trace::Event::CleanupEnd(
                result.is_ok(),
                super::trace::millis(started),
                result.as_ref().err().map(|e| e.code),
            ));
            let duration = self
                .bridge_started
                .take()
                .map(super::trace::millis)
                .unwrap_or(0);
            self.event(super::trace::Event::ComponentExit(
                super::trace::Component::Bridge,
                result.is_ok(),
                duration,
            ));
            result
        } else {
            Ok(())
        }
    }
}

impl Drop for LocalRuntime {
    fn drop(&mut self) {
        if let Some(mut child) = self.bridge.take() {
            let _ = child.finish();
        }
    }
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;
    use crate::esim::Runtime;
    use std::io::Cursor;
    use std::os::unix::fs::PermissionsExt;

    fn diagnostics(bytes: &[u8]) -> HelperDiagnostics {
        drain_stderr(&mut Cursor::new(bytes), true)
    }

    #[test]
    fn raw_unknown_and_private_text_never_become_diagnostics() {
        let text = concat!(
            "SYNTHETIC_PRIVATE_APDU_OR_ACTIVATION\n",
            "{\"event\":\"error\",\"code\":\"SYNTHETIC_PRIVATE_CODE\"}\n",
            "{\"event\":\"unexpected\",\"code\":\"lock_unavailable\"}\n",
            "{\"event\":\"cleanup_unknown\",\"stage\":\"private\"}\n"
        );
        let report = diagnostics(text.as_bytes());
        assert!(report.failure("snapshot_cleanup_failed").is_none());
        assert!(!format!("{report:?}").contains("PRIVATE"));
    }

    #[test]
    fn oversized_line_is_discarded_to_lf_then_next_event_is_parsed() {
        let event = b"{\"event\":\"error\",\"code\":\"qmi_open_rejected\"}\n";
        let mut bytes = vec![b' '; MAX_DIAGNOSTIC_LINE + 16384];
        bytes.extend_from_slice(b"{\"event\":\"error\",\"code\":\"lock_unavailable\"}\n");
        bytes.extend_from_slice(event);
        let mut input = Cursor::new(&bytes);
        let report = drain_stderr(&mut input, true);
        assert_eq!(input.position(), bytes.len() as u64);
        assert_eq!(report.first_error, Some("qmi_open_rejected"));
        assert_eq!(
            report.failure("fallback").unwrap().code,
            "card_open_rejected"
        );
    }

    #[test]
    fn unterminated_fragment_and_lpac_stderr_are_never_interpreted() {
        let bytes = b"{\"event\":\"error\",\"code\":\"lock_unavailable\"}";
        assert!(diagnostics(bytes).first_error.is_none());
        let mut complete = bytes.to_vec();
        complete.push(b'\n');
        let report = drain_stderr(&mut Cursor::new(complete), false);
        assert!(report.first_error.is_none());
    }

    #[test]
    fn interrupted_and_fragmented_reads_resume_draining() {
        struct Interrupted {
            input: Cursor<Vec<u8>>,
            interrupt: bool,
        }
        impl Read for Interrupted {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                if self.interrupt {
                    self.interrupt = false;
                    return Err(io::ErrorKind::Interrupted.into());
                }
                self.interrupt = true;
                self.input.read(&mut out[..1])
            }
        }
        let bytes = b"{\"event\":\"error\",\"code\":\"lock_unavailable\"}\n";
        let mut input = Interrupted {
            input: Cursor::new(bytes.to_vec()),
            interrupt: true,
        };
        let report = drain_stderr(&mut input, true);
        assert!(!report.read_failed);
        assert_eq!(input.input.position(), bytes.len() as u64);
        assert_eq!(report.failure("fallback").unwrap().code, "card_busy");
    }

    #[test]
    fn later_cleanup_uncertainty_has_priority_without_losing_first_cause() {
        let report = diagnostics(
            concat!(
                "{\"event\":\"error\",\"code\":\"qmi_open_rejected\"}\n",
                "{\"event\":\"cleanup_failed\",\"stage\":\"channel_close\"}\n",
                "{\"event\":\"lock_retained\",\"reason\":\"channel_cleanup_unknown\"}\n",
                "{\"event\":\"error\",\"code\":\"channel_close_failed\"}\n"
            )
            .as_bytes(),
        );
        let error = report.failure("fallback").unwrap();
        assert_eq!(error.code, "card_cleanup_unknown");
        assert_eq!(error.component_error, Some("qmi_open_rejected"));
        assert!(report.lock_retained && report.cleanup_unknown);
    }

    #[test]
    fn known_helper_causes_map_to_only_fixed_public_codes() {
        for (code, expected) in [
            ("lock_unavailable", "card_busy"),
            ("qmi_open_rejected", "card_open_rejected"),
            ("qmi_open_unknown", "card_cleanup_unknown"),
            ("channel_open_outcome_unknown", "card_cleanup_unknown"),
            ("card_cleanup_unknown", "card_cleanup_unknown"),
            ("card_not_ready", "card_not_ready"),
            ("selection_mismatch", "snapshot_cleanup_failed"),
        ] {
            let line = format!("{{\"event\":\"error\",\"code\":\"{code}\"}}\n");
            let report = diagnostics(line.as_bytes());
            let error = report.failure("snapshot_cleanup_failed").unwrap();
            assert_eq!(error.code, expected);
            assert_eq!(error.component_error, Some(code));
        }
    }

    #[test]
    fn retained_marker_alone_is_not_clean_exit() {
        let report =
            diagnostics(b"{\"event\":\"lock_retained\",\"reason\":\"channel_cleanup_unknown\"}\n");
        assert_eq!(
            report.failure("fallback").unwrap().code,
            "card_cleanup_unknown"
        );
    }

    #[test]
    fn typed_open_event_preserves_cause_before_generic_cleanup_events() {
        let report = diagnostics(concat!(
            "{\"event\":\"qmi_open_result\",\"outcome\":\"unknown\",\"qmi_result\":1,\"qmi_error\":2}\n",
            "{\"event\":\"cleanup_unknown\",\"stage\":\"channel_open\"}\n",
            "{\"event\":\"lock_retained\",\"reason\":\"channel_cleanup_unknown\"}\n",
            "{\"event\":\"error\",\"code\":\"card_cleanup_unknown\"}\n"
        ).as_bytes());
        let error = report.failure("fallback").unwrap();
        let (wire, exit) = crate::esim::final_value(Err(error));
        assert_eq!(exit, 1);
        assert_eq!(wire["error"], "card_cleanup_unknown");
        assert_eq!(wire["component_error"], "qmi_open_unknown");
        assert!(wire.get("qmi_error").is_none());
        let report = diagnostics(b"{\"event\":\"qmi_open_result\",\"outcome\":\"rejected\",\"qmi_result\":1,\"qmi_error\":82}\n");
        assert_eq!(
            report.failure("fallback").unwrap().code,
            "card_open_rejected"
        );
    }

    struct Script(PathBuf);
    impl Script {
        fn new(body: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "esim-child-diagnostic-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .unwrap();
            file.write_all(format!("#!/bin/sh\n{body}\n").as_bytes())
                .unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            Self(path)
        }
    }
    impl Drop for Script {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn actual_helper_exit_maps_busy_and_unknown_causes_after_wait() {
        for (code, expected) in [
            ("lock_unavailable", "card_busy"),
            ("qmi_open_rejected", "card_open_rejected"),
            ("qmi_open_unknown", "card_cleanup_unknown"),
            ("SYNTHETIC_PRIVATE", "snapshot_cleanup_failed"),
        ] {
            let script = Script::new(&format!(
                "printf '%s\\n' '{{\"event\":\"error\",\"code\":\"{code}\"}}' >&2\nexit 1"
            ));
            let mut runtime = LocalRuntime::new(script.0.clone(), PathBuf::from("unused"));
            let error = runtime.snapshot().unwrap_err();
            assert_eq!(error.code, expected);
            let (wire, exit) = crate::esim::final_value(Err(error));
            assert_eq!(exit, 1);
            assert_eq!(wire["error"], expected);
            assert!(!wire.to_string().contains("PRIVATE"));
            if code == "SYNTHETIC_PRIVATE" {
                assert!(wire.get("component_error").is_none());
            } else {
                assert_eq!(wire["component_error"], code);
            }
        }
    }

    #[test]
    fn successful_stdout_and_exit_cannot_override_retained_lock_event() {
        let script = Script::new(concat!(
            "printf '%s\\n' '{\"ok\":true,\"eid\":\"11111111111111111111111111111111\",\"profiles\":[]}'\n",
            "printf '%s\\n' '{\"event\":\"lock_retained\",\"reason\":\"channel_cleanup_unknown\"}' >&2\n",
            "exit 0"
        ));
        let mut runtime = LocalRuntime::new(script.0.clone(), PathBuf::from("unused"));
        assert_eq!(runtime.snapshot().unwrap_err().code, "card_cleanup_unknown");
    }
    #[test]
    fn ordinary_result_requires_clean_exit_and_no_cleanup_failure() {
        let wire="{\"ok\":true,\"card\":{\"kind\":\"ordinary_sim\",\"management\":\"unavailable\",\"reason\":\"isdr_not_found\",\"cleanup_confirmed\":true}}";
        for (status, marker) in [
            (0, ""),
            (1, ""),
            (
                0,
                "{\"event\":\"cleanup_failed\",\"stage\":\"channel_close\"}",
            ),
        ] {
            let script = Script::new(&format!(
                "printf '%s\\n' '{wire}'\nprintf '%s\\n' '{marker}' >&2\nexit {status}"
            ));
            let mut runtime = LocalRuntime::new(script.0.clone(), PathBuf::from("never-run-lpac"));
            let inspected = runtime.inspect();
            assert_eq!(inspected.is_ok(), status == 0 && marker.is_empty());
            if let Ok(value) = inspected {
                assert_eq!(value, super::super::model::Inspection::Ordinary);
            }
        }
    }
}
