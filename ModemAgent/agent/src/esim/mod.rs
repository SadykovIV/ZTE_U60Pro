//! One private NDJSON request; no HTTP server, startup migration or persistent config.
mod card;
mod children;
mod model;
mod operation_lock;
mod radio;
mod radio_qmi;
mod resources;
#[cfg(test)]
mod tests;
mod trace;
pub mod web;
mod web_http;

use children::{emit, read_json, LocalRuntime};
use model::{notification_arguments, sequence_numbers, Operation, Request, Snapshot};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::io::{BufRead, Write};

pub const MAX_LINE: usize = 9 * 1024 * 1024;
pub const MAX_BODY: usize = 4 * 1024 * 1024;

pub struct Error {
    code: &'static str,
    component_error: Option<&'static str>,
    snapshot: Option<Snapshot>,
    radio_restored: Option<bool>,
    modem_verified: Option<bool>,
}
impl std::fmt::Debug for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code)
    }
}
impl Error {
    fn new(code: &'static str) -> Self {
        Self {
            code,
            component_error: None,
            snapshot: None,
            radio_restored: None,
            modem_verified: None,
        }
    }
    fn component(mut self, code: Option<&'static str>) -> Self {
        self.component_error = code;
        self
    }
    fn snapshot(mut self, snapshot: Snapshot) -> Self {
        self.snapshot = Some(snapshot);
        self
    }
    fn radio(mut self, restored: bool) -> Self {
        self.radio_restored = Some(restored);
        self.modem_verified = Some(false);
        self
    }
}
pub type Result<T> = std::result::Result<T, Error>;

pub trait Relay {
    fn http(&mut self, payload: &Value) -> Result<Value>;
    fn progress(&mut self, stage: &'static str) -> Result<()>;
}
pub trait Runtime {
    fn snapshot(&mut self) -> Result<Snapshot>;
    fn begin(&mut self, expected: &Snapshot) -> Result<()>;
    fn command(&mut self, arguments: &[String], http: &mut dyn Relay) -> Result<Value>;
    fn end(&mut self) -> Result<()>;
    fn radio_ready(&mut self) -> Result<()>;
    fn refresh_modem(&mut self, expected_iccid: &str, relay: &mut dyn Relay) -> Result<()>;
}

struct Rpc<'a, R: BufRead, W: Write> {
    input: &'a mut R,
    output: &'a mut W,
    next_id: u64,
    trace: Option<trace::Trace>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HttpResponse {
    #[serde(rename = "type")]
    kind: String,
    id: u64,
    rcode: u16,
    rx: String,
}
impl<R: BufRead, W: Write> Relay for Rpc<'_, R, W> {
    fn http(&mut self, payload: &Value) -> Result<Value> {
        model::validate_http_payload(payload)?;
        let started = std::time::Instant::now();
        if let Some(trace) = &self.trace {
            trace.event(trace::Event::HttpStart(
                payload["tx"].as_str().map_or(0, |s| s.len() / 2),
            ))?;
        }
        let result = (|| {
            let id = self.next_id;
            self.next_id = self
                .next_id
                .checked_add(1)
                .ok_or(Error::new("http_id_exhausted"))?;
            emit(
                self.output,
                &json!({"type":"http","id":id,"payload":payload}),
            )?;
            let value = read_json(self.input)?.ok_or(Error::new("http_reply_missing"))?;
            let reply: HttpResponse =
                serde_json::from_value(value).map_err(|_| Error::new("invalid_http_reply"))?;
            if reply.kind != "http_response"
                || reply.id != id
                || !model::hex(&reply.rx, MAX_BODY)
                || !(reply.rcode == 0 || (100..=599).contains(&reply.rcode))
                || (reply.rcode == 0 && !reply.rx.is_empty())
            {
                return Err(Error::new("invalid_http_reply"));
            }
            Ok(json!({"rcode":reply.rcode,"rx":reply.rx}))
        })();
        if let Some(trace) = &self.trace {
            let (status, bytes) = result
                .as_ref()
                .map(|v: &Value| {
                    (
                        v["rcode"].as_u64().unwrap_or(0) as u16,
                        v["rx"].as_str().map_or(0, |s| s.len() / 2),
                    )
                })
                .unwrap_or((0, 0));
            let error = result.as_ref().err().map(|e: &Error| e.code);
            trace.event(trace::Event::HttpEnd(
                status,
                bytes,
                trace::millis(started),
                (200..=299).contains(&status),
                error,
            ))?;
        }
        result
    }
    fn progress(&mut self, stage: &'static str) -> Result<()> {
        if let Some(trace) = &self.trace {
            trace.stage(stage)
        } else {
            emit(self.output, &json!({"type":"progress","stage":stage}))
        }
    }
}

struct Outcome {
    snapshot: Snapshot,
    changed: bool,
    notifications_pending: bool,
    modem_verified: Option<bool>,
}

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|s| (*s).to_owned()).collect()
}

fn launcher_request(value: Value) -> Result<Request> {
    let r: Request = serde_json::from_value(value).map_err(|_| Error::new("invalid_request"))?;
    r.validate()?;
    if !matches!(r.operation, Operation::List | Operation::Enable) {
        return Err(Error::new("launcher_operation_refused"));
    }
    Ok(r)
}

fn notifications(
    runtime: &mut impl Runtime,
    rpc: &mut dyn Relay,
    previous: &BTreeSet<u32>,
) -> Result<bool> {
    let fresh_all = sequence_numbers(&runtime.command(&args(&["notification", "list"]), rpc)?)?;
    let fresh = fresh_all
        .difference(previous)
        .copied()
        .collect::<BTreeSet<_>>();
    if fresh.is_empty() {
        return Ok(false);
    }
    if let Some(arguments) = notification_arguments(previous, &fresh) {
        runtime.command(&arguments, rpc)?;
    }
    let remaining = sequence_numbers(&runtime.command(&args(&["notification", "list"]), rpc)?)?;
    Ok(!fresh.is_disjoint(&remaining))
}

fn perform(request: &Request, runtime: &mut impl Runtime, rpc: &mut dyn Relay) -> Result<Outcome> {
    request.validate()?;
    rpc.progress("reading_profiles")?;
    let before = runtime.snapshot()?;
    before.validate()?;
    if request.operation == Operation::List {
        return Ok(Outcome {
            snapshot: before,
            changed: false,
            notifications_pending: false,
            modem_verified: None,
        });
    }
    let expected = request
        .expected_snapshot
        .as_ref()
        .ok_or(Error::new("snapshot_required"))?;
    if !before.matches(expected) {
        return Err(Error::new("snapshot_changed"));
    }
    let arguments = request.arguments(&before)?;
    if request.operation == Operation::Enable {
        // Fail before profile mutation if exact operating-mode readback is
        // unavailable or the user already placed the modem in flight mode.
        runtime.radio_ready()?;
    }
    if request.operation == Operation::Enable && request.postcondition(&before, &before) {
        runtime.refresh_modem(request.iccid.as_deref().unwrap(), rpc)?;
        rpc.progress("verifying")?;
        let after = runtime.snapshot().map_err(|e| e.radio(true))?;
        after.validate().map_err(|e| e.radio(true))?;
        if !request.postcondition(&before, &after) {
            return Err(Error::new("postcondition_failed")
                .snapshot(after)
                .radio(true));
        }
        return Ok(Outcome {
            snapshot: after,
            changed: false,
            notifications_pending: false,
            modem_verified: Some(true),
        });
    }
    // Second guard: helper holds its process lock while performing this handshake.
    runtime.begin(&before)?;
    let previous = runtime
        .command(&args(&["notification", "list"]), rpc)
        .and_then(|v| sequence_numbers(&v))
        .ok();
    let result = (|| {
        rpc.progress(match request.operation {
            Operation::Download => "downloading",
            Operation::Enable => "enabling",
            Operation::Delete => "deleting",
            Operation::List => unreachable!(),
        })?;
        // Exactly one mutation call. Never retry on a transport or card failure.
        runtime.command(&arguments, rpc)
    })();
    let closed = runtime.end();
    closed?;
    rpc.progress("verifying")?;
    let mut after = runtime.snapshot()?;
    after.validate()?;
    if before.eid != after.eid {
        return Err(Error::new("card_changed"));
    }
    if let Err(error) = result {
        return Err(error.snapshot(after));
    }
    if !request.postcondition(&before, &after) {
        return Err(Error::new("postcondition_failed").snapshot(after));
    }
    if request.operation == Operation::Enable {
        // end() and the postcondition snapshot have both fully closed their
        // owned channels. No radio write can race this operation's APDU bridge.
        runtime
            .refresh_modem(request.iccid.as_deref().unwrap(), rpc)
            .map_err(|e| e.snapshot(after.clone()))?;
        rpc.progress("verifying").map_err(|e| e.radio(true))?;
        let fresh = runtime.snapshot().map_err(|e| e.radio(true))?;
        fresh.validate().map_err(|e| e.radio(true))?;
        if !request.postcondition(&before, &fresh) {
            return Err(Error::new("postcondition_failed")
                .snapshot(fresh)
                .radio(true));
        }
        after = fresh;
    }
    // Deliver notifications after confirmed mutation and cleanup. Their ordinary
    // HTTP/LPA failure does not undo the change or permit a mutation retry.
    let mut pending = true;
    if let Some(previous) = previous {
        rpc.progress("notifications")?;
        match runtime.begin(&after) {
            Ok(()) => {
                let delivery = notifications(runtime, rpc, &previous);
                if let Err(error) = runtime.end() {
                    let error = if error.code == "card_cleanup_unknown" {
                        error
                    } else {
                        Error::new("notification_cleanup_failed").component(error.component_error)
                    };
                    return Err(error.snapshot(after));
                }
                pending = delivery.unwrap_or(true);
            }
            Err(error) => {
                // No helper cleanup assertion can be made from a failed begin.
                return Err(error.snapshot(after));
            }
        }
    }
    Ok(Outcome {
        snapshot: after,
        changed: true,
        notifications_pending: pending,
        modem_verified: (request.operation == Operation::Enable).then_some(true),
    })
}

fn run_rpc(input: &mut impl BufRead, output: &mut (impl Write + Send)) -> Result<Outcome> {
    let value = read_json(input)?.ok_or(Error::new("request_missing"))?;
    let request: Request =
        serde_json::from_value(value).map_err(|_| Error::new("invalid_request"))?;
    request.validate()?;
    // One writer serializes complete NDJSON lines from the operation and timer.
    // It is scoped: no background writer can outlive final-result emission.
    std::thread::scope(|scope| {
        let (tx, rx) = std::sync::mpsc::channel::<trace::Wire>();
        scope.spawn(move || {
            while let Ok(wire) = rx.recv() {
                let ok = output
                    .write_all(&wire.bytes)
                    .and_then(|_| output.flush())
                    .is_ok();
                let _ = wire.ack.send(ok);
                if !ok {
                    break;
                }
            }
        });
        let writer = trace::WireWriter::new(tx);
        let event_writer = writer.clone();
        let (trace, heartbeat) = trace::Trace::start(std::sync::Arc::new(move |value| {
            emit(&mut event_writer.clone(), &value)
        }));
        let mut writer = writer;
        let mut rpc = Rpc {
            input,
            output: &mut writer,
            next_id: 1,
            trace: Some(trace.clone()),
        };
        let result = (|| {
            rpc.progress("checking_card")?;
            resources::check_device()?;
            let _operation = operation_lock::OperationLock::acquire()?;
            let mut resources = resources::Resources::extract()?;
            let mut runtime = LocalRuntime::new(resources.helper.clone(), resources.lpac.clone());
            runtime.set_trace(trace.clone());
            let result = perform(&request, &mut runtime, &mut rpc);
            let _ = trace.stage("cleanup");
            let cleanup_started = std::time::Instant::now();
            let _ = trace.event(trace::Event::CleanupStart);
            let closed = runtime.end();
            drop(runtime);
            let cleaned = resources.cleanup();
            let error = closed
                .as_ref()
                .err()
                .or(cleaned.as_ref().err())
                .map(|e| e.code);
            let _ = trace.event(trace::Event::CleanupEnd(
                closed.is_ok() && cleaned.is_ok(),
                trace::millis(cleanup_started),
                error,
            ));
            closed?;
            cleaned?;
            result
        })();
        drop(rpc);
        drop(heartbeat);
        drop(trace);
        drop(writer);
        result
    })
}

fn final_value(result: Result<Outcome>) -> (Value, i32) {
    match result {
        Ok(outcome) => {
            if let Err(error) = outcome.snapshot.validate() {
                return final_value(Err(error));
            }
            let mut value = json!({"type":"result","ok":true,"snapshot":outcome.snapshot,
                "changed":outcome.changed,"notifications_pending":outcome.notifications_pending,
                "card":card::Status::confirmed()});
            if let Some(verified) = outcome.modem_verified {
                value["modem_verified"] = json!(verified);
                value["radio_restored"] = json!(true);
            }
            (value, 0)
        }
        Err(error) => {
            let mut value = json!({"type":"result","ok":false,"error":error.code,
                "card":card::Status::failed(&error)});
            if let Some(code) = error.component_error {
                value["component_error"] = json!(code);
            }
            if let Some(snapshot) = error.snapshot {
                value["snapshot"] = json!(snapshot);
            }
            if let Some(v) = error.modem_verified {
                value["modem_verified"] = json!(v);
            }
            if let Some(v) = error.radio_restored {
                value["radio_restored"] = json!(v);
            }
            (value, 1)
        }
    }
}

pub fn early_entry() -> Option<i32> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    if !arguments.iter().any(|s| s.starts_with("--esim")) {
        return None;
    }
    // Dependency panics must not expose request/card values in the SSH stderr.
    std::panic::set_hook(Box::new(|_| eprintln!("{{\"event\":\"esim_panic\"}}")));
    let mut output = std::io::stdout();
    if arguments == ["--esim-rpc"] || arguments == ["--esim-launcher"] {
        // SSH channel loss becomes EOF/EPIPE, allowing owned card cleanup and
        // radio recovery. Normal permanent-server signal behavior is unchanged.
        if unsafe { libc::signal(libc::SIGHUP, libc::SIG_IGN) } == libc::SIG_ERR {
            let (value, _) = final_value(Err(Error::new("unsupported_device")));
            let _ = emit(&mut output, &value);
            return Some(1);
        }
    }
    if arguments == ["--esim-check"] {
        let valid = resources::verify().is_ok();
        let value = json!({"ok":valid,"offline":true,"protocol":1,"version":crate::AGENT_VERSION,
            "helper_sha256":resources::BRIDGE_HASH,"lpac_sha256":resources::LPAC_HASH,
            "operations":["list","download","enable","delete"]});
        return Some(if emit(&mut output, &value).is_ok() && valid {
            0
        } else {
            1
        });
    }
    if arguments == ["--esim-radio-check"] {
        let checked = (|| {
            resources::check_device()?;
            let _operation = operation_lock::OperationLock::acquire()?;
            let mode = radio_qmi::mode()?;
            let _private_iccid = radio_qmi::iccid()?;
            Ok::<_, Error>(json!({"ok":true,"read_only":true,"mode":mode,"slot1_iccid_valid":true}))
        })();
        let value = match checked {
            Ok(v) => v,
            Err(e) => json!({"ok":false,"read_only":true,"error":e.code}),
        };
        let status = if value["ok"] == true { 0 } else { 1 };
        return Some(if emit(&mut output, &value).is_ok() {
            status
        } else {
            1
        });
    }
    if arguments == ["--esim-radio-restore"] {
        let checked = (|| {
            resources::check_device()?;
            let _operation = operation_lock::OperationLock::acquire()?;
            let before = radio_qmi::mode()?;
            if before != 0 && before != 1 {
                return Err(Error::new("radio_not_online"));
            }
            let ack = if before == 1 {
                radio_qmi::set_online().ok()
            } else {
                None
            };
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
            let mut after = None;
            for _ in 0..20 {
                after = radio_qmi::mode().ok();
                if after == Some(0) || std::time::Instant::now() >= deadline {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
            Ok::<_, Error>(
                json!({"ok":after==Some(0),"mode_before":before,"mode_after":after,
                "set_attempted":before==1,"set_acknowledged":ack==Some((0,0)),
                "qmi_result":ack.map(|x|x.0),"qmi_error":ack.map(|x|x.1)}),
            )
        })();
        let value = match checked {
            Ok(v) => v,
            Err(e) => json!({"ok":false,"error":e.code}),
        };
        let status = if value["ok"] == true { 0 } else { 1 };
        return Some(if emit(&mut output, &value).is_ok() {
            status
        } else {
            1
        });
    }
    if arguments == ["--esim-web-read-check"] || arguments == ["--esim-https-check"] {
        let value = if arguments[0] == "--esim-web-read-check" {
            web::read_check()
        } else {
            web_http::check()
        };
        let ok = value["ok"] == true;
        return Some(if emit(&mut output, &value).is_ok() && ok {
            0
        } else {
            1
        });
    }
    let result = if arguments == ["--esim-launcher"] {
        let mut input = std::io::stdin().lock();
        read_json(&mut input)
            .and_then(|v| launcher_request(v.ok_or(Error::new("request_missing"))?))
            .and_then(|r| web::launcher(r, &mut output))
    } else if arguments == ["--esim-rpc"] {
        let mut input = std::io::stdin().lock();
        run_rpc(&mut input, &mut output)
    } else {
        Err(Error::new("invalid_arguments"))
    };
    let (value, status) = final_value(result);
    Some(if emit(&mut output, &value).is_ok() {
        status
    } else {
        1
    })
}
