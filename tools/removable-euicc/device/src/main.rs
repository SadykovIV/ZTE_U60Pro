//! Temporary on-device adapter for pinned upstream lpac running on the Mac.
//! Full identifiers and APDU responses are private stdout protocol data.
mod adapter;
mod euicc;
mod platform;
mod qmi;

use adapter::{expected_eid, Result, Session, MAX_LINE};
use platform::{AppLock, RealDevice};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

fn read_line(input: &mut impl BufRead) -> Result<Option<Value>> {
    let mut bytes = Vec::new();
    loop {
        let buf = input.fill_buf().map_err(|_| "stdin_error")?;
        if buf.is_empty() {
            if bytes.is_empty() {
                return Ok(None);
            }
            return Err("unterminated_json_line");
        }
        let count = buf
            .iter()
            .position(|&b| b == b'\n')
            .map(|i| i + 1)
            .unwrap_or(buf.len());
        if bytes.len().saturating_add(count) > MAX_LINE {
            return Err("input_line_too_large");
        }
        let complete = buf[count - 1] == b'\n';
        bytes.extend_from_slice(&buf[..count]);
        input.consume(count);
        if complete {
            return serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|_| "invalid_json_line");
        }
    }
}
fn emit(output: &mut impl Write, value: &Value) -> Result<()> {
    serde_json::to_writer(&mut *output, value).map_err(|_| "stdout_error")?;
    output
        .write_all(b"\n")
        .and_then(|_| output.flush())
        .map_err(|_| "stdout_error")
}
fn bridge(
    input: &mut impl BufRead,
    output: &mut impl Write,
    session: &mut Session<RealDevice>,
) -> Result<()> {
    let result = (|| {
        emit(output, &session.snapshot()?)?;
        while let Some(message) = read_line(input)? {
            emit(output, &session.handle(&message))?;
        }
        Ok(())
    })();
    // EOF, malformed input and broken stdout all reach explicit cleanup.
    session.disconnect()?;
    result
}

fn run(mode: &str) -> Result<()> {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    // Invalid header is rejected before lock, selection commands or QRTR.
    let expected = if mode == "bridge" {
        Some(expected_eid(
            &read_line(&mut input)?.ok_or("missing_header")?,
        )?)
    } else {
        None
    };
    let mut lock = AppLock::acquire()?;
    let mut session = Session::new(RealDevice, expected);
    let result = if mode == "snapshot" {
        session.snapshot().and_then(|v| emit(&mut output, &v))
    } else {
        bridge(&mut input, &mut output, &mut session)
    };
    let close = session.disconnect();
    if session.cleanup_failed {
        lock.retain();
        eprintln!("{{\"event\":\"lock_retained\",\"reason\":\"channel_cleanup_unknown\"}}");
    }
    let release = lock.release();
    close?;
    release?;
    result?;
    if session.operation_failed {
        return Err("bridge_operation_failed");
    }
    Ok(())
}
fn main() {
    // No panic text may contain private request/card data. Normal error paths
    // use static codes; this hook is a final guard, not cleanup confirmation.
    std::panic::set_hook(Box::new(|_| eprintln!("{{\"event\":\"panic\"}}")));
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mode = match args.as_slice() {
        [] => {
            println!("zte-removable-euicc: explicit snapshot | bridge; no default device action");
            return;
        }
        [one] if one == "--help" || one == "--check" => {
            println!("{{\"ok\":true,\"offline\":true,\"modes\":[\"snapshot\",\"bridge\"]}}");
            return;
        }
        [one] if one == "snapshot" || one == "bridge" => one,
        _ => {
            eprintln!("{{\"event\":\"error\",\"code\":\"invalid_arguments\"}}");
            std::process::exit(2);
        }
    };
    if let Err(code) = run(mode) {
        eprintln!("{}", json!({"event":"error","code":code}));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_json_lines() {
        let mut good = &b"{\"type\":\"apdu\"}\n"[..];
        assert!(read_line(&mut good).unwrap().is_some());
        assert_eq!(read_line(&mut good).unwrap(), None);
        let mut bad = &b"{}"[..];
        assert!(read_line(&mut bad).is_err());
        let long = vec![b' '; MAX_LINE + 1];
        assert!(read_line(&mut &long[..]).is_err());
    }
}
