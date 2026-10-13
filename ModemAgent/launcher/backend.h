#ifndef ZTE_LAUNCHER_BACKEND_H
#define ZTE_LAUNCHER_BACKEND_H
#include <pthread.h>
#include <stdint.h>
#include "telemetry.h"
#include "info-layout.h"
#define MAX_PROFILES 1024
#define MAX_SUBSCRIPTIONS 1024
struct profile_summary {char id[37],name[257];int active,insecure_tls;};
struct subscription_update {int total,done,succeeded,running,complete;char first_error[64];};
struct snapshot {int valid,enabled,running,network_ok,count,busy,error;unsigned generation;char error_code[64],operation_error[64];char ssid[33],ssid_2g[33],ssid_5g[33];struct profile_summary profiles[MAX_PROFILES];int subscription_count;char subscriptions[MAX_SUBSCRIPTIONS][37];struct subscription_update subscription_update;struct modem_telemetry telemetry;struct info_layout layout;};
int backend_update_subscriptions(void);
void backend_start(void);
void backend_refresh(void);
void backend_snapshot(struct snapshot *out);
int backend_action(int enable,const char *id); /* enable=-1 activates id */
#endif
