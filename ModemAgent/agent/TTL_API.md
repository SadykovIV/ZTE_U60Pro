# Shared IPv4 TTL API (schema 2)

The existing authentication requirement is unchanged. All three TTL routes run
behind the same bearer-token check as the other protected API routes.
`GET /api/health` also requires authentication and returns the agent package
`version` and `ttl_schema_version: 2` in its data object.

- `GET /api/ttl/status` reads the installed shared manager.
- `PUT /api/ttl/set` requires exactly
  `{"schema_version":2,"outbound":64,"inbound_inc":1}`.
  Each direction is an integer in 1–255 or `null` (off); both fields are required.
- `DELETE /api/ttl/clear` disables both directions through that same manager.

A successful response has `ok: true` and a `data` object:

```json
{
  "schema_version": 2,
  "state": "configured",
  "outbound": 64,
  "inbound_inc": 1,
  "capability": "supported",
  "verification": "unverified",
  "persistence": "boot"
}
```

`state`: `configured`, `disabled`, `error`, `unsupported`.
`capability`: `supported`, `unsupported`, `unknown`.
`verification`: `unverified`, `not-applicable`.
`persistence`: `boot`, `none`.
The adapter never labels a configuration or rules check as packet verification.
Read errors do not return invented defaults. Apply success requires the returned
settings and state to match the complete requested configuration.

Errors contain `ok: false`, an English fallback `error`, and a stable `code` for
localization. Failed manager calls may also contain a bounded `manager_code`
(uppercase letters and underscores only); raw stdout/stderr is not exposed.

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `TTL_INVALID_CONFIGURATION` | Malformed JSON, unknown/duplicate/missing field, invalid direction |
| 409 | `TTL_SCHEMA_UPGRADE_REQUIRED` | Absent/old schema (including old `{ttl:65}` clients); reload dashboard |
| 409 | `TTL_BUSY` | Native application or TTL manager holds an operation lock |
| 409 | `TTL_OTHER_TRANSACTION` | Pending modem setup/IMEI transaction or firmware update |
| 503 | `TTL_MANAGER_UNAVAILABLE` | Shared manager is not installed |
| 503 | `TTL_MANAGER_INTEGRITY` | Unsafe paths/ownership, modified manager, CID or installation mismatch |
| 503 | `TTL_UNSUPPORTED_PROFILE` | Manager cannot support the firmware/acceleration profile |
| 504 | `TTL_TIMEOUT` | The 90-second subprocess deadline expired; refresh status before retrying |
| 502 | `TTL_MANAGER_IO` | Could not run manager or output exceeded 16 KiB per pipe |
| 502 | `TTL_INVALID_STATUS` | Invalid, ambiguous or incoherent manager status |
| 502 | `TTL_APPLY_UNCONFIRMED` | Requested values/state were not confirmed; refresh status |
| 500 | `TTL_MANAGER_FAILED` | Manager reported failure; refresh status |

The client request deadline must exceed 90 seconds for these endpoints. Failed
mutations must be followed by an explicit status refresh; they must not be
presented as a successful rollback or successful apply.

The pinned manager SHA256 is
`b6588072c82ddd7678093a29b983ec4417c6807562819e3bda69cd6534637b7c`.
It validates its firmware/profile, CID, owned files, rules and hooks. The adapter
checks root-owned, non-writable, non-symlink paths and the manager hash before
invocation. It uses fixed `/bin/sh` argv (no `-c` or string interpolation), a clean
environment, bounded I/O, and the native `/tmp/zte-imei-app.lock` for mutations.
Existing locks are never reclaimed. Pending guards also apply to full disable.

Legacy `start_ttl.sh` is neither executed nor written by this build. Deployment
must archive/neutralize only a confirmed upstream-owned legacy installation;
this adapter deliberately does not remove legacy or foreign firewall rules.
