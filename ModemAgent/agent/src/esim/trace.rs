//! Structured diagnostics only: no request, identifier, APDU or response text.
use super::{Error, Result};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub type Sink = Arc<dyn Fn(Value) -> Result<()> + Send + Sync>;
#[derive(Clone, Copy)]
pub enum Component {
    Snapshot,
    Bridge,
    Lpac,
}
impl Component {
    fn name(self) -> &'static str {
        match self {
            Self::Snapshot => "snapshot",
            Self::Bridge => "bridge",
            Self::Lpac => "lpac",
        }
    }
}
pub enum Event {
    Stage,
    Waiting,
    ComponentStart(Component),
    ComponentExit(Component, bool, u64),
    ApduSent,
    ApduReply(bool, usize, u64),
    HttpStart(usize),
    HttpEnd(u16, usize, u64, bool, Option<&'static str>),
    CleanupStart,
    CleanupEnd(bool, u64, Option<&'static str>),
}
struct State {
    stage: &'static str,
    waiting: &'static str,
    seq: u64,
    apdu: u32,
    http: u32,
    stopped: bool,
}
struct Inner {
    start: Instant,
    state: Mutex<State>,
    wake: Condvar,
    sink: Sink,
}
#[derive(Clone)]
pub struct Trace {
    inner: Arc<Inner>,
}
pub struct Heartbeat {
    trace: Trace,
    thread: Option<JoinHandle<()>>,
}
pub fn millis(start: Instant) -> u64 {
    start.elapsed().as_millis().min(u64::MAX as u128) as u64
}
impl Trace {
    pub fn start(sink: Sink) -> (Self, Heartbeat) {
        Self::with_interval(sink, Duration::from_secs(5))
    }
    pub(super) fn with_interval(sink: Sink, interval: Duration) -> (Self, Heartbeat) {
        let trace = Self {
            inner: Arc::new(Inner {
                start: Instant::now(),
                state: Mutex::new(State {
                    stage: "checking_card",
                    waiting: "card",
                    seq: 0,
                    apdu: 0,
                    http: 0,
                    stopped: false,
                }),
                wake: Condvar::new(),
                sink,
            }),
        };
        let background = trace.clone();
        let thread = std::thread::Builder::new()
            .name("esim-heartbeat".into())
            .spawn(move || loop {
                let Ok(state) = background.inner.state.lock() else {
                    break;
                };
                if state.stopped {
                    break;
                }
                let Ok((state, timed)) = background.inner.wake.wait_timeout(state, interval) else {
                    break;
                };
                if state.stopped {
                    break;
                }
                drop(state);
                if timed.timed_out() && background.event(Event::Waiting).is_err() {
                    break;
                }
            })
            .ok();
        let heartbeat = Heartbeat {
            trace: trace.clone(),
            thread,
        };
        (trace, heartbeat)
    }
    pub fn stage(&self, stage: &'static str) -> Result<()> {
        let mut s = self
            .inner
            .state
            .lock()
            .map_err(|_| Error::new("stream_write_failed"))?;
        s.stage = stage;
        s.waiting = if stage == "cleanup" {
            "cleanup"
        } else {
            "card"
        };
        self.emit(&mut s, Event::Stage)
    }
    pub fn event(&self, event: Event) -> Result<()> {
        let mut s = self
            .inner
            .state
            .lock()
            .map_err(|_| Error::new("stream_write_failed"))?;
        self.emit(&mut s, event)
    }
    fn emit(&self, s: &mut State, event: Event) -> Result<()> {
        if s.stopped {
            return Ok(());
        }
        let mut fields = serde_json::Map::new();
        let event_name = match event {
            Event::Stage => "stage",
            Event::Waiting => {
                fields.insert("waiting_for".into(), json!(s.waiting));
                "waiting"
            }
            Event::ComponentStart(c) => {
                fields.insert("component".into(), json!(c.name()));
                "component_start"
            }
            Event::ComponentExit(c, ok, duration) => {
                fields.insert("component".into(), json!(c.name()));
                fields.insert("outcome".into(), json!(if ok { "ok" } else { "failed" }));
                fields.insert("duration_ms".into(), json!(duration));
                "component_exit"
            }
            Event::ApduSent => {
                s.apdu = s.apdu.saturating_add(1);
                s.waiting = "card";
                if s.apdu > 3 && s.apdu % 25 != 0 {
                    return Ok(());
                }
                "apdu_sent"
            }
            Event::ApduReply(ok, bytes, duration) => {
                if ok && s.apdu > 3 && s.apdu % 25 != 0 {
                    return Ok(());
                }
                fields.insert("outcome".into(), json!(if ok { "ok" } else { "failed" }));
                fields.insert("response_bytes".into(), json!(bytes));
                fields.insert("duration_ms".into(), json!(duration));
                "apdu_reply"
            }
            Event::HttpStart(bytes) => {
                s.http = s.http.saturating_add(1);
                s.waiting = "operator_https";
                fields.insert("request_bytes".into(), json!(bytes));
                "http_start"
            }
            Event::HttpEnd(status, bytes, duration, ok, error) => {
                s.waiting = "card";
                fields.insert("http_status".into(), json!(status));
                fields.insert("response_bytes".into(), json!(bytes));
                fields.insert("duration_ms".into(), json!(duration));
                fields.insert("outcome".into(), json!(if ok { "ok" } else { "failed" }));
                if let Some(error) = error {
                    fields.insert("error".into(), json!(error));
                }
                "http_end"
            }
            Event::CleanupStart => {
                s.waiting = "cleanup";
                "cleanup_start"
            }
            Event::CleanupEnd(ok, duration, error) => {
                fields.insert("outcome".into(), json!(if ok { "ok" } else { "failed" }));
                fields.insert("duration_ms".into(), json!(duration));
                if let Some(error) = error {
                    fields.insert("error".into(), json!(error));
                }
                "cleanup_end"
            }
        };
        s.seq = s.seq.saturating_add(1);
        fields.insert("event".into(), json!(event_name));
        fields.insert("log_seq".into(), json!(s.seq));
        fields.insert("elapsed_ms".into(), json!(millis(self.inner.start)));
        fields.insert("apdu_count".into(), json!(s.apdu));
        fields.insert("http_count".into(), json!(s.http));
        // Serialize sequence assignment and send to avoid out-of-order heartbeats.
        (self.inner.sink)(json!({"type":"progress","stage":s.stage,"detail":fields}))
    }
}
impl Drop for Heartbeat {
    fn drop(&mut self) {
        if let Ok(mut s) = self.trace.inner.state.lock() {
            s.stopped = true;
            self.trace.inner.wake.notify_all();
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

pub struct Wire {
    pub bytes: Vec<u8>,
    pub ack: mpsc::SyncSender<bool>,
}
#[derive(Clone)]
pub struct WireWriter {
    sender: mpsc::Sender<Wire>,
    buffer: Vec<u8>,
}
impl WireWriter {
    pub fn new(sender: mpsc::Sender<Wire>) -> Self {
        Self {
            sender,
            buffer: Vec::new(),
        }
    }
}
impl Write for WireWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.buffer.len().saturating_add(bytes.len()) > super::MAX_LINE {
            return Err(io::Error::other("output limit"));
        }
        self.buffer.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        let (tx, rx) = mpsc::sync_channel(1);
        self.sender
            .send(Wire {
                bytes: std::mem::take(&mut self.buffer),
                ack: tx,
            })
            .map_err(|_| io::Error::other("output closed"))?;
        if rx.recv().unwrap_or(false) {
            Ok(())
        } else {
            Err(io::Error::other("output closed"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn heartbeat_has_fixed_fields_and_stops_before_final() {
        let rows = Arc::new(Mutex::new(Vec::new()));
        let output = rows.clone();
        let (trace, heartbeat) = Trace::with_interval(
            Arc::new(move |v| {
                output.lock().unwrap().push(v);
                Ok(())
            }),
            Duration::from_millis(5),
        );
        trace.stage("downloading").unwrap();
        trace.event(Event::HttpStart(321)).unwrap();
        std::thread::sleep(Duration::from_millis(25));
        trace
            .event(Event::HttpEnd(200, 123, 24, true, None))
            .unwrap();
        drop(heartbeat);
        let before = rows.lock().unwrap().len();
        std::thread::sleep(Duration::from_millis(15));
        assert_eq!(rows.lock().unwrap().len(), before);
        let rows = rows.lock().unwrap();
        assert!(rows
            .iter()
            .any(|v| v["detail"]["waiting_for"] == "operator_https"));
        for (i, row) in rows.iter().enumerate() {
            assert_eq!(row["detail"]["log_seq"], i + 1);
            assert_eq!(row["stage"], "downloading");
        }
        assert_eq!(rows.last().unwrap()["detail"]["http_count"], 1);
    }
    #[test]
    fn apdu_trace_is_throttled_but_counters_are_absolute_and_errors_visible() {
        let rows = Arc::new(Mutex::new(Vec::new()));
        let output = rows.clone();
        let (trace, heartbeat) = Trace::start(Arc::new(move |v| {
            output.lock().unwrap().push(v);
            Ok(())
        }));
        for _ in 0..100 {
            trace.event(Event::ApduSent).unwrap();
            trace.event(Event::ApduReply(true, 2, 1)).unwrap();
        }
        trace.event(Event::ApduSent).unwrap();
        trace.event(Event::ApduReply(false, 0, 1)).unwrap();
        drop(heartbeat);
        let rows = rows.lock().unwrap();
        assert_eq!(rows.len(), 15);
        assert_eq!(rows.last().unwrap()["detail"]["apdu_count"], 101);
        assert_eq!(rows.last().unwrap()["detail"]["outcome"], "failed");
    }
}
