#ifndef ZTE_LAUNCHER_VPN_MODEL_H
#define ZTE_LAUNCHER_VPN_MODEL_H

struct snapshot;

/* The caller must prove a successful child exit and reject embedded NUL bytes.
 * Failure leaves the complete snapshot unchanged; success changes status only. */
int vpn_parse_status(struct snapshot *out, const char *json);

/* Strict ok:false reply -> a fixed code literal; invalid/success reply -> NULL. */
const char *vpn_error_code(const char *json);
/* Unknown codes are never included in the returned display text. */
const char *vpn_error_text(const char *code, int ru);

#endif
