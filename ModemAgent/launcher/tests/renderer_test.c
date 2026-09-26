/* Run on the host: cc -std=c11 -Wall -Wextra -Werror renderer_test.c ../info-layout.c -o /tmp/launcher-renderer-test && /tmp/launcher-renderer-test */
#define LAUNCHER_FORMAT_TEST
#include "../launcher.c"
#include <assert.h>

static unsigned tests;
static struct snapshot sample(void){
 struct snapshot s={0};
 s.telemetry.valid=TELEMETRY_CPU|TELEMETRY_SIGNAL|TELEMETRY_RAT|TELEMETRY_CARRIERS|TELEMETRY_CPU_TEMP|TELEMETRY_MODEM_TEMP;
 s.telemetry.cpu_percent=27;s.telemetry.signal_dbm=-93;s.telemetry.signal_bars=3;
 snprintf(s.telemetry.signal_metric,sizeof s.telemetry.signal_metric,"RSRP");
 snprintf(s.telemetry.network_type,sizeof s.telemetry.network_type,"5G NSA");
 s.telemetry.carrier_count=3;s.telemetry.carriers_complete=1;
 snprintf(s.telemetry.carrier_bands,sizeof s.telemetry.carrier_bands,"B3 + B7 + n78");
 s.telemetry.cpu_temp_tenths=537;s.telemetry.modem_temp_tenths=492;
 return s;
}
int main(void){
 struct snapshot s={0};struct info_text out;
 char ssid[96];assert(!format_wifi_ssid(&s,0,ssid,sizeof ssid)&&!strcmp(ssid,"SSID unavailable"));tests++;
 s.valid=1;snprintf(s.ssid,sizeof s.ssid,"Existing Guest Network");assert(!format_wifi_ssid(&s,0,ssid,sizeof ssid)&&!strcmp(ssid,"Existing Guest Network"));tests++;
 snprintf(s.ssid_2g,sizeof s.ssid_2g,"Guest24");snprintf(s.ssid_5g,sizeof s.ssid_5g,"Guest5");assert(format_wifi_ssid(&s,0,ssid,sizeof ssid)&&!strcmp(ssid,"2.4G: Guest24\n5G: Guest5"));tests++;
 snprintf(s.ssid_2g,sizeof s.ssid_2g,"Actual VPN");snprintf(s.ssid_5g,sizeof s.ssid_5g,"Actual VPN");snprintf(s.ssid,sizeof s.ssid,"Actual VPN");assert(!format_wifi_ssid(&s,0,ssid,sizeof ssid)&&!strcmp(ssid,"Actual VPN"));tests++;
 memset(&s,0,sizeof s);
 format_info(&s,0,&out);
 for(int i=0;i<INFO_ROWS;i++)assert(!strcmp(out.values[i],"—"));
 assert(!strcmp(out.status,"— unavailable"));tests++;

 s=sample();format_info(&s,0,&out);
 assert(!strcmp(out.values[INFO_CPU],"27%"));assert(!strcmp(out.values[INFO_SIGNAL],"-93 dBm (RSRP)"));
 assert(!strcmp(out.values[INFO_NETWORK],"5G NSA"));assert(!strcmp(out.carrier_title,"Carriers: 3"));
 assert(!strcmp(out.values[INFO_CARRIERS],"B3 + B7 + n78"));assert(!strcmp(out.values[INFO_CPU_TEMP],"53.7 °C"));
 assert(!strcmp(out.values[INFO_MODEM_TEMP],"49.2 °C"));assert(!strcmp(out.status,"Current measurements"));tests++;

 format_info(&s,1,&out);assert(!strcmp(out.values[INFO_CPU_TEMP],"53,7 °C"));
 assert(!strcmp(out.carrier_title,"Несущие: 3"));assert(!strcmp(out.status,"Текущие показатели"));tests++;

 s.telemetry.cpu_percent=0;s.telemetry.cpu_temp_tenths=0;format_info(&s,0,&out);
 assert(!strcmp(out.values[INFO_CPU],"0%"));assert(!strcmp(out.values[INFO_CPU_TEMP],"0.0 °C"));tests++;

 s.telemetry.cpu_temp_tenths=-1;format_info(&s,0,&out);assert(!strcmp(out.values[INFO_CPU_TEMP],"−0.1 °C"));tests++;

 s=sample();s.telemetry.stale=TELEMETRY_SIGNAL|TELEMETRY_CARRIERS;format_info(&s,1,&out);
 assert(!strcmp(out.values[INFO_SIGNAL],"-93 dBm (RSRP) *"));assert(!strcmp(out.values[INFO_CPU],"27%"));
 assert(!strcmp(out.carrier_title,"Несущие: 3 *"));assert(!strcmp(out.status,"* данные устарели"));tests++;

 s.telemetry.valid=TELEMETRY_CPU;s.telemetry.stale=TELEMETRY_SIGNAL;format_info(&s,0,&out);
 assert(!strcmp(out.values[INFO_SIGNAL],"—"));assert(!strcmp(out.status,"— unavailable"));tests++;

 s=sample();s.telemetry.carriers_complete=0;format_info(&s,0,&out);
 assert(!strcmp(out.carrier_title,"Carriers: ≥3"));tests++;

 s.telemetry.carriers_complete=1;s.telemetry.carrier_count=2;
 snprintf(s.telemetry.carrier_bands,sizeof s.telemetry.carrier_bands,"B3 + B3");format_info(&s,0,&out);
 assert(!strcmp(out.carrier_title,"Carriers: 2"));assert(!strcmp(out.values[INFO_CARRIERS],"B3 + B3"));tests++;

 snprintf(s.telemetry.carrier_bands,sizeof s.telemetry.carrier_bands,"B1 + B3 + B7 + B8 + n28 + n78");format_info(&s,0,&out);
 assert(strchr(out.values[INFO_CARRIERS],'\n'));assert(!strstr(out.values[INFO_CARRIERS],"..."));tests++;

 snprintf(s.telemetry.carrier_bands,sizeof s.telemetry.carrier_bands,"n257 + n258 + n260 + n261 + B48 + B66 + n77 + n78 + n79 + B1 + B3 + B7");format_info(&s,0,&out);
 assert(strchr(out.values[INFO_CARRIERS],'\n'));assert(strstr(out.values[INFO_CARRIERS],"..."));
 assert(!strchr(strchr(out.values[INFO_CARRIERS],'\n')+1,'\n'));tests++;

 s=sample();s.telemetry.valid&=~TELEMETRY_MODEM_TEMP;s.telemetry.stale=TELEMETRY_CPU;format_info(&s,1,&out);
 assert(!strcmp(out.values[INFO_MODEM_TEMP],"—"));assert(!strcmp(out.status,"— нет данных; * устарели"));tests++;

 s=sample();snprintf(s.telemetry.signal_metric,sizeof s.telemetry.signal_metric,"BARS");s.telemetry.signal_bars=0;
 format_info(&s,0,&out);assert(!strcmp(out.values[INFO_SIGNAL],"0/5"));tests++;

 s=sample();s.telemetry.carrier_bands[0]=0;format_info(&s,1,&out);
 assert(!strcmp(out.values[INFO_CARRIERS],"Диапазоны недоступны"));
 s.telemetry.carrier_count=0;format_info(&s,0,&out);assert(!strcmp(out.values[INFO_CARRIERS],"None active"));tests++;

 s=sample();s.telemetry.valid|=TELEMETRY_MEMORY|TELEMETRY_STORAGE|TELEMETRY_UPTIME;
 s.telemetry.memory_used=284*1048576ULL;s.telemetry.memory_total=512*1048576ULL;
 s.telemetry.storage_used=1288490189ULL;s.telemetry.storage_total=3758096384ULL;s.telemetry.uptime=2*86400+3*3600+4*60+5;
 format_info(&s,1,&out);assert(!strcmp(out.values[INFO_MEMORY],"284 / 512 МиБ"));assert(!strcmp(out.values[INFO_STORAGE],"1,2 / 3,5 ГиБ"));
 assert(!strcmp(out.values[INFO_UPTIME],"2 д 03:04:05"));assert(!strcmp(info_title(INFO_MEMORY,1,0,&out),"Оперативная память"));assert(!strcmp(info_title(INFO_CARRIERS,1,0,&out),"Несущие: 3"));tests++;

 format_info(&s,0,&out);assert(!strcmp(info_title(INFO_CARRIERS,0,0,&out),"Carriers: 3"));assert(!strcmp(out.values[INFO_MEMORY],"284 / 512 MiB"));assert(!strcmp(out.values[INFO_STORAGE],"1.2 / 3.5 GiB"));assert(!strcmp(out.values[INFO_UPTIME],"2 d 03:04:05"));tests++;
 s.telemetry.memory_used=0;s.telemetry.storage_used=0;s.telemetry.uptime=0;format_info(&s,0,&out);
 assert(!strcmp(out.values[INFO_MEMORY],"0 / 512 MiB"));assert(!strcmp(out.values[INFO_STORAGE],"0.0 / 3.5 GiB"));assert(!strcmp(out.values[INFO_UPTIME],"00:00:00"));tests++;

 info_layout_default(&s.layout);for(unsigned i=0;i<INFO_ROWS;i++)s.layout.enabled[i]=i==INFO_UPTIME;
 s.telemetry.valid=TELEMETRY_UPTIME;s.telemetry.stale=TELEMETRY_CPU;format_info(&s,0,&out);
 assert(!strcmp(out.status,"Current measurements"));assert(!strcmp(out.values[INFO_UPTIME],"00:00:00"));tests++;
 s.telemetry.stale=TELEMETRY_UPTIME;format_info(&s,1,&out);assert(!strcmp(out.status,"* данные устарели"));assert(!strcmp(out.values[INFO_UPTIME],"00:00:00 *"));tests++;
 s.layout.enabled[INFO_MEMORY]=1;format_info(&s,0,&out);assert(!strcmp(out.status,"— unavailable; * stale"));tests++;

 info_layout_default(&s.layout);for(unsigned i=0;i<INFO_ROWS;i++)s.layout.enabled[i]=1;
 s.telemetry.valid=TELEMETRY_ALL;s.telemetry.stale=0;format_info(&s,0,&out);assert(!strcmp(out.status,"Current measurements"));
 s.telemetry.valid&=~TELEMETRY_STORAGE;format_info(&s,0,&out);assert(!strcmp(out.status,"— unavailable"));tests++;

 s=sample();info_layout_default(&s.layout);for(unsigned i=0;i<INFO_ROWS;i++)s.layout.enabled[i]=1;
 s.telemetry.valid=TELEMETRY_ALL;s.telemetry.battery_percent=83;s.telemetry.battery_status=BATTERY_CHARGING;
 s.telemetry.rsrq_tenths=-115;s.telemetry.sinr_tenths=156;s.telemetry.rsrq_is_nr=s.telemetry.sinr_is_nr=1;
 format_info(&s,1,&out);assert(!strcmp(out.values[INFO_BATTERY],"83% · Заряжается"));
 assert(!strcmp(out.values[INFO_RSRQ],"−11,5 dB · NR")&&!strcmp(out.values[INFO_SINR],"15,6 dB · NR"));
 assert(!strcmp(info_title(INFO_BATTERY,1,0,&out),"Батарея"));assert(!strcmp(info_title(INFO_RSRQ,1,0,&out),"Качество сигнала · RSRQ"));tests++;
 s.telemetry.sinr_tenths=0;s.telemetry.sinr_is_nr=0;format_info(&s,0,&out);assert(!strcmp(out.values[INFO_SINR],"0.0 dB · LTE"));tests++;

 s.layout.style=INFO_STYLE_TILES;s.telemetry.memory_used=284*1048576ULL;s.telemetry.memory_total=512*1048576ULL;
 s.telemetry.storage_used=1288490189ULL;s.telemetry.storage_total=3758096384ULL;s.telemetry.uptime=2*86400+3*3600+4*60+5;
 format_info(&s,1,&out);
 assert(!strcmp(out.values[INFO_SIGNAL],"-93 dBm\nRSRP"));assert(!strcmp(out.values[INFO_BATTERY],"83%\nЗаряжается"));
 assert(!strcmp(out.values[INFO_RSRQ],"−11,5 dB\nNR"));assert(!strcmp(out.values[INFO_SINR],"0,0 dB\nLTE"));
 assert(!strcmp(out.values[INFO_MEMORY],"284 / 512\nМиБ")&&!strcmp(out.values[INFO_STORAGE],"1,2 / 3,5\nГиБ"));
 assert(!strcmp(out.values[INFO_UPTIME],"2 д\n03:04:05"));assert(!strcmp(out.values[INFO_CARRIERS],"B3 + B7 + n78"));
 assert(!strcmp(info_title(INFO_CPU_TEMP,1,1,&out),"Темп. CPU")&&!strcmp(info_title(INFO_MODEM_TEMP,1,1,&out),"Темп. модема"));
 assert(!strcmp(info_title(INFO_SINR,1,1,&out),"SINR"));tests++;

 s.telemetry.stale=TELEMETRY_BATTERY|TELEMETRY_RSRQ|TELEMETRY_SINR;format_info(&s,1,&out);
 assert(!strcmp(out.values[INFO_BATTERY],"83%\nЗаряжается *"));assert(!strcmp(out.values[INFO_RSRQ],"−11,5 dB\nNR *"));
 assert(!strcmp(out.status,"* данные устарели"));tests++;
 s.telemetry.valid&=~(TELEMETRY_BATTERY|TELEMETRY_SINR);format_info(&s,0,&out);
 assert(!strcmp(out.values[INFO_BATTERY],"—")&&!strcmp(out.values[INFO_SINR],"—"));assert(!strcmp(out.status,"— unavailable; * stale"));tests++;

 s.telemetry.valid=TELEMETRY_ALL;s.telemetry.stale=0;
 snprintf(s.telemetry.carrier_bands,sizeof s.telemetry.carrier_bands,"n257 + n258 + n260 + n261 + B48 + B66 + n77 + n78 + n79 + B1 + B3 + B7");
 format_info(&s,0,&out);assert(strstr(out.values[INFO_CARRIERS],"..."));
 const char *line=out.values[INFO_CARRIERS];unsigned lines=0;
 while(*line){const char *end=strchr(line,'\n');if(!end)end=line+strlen(line);assert(end-line<=14);lines++;line=*end?end+1:end;}
 assert(lines==4);tests++;
 /* Page style affects formatting only when the complete config is valid. */
 s.layout.order[0]=255;format_info(&s,0,&out);assert(!strcmp(out.values[INFO_SIGNAL],"-93 dBm (RSRP)"));tests++;
 for(int status=BATTERY_UNKNOWN;status<=BATTERY_FULL;status++)for(int ru=0;ru<=1;ru++)assert(strlen(battery_status_text(status,ru))>0);
 assert(!strcmp(battery_status_text(999,0),"Status —"));assert(!strcmp(battery_status_text(-1,1),"Статус —"));tests++;
 for(unsigned id=0;id<INFO_ROWS;id++)for(int ru=0;ru<=1;ru++)for(int tiles=0;tiles<=1;tiles++)assert(strlen(info_title(id,ru,tiles,&out))>0);tests++;

 printf("launcher renderer: %u test groups passed\n",tests);return 0;
}
