//! QMI over QRTR (`AF_QIPCRTR`).
//!
//! The SDX75 modem here is PCIe/MHI-attached and the kernel is built with
//! `CONFIG_QRTR=y` + `CONFIG_QRTR_MHI=y`, so QMI services are reachable from a
//! plain datagram socket. That matters for this agent specifically: it ships as
//! a static musl binary, so `dlopen`ing the device's `libqmi_cci.so` is not an
//! option, and the alternative — driving the interactive `qmi_simple_ril_test`
//! binary — means parsing a human-readable log for APDU bytes with no reliable
//! way to bound a stuck logical channel.
//!
//! Addressing note: QRTR gives each socket an implicit port, so there is no
//! QMUX control-service client-ID allocation. Requests go straight to the
//! service's `{node, port}` with a 7-byte QMI header.

use std::io;
use std::os::unix::io::RawFd;
use std::time::{Duration, Instant};

use super::tlv::{self, Tlv};

/// Not in the libc crate for every target, so it is spelled out here.
const AF_QIPCRTR: libc::c_int = 42;
const PORT_CONTROL: u32 = 0xffff_fffe;

const CTRL_NEW_SERVER: u32 = 4;
const CTRL_NEW_LOOKUP: u32 = 10;

const QMI_REQUEST: u8 = 0x00;
const QMI_RESPONSE: u8 = 0x02;
const QMI_HEADER_LEN: usize = 7;

/// QMI service IDs.
pub const SERVICE_UIM: u32 = 0x0B;

/// Kernel `struct sockaddr_qrtr`. The 2 bytes of padding after `family` are
/// part of the C layout on both sides, so `repr(C)` matches the kernel.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SockAddrQrtr {
    family: u16,
    node: u32,
    port: u32,
}

/// A blocking QMI client bound to one QRTR service.
pub struct QrtrClient {
    fd: RawFd,
    server: SockAddrQrtr,
    txn: u16,
    timeout: Duration,
}

impl QrtrClient {
    /// Open a socket and resolve `service` through the QRTR name server.
    pub fn connect(service: u32, timeout: Duration) -> Result<Self, String> {
        let fd = unsafe { libc::socket(AF_QIPCRTR, libc::SOCK_DGRAM, 0) };
        if fd < 0 {
            return Err(format!("QRTR socket: {}", io::Error::last_os_error()));
        }

        // Every fallible step below has to go through `fail` so the fd is not
        // leaked — this process is long-lived and would otherwise hit EMFILE.
        let mut client = Self {
            fd,
            server: SockAddrQrtr::default(),
            txn: 0,
            timeout,
        };

        if let Err(e) = client.set_recv_timeout(timeout) {
            return Err(client.fail(e));
        }
        match client.lookup(service, timeout) {
            Ok(server) => client.server = server,
            Err(e) => return Err(client.fail(e)),
        }
        Ok(client)
    }

    fn fail(&mut self, error: String) -> String {
        unsafe { libc::close(self.fd) };
        self.fd = -1;
        error
    }

    fn set_recv_timeout(&self, timeout: Duration) -> Result<(), String> {
        let tv = libc::timeval {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_usec: timeout.subsec_micros() as libc::suseconds_t,
        };
        let rc = unsafe {
            libc::setsockopt(
                self.fd,
                libc::SOL_SOCKET,
                libc::SO_RCVTIMEO,
                &tv as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::timeval>() as libc::socklen_t,
            )
        };
        if rc < 0 {
            return Err(format!("QRTR SO_RCVTIMEO: {}", io::Error::last_os_error()));
        }
        Ok(())
    }

    fn local_addr(&self) -> Result<SockAddrQrtr, String> {
        let mut addr = SockAddrQrtr::default();
        let mut len = std::mem::size_of::<SockAddrQrtr>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockname(
                self.fd,
                &mut addr as *mut _ as *mut libc::sockaddr,
                &mut len,
            )
        };
        if rc < 0 {
            return Err(format!("QRTR getsockname: {}", io::Error::last_os_error()));
        }
        Ok(addr)
    }

    fn send_to(&self, dest: &SockAddrQrtr, data: &[u8]) -> Result<(), String> {
        let sent = unsafe {
            libc::sendto(
                self.fd,
                data.as_ptr() as *const libc::c_void,
                data.len(),
                0,
                dest as *const _ as *const libc::sockaddr,
                std::mem::size_of::<SockAddrQrtr>() as libc::socklen_t,
            )
        };
        if sent < 0 {
            return Err(format!("QRTR sendto: {}", io::Error::last_os_error()));
        }
        if sent as usize != data.len() {
            return Err(format!("QRTR short write: {sent} of {} bytes", data.len()));
        }
        Ok(())
    }

    fn recv_from(&self, buf: &mut [u8]) -> Result<(usize, SockAddrQrtr), String> {
        let mut addr = SockAddrQrtr::default();
        let mut len = std::mem::size_of::<SockAddrQrtr>() as libc::socklen_t;
        let n = unsafe {
            libc::recvfrom(
                self.fd,
                buf.as_mut_ptr() as *mut libc::c_void,
                buf.len(),
                0,
                &mut addr as *mut _ as *mut libc::sockaddr,
                &mut len,
            )
        };
        if n < 0 {
            let err = io::Error::last_os_error();
            return match err.kind() {
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => {
                    Err("QRTR receive timed out".to_string())
                }
                _ => Err(format!("QRTR recvfrom: {err}")),
            };
        }
        Ok((n as usize, addr))
    }

    /// Ask the name server for `service` and wait for its NEW_SERVER reply.
    fn lookup(&self, service: u32, timeout: Duration) -> Result<SockAddrQrtr, String> {
        let local = self.local_addr()?;
        let control = SockAddrQrtr {
            family: AF_QIPCRTR as u16,
            node: local.node,
            port: PORT_CONTROL,
        };

        // struct qrtr_ctrl_pkt: cmd, then {service, instance, node, port}.
        let mut packet = Vec::with_capacity(20);
        packet.extend_from_slice(&CTRL_NEW_LOOKUP.to_le_bytes());
        packet.extend_from_slice(&service.to_le_bytes());
        packet.extend_from_slice(&0u32.to_le_bytes()); // instance: any
        packet.extend_from_slice(&0u32.to_le_bytes()); // node: any
        packet.extend_from_slice(&0u32.to_le_bytes()); // port: any
        self.send_to(&control, &packet)?;

        // The name server replays every matching server, plus unrelated
        // announcements. Take the first entry for the service we asked for.
        let deadline = Instant::now() + timeout;
        let mut buf = [0u8; 256];
        while Instant::now() < deadline {
            let (n, _) = self.recv_from(&mut buf)?;
            if n < 20 {
                continue;
            }
            if u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) != CTRL_NEW_SERVER {
                continue;
            }
            if u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]) != service {
                continue;
            }
            let node = u32::from_le_bytes([buf[12], buf[13], buf[14], buf[15]]);
            let port = u32::from_le_bytes([buf[16], buf[17], buf[18], buf[19]]);
            // A NEW_SERVER with node/port 0 is the end-of-list marker.
            if node == 0 && port == 0 {
                continue;
            }
            return Ok(SockAddrQrtr {
                family: AF_QIPCRTR as u16,
                node,
                port,
            });
        }
        Err(format!("QMI service 0x{service:02X} not found on QRTR"))
    }

    /// Send a request and return the response TLVs.
    ///
    /// Transaction IDs start at 1 because 0 is not a valid QMI transaction.
    pub fn request(&mut self, message_id: u16, tlvs: &[Tlv]) -> Result<Vec<Tlv>, String> {
        self.request_inner(message_id, tlvs, false)
    }

    /// Exact framing is required before using an Open failure as evidence
    /// that no channel was allocated. Other requests retain their old ABI.
    pub fn request_exact(&mut self, message_id: u16, tlvs: &[Tlv]) -> Result<Vec<Tlv>, String> {
        self.request_inner(message_id, tlvs, true)
    }

    fn request_inner(
        &mut self,
        message_id: u16,
        tlvs: &[Tlv],
        exact: bool,
    ) -> Result<Vec<Tlv>, String> {
        self.txn = self.txn.wrapping_add(1).max(1);
        let txn = self.txn;

        let payload = tlv::encode(tlvs);
        let mut packet = Vec::with_capacity(QMI_HEADER_LEN + payload.len());
        packet.push(QMI_REQUEST);
        packet.extend_from_slice(&txn.to_le_bytes());
        packet.extend_from_slice(&message_id.to_le_bytes());
        packet.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        packet.extend_from_slice(&payload);
        let server = self.server;
        self.send_to(&server, &packet)?;

        // Indications for other messages can arrive while a response is
        // pending, so match on transaction and message id rather than taking
        // the first datagram.
        let deadline = Instant::now() + self.timeout;
        let mut buf = vec![0u8; 65536];
        while Instant::now() < deadline {
            let (n, from) = self.recv_from(&mut buf)?;
            if from.node != self.server.node || from.port != self.server.port {
                continue;
            }
            if n < QMI_HEADER_LEN {
                continue;
            }
            let msg_type = buf[0];
            let got_txn = u16::from_le_bytes([buf[1], buf[2]]);
            let got_msg = u16::from_le_bytes([buf[3], buf[4]]);
            let len = u16::from_le_bytes([buf[5], buf[6]]) as usize;
            if msg_type != QMI_RESPONSE || got_txn != txn || got_msg != message_id {
                continue;
            }
            return decode_response_payload(&buf[QMI_HEADER_LEN..n], len, exact);
        }
        Err(format!("QMI request 0x{message_id:04X} timed out"))
    }
}

fn decode_response_payload(
    payload: &[u8],
    declared: usize,
    exact: bool,
) -> Result<Vec<Tlv>, String> {
    if payload.len() < declared || (exact && payload.len() != declared) {
        return Err("QMI response payload length mismatch".into());
    }
    tlv::decode(&payload[..declared])
}

impl Drop for QrtrClient {
    fn drop(&mut self) {
        if self.fd >= 0 {
            unsafe { libc::close(self.fd) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_open_framing_refuses_truncation_and_trailing_bytes() {
        let result = [2, 4, 0, 1, 0, 82, 0];
        assert!(decode_response_payload(&result, result.len(), true).is_ok());
        assert!(decode_response_payload(&result, result.len() + 1, true).is_err());
        let padded = [2, 4, 0, 1, 0, 82, 0, 0];
        assert!(decode_response_payload(&padded, result.len(), true).is_err());
        assert!(decode_response_payload(&padded, result.len(), false).is_ok());
        assert!(decode_response_payload(&result[..6], 6, true).is_err());
    }

    #[test]
    fn sockaddr_matches_kernel_layout() {
        // struct sockaddr_qrtr { __kernel_sa_family_t sq_family; __u32 sq_node;
        // __u32 sq_port; } — 2 bytes of tail padding after the u16.
        assert_eq!(std::mem::size_of::<SockAddrQrtr>(), 12);
        assert_eq!(std::mem::align_of::<SockAddrQrtr>(), 4);
    }

    #[test]
    fn qmi_header_is_seven_bytes() {
        assert_eq!(QMI_HEADER_LEN, 1 + 2 + 2 + 2);
    }
}
