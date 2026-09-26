#ifndef ZTE_LAUNCHER_TELEMETRY_H
#define ZTE_LAUNCHER_TELEMETRY_H
#include <stdint.h>
#define TELEMETRY_CPU (1U << 0)
#define TELEMETRY_SIGNAL (1U << 1)
#define TELEMETRY_RAT (1U << 2)
#define TELEMETRY_CARRIERS (1U << 3)
#define TELEMETRY_CPU_TEMP (1U << 4)
#define TELEMETRY_MODEM_TEMP (1U << 5)
#define TELEMETRY_MEMORY (1U << 6)
#define TELEMETRY_STORAGE (1U << 7)
#define TELEMETRY_UPTIME (1U << 8)
#define TELEMETRY_BATTERY (1U << 9)
#define TELEMETRY_RSRQ (1U << 10)
#define TELEMETRY_SINR (1U << 11)
#define TELEMETRY_FIELDS 12
#define TELEMETRY_ALL ((1U << TELEMETRY_FIELDS) - 1)
#define TELEMETRY_MAX_AGE_MS 12000U
enum telemetry_battery_status { BATTERY_UNKNOWN, BATTERY_CHARGING, BATTERY_DISCHARGING, BATTERY_NOT_CHARGING, BATTERY_FULL };
struct modem_telemetry {
 unsigned valid,stale;
 int cpu_percent,signal_dbm,signal_bars;
 char signal_metric[8],network_type[24];
 unsigned carrier_count;
 int carriers_complete;
 char carrier_bands[128];
 int cpu_temp_tenths,modem_temp_tenths;
 uint64_t memory_used,memory_total,storage_used,storage_total,uptime;
 int battery_percent,battery_status,rsrq_tenths,sinr_tenths,rsrq_is_nr,sinr_is_nr;
 uint64_t updated_ms[TELEMETRY_FIELDS];
};
struct telemetry_cpu_sample {uint64_t total,idle,sampled_ms;int valid;};
/* Only current serving-cell / CA fields belong here, never configured band lists. */
struct telemetry_radio_fields {
 const char *network_type,*wan_active_band,*wan_active_channel,*lte_pci,*lte_rsrp,*lte_rssi;
 const char *nr5g_action_band,*nr5g_action_channel,*nr5g_pci,*nr5g_rsrp;
 const char *rscp,*rssi,*signalbar,*lteca,*ltecasig,*nrca;
 const char *lte_rsrq,*lte_snr,*nr5g_rsrq,*nr5g_snr;
};
int telemetry_cpu_parse(const char *line,uint64_t now_ms,struct telemetry_cpu_sample *out);
int telemetry_cpu_percent(struct telemetry_cpu_sample *previous,const struct telemetry_cpu_sample *current,int *percent);
int telemetry_temperature(const char *millidegrees,int *tenths);
int telemetry_memory_parse(const char *meminfo,uint64_t *used,uint64_t *total);
int telemetry_uptime_parse(const char *line,uint64_t *seconds);
int telemetry_set_capacity(struct modem_telemetry *out,unsigned field,uint64_t used,uint64_t total,uint64_t now_ms);
void telemetry_set_uptime(struct modem_telemetry *out,uint64_t seconds,uint64_t now_ms);
/* Read sysfs capacity/status together; a real zero remains a valid value. */
int telemetry_update_battery(struct modem_telemetry *out,const char *capacity,const char *status,uint64_t now_ms);
/* A failed source retains last data, but marks it stale immediately. */
void telemetry_update_radio(struct modem_telemetry *out,const struct telemetry_radio_fields *fields,uint64_t now_ms);
void telemetry_set_number(struct modem_telemetry *out,unsigned field,int value,uint64_t now_ms);
void telemetry_source_failed(struct modem_telemetry *out,unsigned fields);
void telemetry_expire(struct modem_telemetry *out,uint64_t now_ms);
#endif
