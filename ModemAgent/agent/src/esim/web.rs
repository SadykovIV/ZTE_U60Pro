//! Authenticated, token-owned jobs. No HTTP worker waits for a card operation.
use super::{
    children::LocalRuntime, final_value, model::Request, perform, resources, web_http, Error,
    Relay, Result,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tiny_http::Method;

const RETENTION: Duration = Duration::from_secs(600);
const JOB_BUDGET: Duration = Duration::from_secs(600);
const MAX_JOBS: usize = 16;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Start {
    request_id: String,
    request: Request,
}
struct Job {
    id: String,
    owner: [u8; 32],
    request_id: String,
    fingerprint: [u8; 32],
    stage: String,
    logs: std::collections::VecDeque<Value>,
    result: Option<Value>,
    finished: Option<Instant>,
}
#[derive(Default)]
pub struct Jobs {
    entries: Mutex<Vec<Job>>,
}
fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
fn token(s: &str) -> bool {
    s.len() == 32
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn random_id() -> Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|_| Error::new("job_start_failed"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn fail(status: u16, code: &str) -> (u16, Value) {
    (status, json!({"ok":false,"error":code}))
}
fn view(j: &Job) -> Value {
    json!({"job_id":j.id,"state":if j.result.is_some(){"complete"}else{"running"},
        "stage":j.stage,"result":j.result,"logs":j.logs})
}
impl Jobs {
    fn reserve(
        &self,
        owner: [u8; 32],
        request_id: String,
        fingerprint: [u8; 32],
    ) -> std::result::Result<(String, bool), (u16, Value)> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| fail(503, "job_unavailable"))?;
        entries.retain(|j| !j.finished.is_some_and(|t| t.elapsed() >= RETENTION));
        if let Some(j) = entries
            .iter()
            .find(|j| j.owner == owner && j.request_id == request_id)
        {
            if j.fingerprint != fingerprint {
                return Err(fail(409, "request_id_conflict"));
            }
            return Ok((j.id.clone(), false));
        }
        if entries.iter().any(|j| j.finished.is_none()) {
            return Err(fail(409, "esim_busy"));
        }
        if entries.len() >= MAX_JOBS {
            return Err(fail(429, "job_capacity"));
        }
        let id = random_id().map_err(|e| fail(503, e.code))?;
        entries.push(Job {
            id: id.clone(),
            owner,
            request_id,
            fingerprint,
            stage: "checking_card".into(),
            logs: std::collections::VecDeque::new(),
            result: None,
            finished: None,
        });
        Ok((id, true))
    }
    fn status(&self, owner: [u8; 32], id: &str) -> (u16, Value) {
        let mut entries = match self.entries.lock() {
            Ok(x) => x,
            Err(_) => return fail(503, "job_unavailable"),
        };
        entries.retain(|j| !j.finished.is_some_and(|t| t.elapsed() >= RETENTION));
        match entries.iter().find(|j| j.id == id && j.owner == owner) {
            Some(j) => (200, json!({"ok":true,"data":view(j)})),
            None => fail(404, "job_not_found"),
        }
    }
    fn record(&self, id: &str, event: Value) {
        if let Ok(mut entries) = self.entries.lock() {
            if let Some(j) = entries.iter_mut().find(|j| j.id == id) {
                if j.result.is_some() {
                    return;
                }
                j.stage = event["stage"]
                    .as_str()
                    .unwrap_or("checking_card")
                    .to_owned();
                j.logs.push_back(event);
                while j.logs.len() > 256 {
                    j.logs.pop_front();
                }
            }
        }
    }
    fn launch(self: &Arc<Self>, id: &str, task: impl FnOnce() -> Value + Send + 'static) {
        let jobs = Arc::clone(self);
        let job_id = id.to_owned();
        if std::thread::Builder::new()
            .name("esim-job".into())
            .spawn(move || {
                let value = task(); // Includes bridge EOF/wait and owned-file cleanup.
                jobs.complete(&job_id, value);
            })
            .is_err()
        {
            self.complete(id, final_value(Err(Error::new("job_start_failed"))).0);
        }
    }
    fn complete(self: &Arc<Self>, id: &str, value: Value) {
        if let Ok(mut entries) = self.entries.lock() {
            if let Some(j) = entries.iter_mut().find(|j| j.id == id) {
                j.result = Some(value);
                j.finished = Some(Instant::now());
            }
        }
        // Expire private inventory even when the browser never polls again.
        let weak = Arc::downgrade(self);
        let id = id.to_owned();
        let _ = std::thread::Builder::new()
            .name("esim-expiry".into())
            .spawn(move || {
                std::thread::sleep(RETENTION);
                if let Some(jobs) = weak.upgrade() {
                    if let Ok(mut entries) = jobs.entries.lock() {
                        entries.retain(|j| j.id != id);
                    }
                }
            });
    }
}

pub fn route(
    jobs: &Arc<Jobs>,
    method: &Method,
    path: &str,
    bearer: &str,
    body: &[u8],
) -> (u16, Value) {
    // Defense in depth: this handler is only reached after AuthState validation.
    if bearer.is_empty() {
        return fail(401, "unauthorized");
    }
    let owner = digest(bearer.as_bytes());
    if *method == Method::Get && path == "/api/esim/capabilities" {
        return (
            200,
            json!({"ok":true,"data":{"protocol":1,"version":crate::AGENT_VERSION,
            "operations":["list","download","enable","delete"],"https_transport":"agent_curl",
            "web_download_requires_modem_internet":true,"https_transport_available":web_http::available(),
            "private_rpc_protocol":1,"job_budget_seconds":JOB_BUDGET.as_secs(),
            "enable_radio_cycle":true,"enable_modem_readback":true,
            "result_retention_seconds":RETENTION.as_secs(),"cleanup":"graceful_eof_no_channel_kill"}}),
        );
    }
    if *method == Method::Get {
        if let Some(id) = path.strip_prefix("/api/esim/jobs/") {
            if token(id) {
                return jobs.status(owner, id);
            }
        }
        return fail(404, "not_found");
    }
    if *method != Method::Post || path != "/api/esim/jobs" {
        return fail(404, "not_found");
    }
    let value: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return fail(400, "invalid_request"),
    };
    let fingerprint = digest(&serde_json::to_vec(&value).unwrap_or_default());
    let start: Start = match serde_json::from_value(value) {
        Ok(v) => v,
        Err(_) => return fail(400, "invalid_request"),
    };
    if !token(&start.request_id) {
        return fail(400, "invalid_request_id");
    }
    if let Err(e) = start.request.validate() {
        return fail(400, e.code);
    }
    let (id, created) = match jobs.reserve(owner, start.request_id, fingerprint) {
        Ok(v) => v,
        Err(v) => return v,
    };
    if created {
        let worker_jobs = Arc::clone(jobs);
        let worker_id = id.clone();
        jobs.launch(&id, move || {
            let deadline = Instant::now() + JOB_BUDGET;
            let log_jobs = Arc::clone(&worker_jobs);
            let log_id = worker_id.clone();
            let (trace, heartbeat) = super::trace::Trace::start(Arc::new(move |event| {
                log_jobs.record(&log_id, event);
                Ok(())
            }));
            let mut relay = WebRelay {
                trace,
                deadline,
                root: None,
            };
            let result = run(start.request, &mut relay, deadline);
            drop(heartbeat);
            let (value, _) = final_value(result);
            value
        });
    }
    let (_, value) = jobs.status(owner, &id);
    (202, value)
}

struct WebRelay {
    trace: super::trace::Trace,
    deadline: Instant,
    root: Option<std::path::PathBuf>,
}
impl Relay for WebRelay {
    fn progress(&mut self, stage: &'static str) -> Result<()> {
        if Instant::now() >= self.deadline {
            return Err(Error::new("job_deadline_exceeded"));
        }
        self.trace.stage(stage)
    }
    fn http(&mut self, payload: &Value) -> Result<Value> {
        let started = Instant::now();
        self.trace.event(super::trace::Event::HttpStart(
            payload["tx"].as_str().map_or(0, |s| s.len() / 2),
        ))?;
        let result = (|| {
            let root = self.root.as_deref().ok_or(Error::new("http_unavailable"))?;
            web_http::post(payload, root, self.deadline)
        })();
        let (status, bytes) = result
            .as_ref()
            .map(|v| {
                (
                    v["rcode"].as_u64().unwrap_or(0) as u16,
                    v["rx"].as_str().map_or(0, |s| s.len() / 2),
                )
            })
            .unwrap_or((0, 0));
        self.trace.event(super::trace::Event::HttpEnd(
            status,
            bytes,
            super::trace::millis(started),
            (200..=299).contains(&status),
            result.as_ref().err().map(|e| e.code),
        ))?;
        result
    }
}
fn run(request: Request, relay: &mut WebRelay, deadline: Instant) -> Result<super::Outcome> {
    relay.progress("checking_card")?;
    resources::check_device()?;
    let _operation = super::operation_lock::OperationLock::acquire()?;
    let mut resources = resources::Resources::extract()?;
    relay.root = Some(resources.gsma_root.clone());
    let mut runtime =
        LocalRuntime::with_deadline(resources.helper.clone(), resources.lpac.clone(), deadline);
    runtime.set_trace(relay.trace.clone());
    let result = perform(&request, &mut runtime, relay);
    let _ = relay.trace.stage("cleanup");
    let cleanup_started = Instant::now();
    let _ = relay.trace.event(super::trace::Event::CleanupStart);
    let closed = super::Runtime::end(&mut runtime);
    drop(runtime);
    let cleaned = resources.cleanup();
    let error = closed
        .as_ref()
        .err()
        .or(cleaned.as_ref().err())
        .map(|e| e.code);
    let _ = relay.trace.event(super::trace::Event::CleanupEnd(
        closed.is_ok() && cleaned.is_ok(),
        super::trace::millis(cleanup_started),
        error,
    ));
    closed?;
    cleaned?;
    result
}

/// Local root-only launcher adapter: same backend and modem HTTPS policy,
/// without AppState, a listener, authentication material or server startup.
pub(super) fn launcher(
    request: Request,
    output: &mut (impl std::io::Write + Send),
) -> Result<super::Outcome> {
    std::thread::scope(|scope| {
        let (tx, rx) = std::sync::mpsc::channel::<super::trace::Wire>();
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
        let writer = super::trace::WireWriter::new(tx);
        let (trace, heartbeat) = super::trace::Trace::start(Arc::new(move |value| {
            super::children::emit(&mut writer.clone(), &value)
        }));
        let deadline = Instant::now() + JOB_BUDGET;
        let mut relay = WebRelay {
            trace,
            deadline,
            root: None,
        };
        let result = run(request, &mut relay, deadline);
        drop(relay);
        drop(heartbeat);
        result
    })
}

// Diagnostic entry point: exact production job handlers, only a hard-coded list.
// It runs before normal startup and never creates AppState or a network listener.
pub fn read_check() -> Value {
    let jobs = Arc::new(Jobs::default());
    let owner = match random_id() {
        Ok(v) => v,
        Err(_) => return json!({"ok":false,"error":"job_start_failed"}),
    };
    let (_, capabilities) = route(&jobs, &Method::Get, "/api/esim/capabilities", &owner, &[]);
    let body = json!({"request_id":owner,"request":{"protocol":1,"operation":"list"}});
    let (status, start) = route(
        &jobs,
        &Method::Post,
        "/api/esim/jobs",
        &owner,
        &serde_json::to_vec(&body).unwrap_or_default(),
    );
    if status != 202 {
        return json!({"ok":false,"error":"job_start_failed"});
    }
    let Some(id) = start["data"]["job_id"].as_str() else {
        return json!({"ok":false,"error":"job_start_failed"});
    };
    let path = format!("/api/esim/jobs/{id}");
    let isolated = route(&jobs, &Method::Get, &path, "different-owner", &[]).0 == 404;
    loop {
        let (_, value) = route(&jobs, &Method::Get, &path, &owner, &[]);
        if value["data"]["state"] == "complete" {
            let result = value["data"]["result"].clone();
            return json!({"ok":isolated && result["ok"]==true,"owner_isolation":isolated,
                "capabilities":capabilities["data"],"job_result":result,"logs":value["data"]["logs"]});
        }
        // Never kill a bridge to turn a cleanup wait into a diagnostic timeout.
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owner_and_idempotency_and_busy() {
        let jobs = Arc::new(Jobs::default());
        let owner = digest(b"one");
        let fp = digest(b"request");
        let (id, new) = jobs.reserve(owner, "a".repeat(32), fp).unwrap();
        assert!(new);
        assert_eq!(
            jobs.reserve(owner, "a".repeat(32), fp).unwrap(),
            (id.clone(), false)
        );
        assert_eq!(
            jobs.reserve(owner, "a".repeat(32), digest(b"other"))
                .unwrap_err()
                .0,
            409
        );
        assert_eq!(jobs.status(digest(b"two"), &id).0, 404);
        assert_eq!(jobs.reserve(owner, "b".repeat(32), fp).unwrap_err().0, 409);
        jobs.complete(&id, json!({"type":"result","ok":false,"error":"fixture"}));
        assert_eq!(jobs.status(owner, &id).1["data"]["state"], "complete");
        assert!(jobs.reserve(owner, "b".repeat(32), fp).unwrap().1);
    }
    #[test]
    fn final_is_not_visible_until_worker_cleanup_returns() {
        let jobs = Arc::new(Jobs::default());
        let owner = digest(b"owner");
        let (id, _) = jobs
            .reserve(owner, "c".repeat(32), digest(b"read"))
            .unwrap();
        let (tx, rx) = std::sync::mpsc::sync_channel::<()>(1);
        jobs.launch(&id, move || {
            rx.recv().unwrap();
            final_value(Err(Error::new("bridge_cleanup_failed"))).0
        });
        let status = jobs.status(owner, &id).1;
        assert_eq!(status["data"]["state"], "running");
        assert!(status["data"]["result"].is_null());
        tx.send(()).unwrap();
        let until = Instant::now() + Duration::from_secs(2);
        loop {
            let value = jobs.status(owner, &id).1;
            if value["data"]["state"] == "complete" {
                assert_eq!(value["data"]["result"]["ok"], false);
                assert_eq!(value["data"]["result"]["error"], "bridge_cleanup_failed");
                assert_eq!(value["data"]["result"]["card"], json!({
                    "kind":"unknown", "management":"unknown",
                    "reason":"cleanup_unknown", "cleanup_confirmed":false
                }));
                break;
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    #[test]
    fn timeline_is_bounded_and_owned_and_stops_at_completion() {
        let jobs = Arc::new(Jobs::default());
        let owner = digest(b"one");
        let (id, _) = jobs
            .reserve(owner, "d".repeat(32), digest(b"request"))
            .unwrap();
        for i in 1..=300 {
            jobs.record(&id,json!({"type":"progress","stage":"reading_profiles","detail":{"event":"waiting","log_seq":i,"elapsed_ms":i,"apdu_count":0,"http_count":0,"waiting_for":"card"}}));
        }
        let view = jobs.status(owner, &id).1;
        let logs = view["data"]["logs"].as_array().unwrap();
        assert_eq!(logs.len(), 256);
        assert_eq!(logs[0]["detail"]["log_seq"], 45);
        assert_eq!(jobs.status(digest(b"other"), &id).0, 404);
        jobs.complete(&id, json!({"type":"result","ok":false,"error":"fixture"}));
        jobs.record(
            &id,
            json!({"type":"progress","stage":"cleanup","detail":{"log_seq":301}}),
        );
        assert_eq!(
            jobs.status(owner, &id).1["data"]["logs"]
                .as_array()
                .unwrap()
                .last()
                .unwrap()["detail"]["log_seq"],
            300
        );
    }

    #[test]
    fn rejects_unknown_fields_without_worker() {
        let jobs = Arc::new(Jobs::default());
        for body in [
            json!({"request_id":"a".repeat(32),"request":{"protocol":1,"operation":"list"},"unknown":1}),
            json!({"request_id":"a".repeat(32),"request":{"protocol":1,"operation":"list","secret":"never-log"}}),
            json!({"request_id":"bad","request":{"protocol":1,"operation":"list"}}),
        ] {
            let response = route(
                &jobs,
                &Method::Post,
                "/api/esim/jobs",
                "owner",
                &serde_json::to_vec(&body).unwrap(),
            );
            assert_eq!(response.0, 400);
            assert!(!response.1.to_string().contains("never-log"));
        }
        assert!(jobs.entries.lock().unwrap().is_empty());
        assert_eq!(
            route(&jobs, &Method::Get, "/api/esim/capabilities", "", &[]).0,
            401
        );
    }
    #[test]
    fn completed_results_expire_active_job_not_evicted() {
        let jobs = Jobs::default();
        let owner = digest(b"owner");
        let (id, _) = jobs.reserve(owner, "a".repeat(32), digest(b"one")).unwrap();
        {
            let mut entries = jobs.entries.lock().unwrap();
            entries[0].finished = Some(Instant::now() - RETENTION);
            entries[0].result = Some(json!({"eid":"private"}));
        }
        assert_eq!(jobs.status(owner, &id).0, 404);
        assert!(jobs.entries.lock().unwrap().is_empty());
        assert!(jobs.reserve(owner, "b".repeat(32), digest(b"two")).is_ok());
    }
}
