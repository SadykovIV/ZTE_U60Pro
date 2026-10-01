#ifndef ZTE_LAUNCHER_ESIM_H
#define ZTE_LAUNCHER_ESIM_H
#define ESIM_MAX_PROFILES 1024
struct esim_profile {char iccid[21],name[129];int enabled;};
struct esim_snapshot {int valid,cached,count,busy,error,verified,mutation_failed;unsigned generation;char stage[40],error_code[64],component_error[64];struct esim_profile profiles[ESIM_MAX_PROFILES];};
/* A private canonical snapshot is retained for the agent's compare-before-write. */
int esim_parse_result(const char *line,struct esim_snapshot *out,char **canonical,int require_verified);
int esim_parse_error(const char *line,char error[64],char component[64]);
int esim_parse_progress(const char *line,char stage[40]);
void esim_start(void);
void esim_refresh(void);
void esim_poll(void);
void esim_snapshot(struct esim_snapshot *out);
int esim_enable(const char *iccid,unsigned generation);
#endif
