#ifndef ZTE_LAUNCHER_BACKEND_H
#define ZTE_LAUNCHER_BACKEND_H
#include <pthread.h>
#include <stdint.h>
#include "telemetry.h"
#include "info-layout.h"
#define MAX_PROFILES 32
struct profile_summary {char id[37],name[257];int active;};
struct snapshot {int valid,enabled,running,network_ok,count,busy,error;unsigned generation;char error_code[64],operation_error[64];char ssid[33],ssid_2g[33],ssid_5g[33];struct profile_summary profiles[MAX_PROFILES];struct modem_telemetry telemetry;struct info_layout layout;};
void backend_start(void);
void backend_refresh(void);
void backend_snapshot(struct snapshot *out);
int backend_action(int enable,const char *id); /* enable=-1 activates id */
#endif
