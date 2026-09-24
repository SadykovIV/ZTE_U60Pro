#ifndef ZTE_LAUNCHER_BACKEND_H
#define ZTE_LAUNCHER_BACKEND_H
#include <pthread.h>
#include <stdint.h>
#define MAX_PROFILES 32
struct profile_summary {char id[37],name[257];int active;};
struct snapshot {int valid,enabled,running,network_ok,count,busy,error;unsigned generation;uint64_t ram_free,ram_total,disk_free,disk_total,uptime;struct profile_summary profiles[MAX_PROFILES];};
void backend_start(void);
void backend_refresh(void);
void backend_snapshot(struct snapshot *out);
int backend_action(int enable,const char *id); /* enable=-1 activates id */
#endif
