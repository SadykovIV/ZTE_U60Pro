#ifndef ZTE_LAUNCHER_VPN_MODEL_H
#define ZTE_LAUNCHER_VPN_MODEL_H

#include <stddef.h>
struct snapshot;

/* The caller must prove a successful child exit and reject embedded NUL bytes.
 * Failure leaves the complete snapshot unchanged; success changes status only. */
int vpn_parse_status(struct snapshot *out, const char *json);

/* Strict ok:false reply -> a fixed code literal; invalid/success reply -> NULL. */
const char *vpn_error_code(const char *json);
/* Unknown codes are never included in the returned display text. */
const char *vpn_error_text(const char *code, int ru);

/* Batch only the UUIDs captured when the user pressed Update. Each callback
 * performs one existing RPC and leaves status unchanged on failure. */
typedef int (*vpn_request_fn)(void *,struct snapshot *,const char *,const char **);
typedef void (*vpn_progress_fn)(void *,const struct snapshot *);
int vpn_update_subscriptions(struct snapshot *,vpn_request_fn,vpn_progress_fn,void *);
int vpn_can_update_subscriptions(const struct snapshot *);
void vpn_subscription_text(const struct snapshot *,int ru,char *,size_t);
const char *vpn_warning_text(const char *,int ru);

#endif
