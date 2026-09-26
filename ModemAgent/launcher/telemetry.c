#include "telemetry.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <ctype.h>
#include <limits.h>
#include <math.h>

static int number(const char *s,double min,double max,double *value){
 if(!s||!*s||strlen(s)>63)return 0;
 char *end;errno=0;double n=strtod(s,&end);
 while(isspace((unsigned char)*end))end++;
 if(errno||end==s||*end||!isfinite(n)||n<min||n>max)return 0;
 *value=n;return 1;
}
static int integer(const char *s,int min,int max,int *value){double n;if(!number(s,min,max,&n)||n!=(int)n)return 0;*value=(int)n;return 1;}
static int bit_index(unsigned field){for(int i=0;i<TELEMETRY_FIELDS;i++)if(field==(1U<<i))return i;return -1;}
static void updated(struct modem_telemetry *out,unsigned field,uint64_t now){int i=bit_index(field);if(i<0)return;out->valid|=field;out->stale&=~field;out->updated_ms[i]=now;}
void telemetry_source_failed(struct modem_telemetry *out,unsigned fields){out->stale|=out->valid&fields;}
void telemetry_expire(struct modem_telemetry *out,uint64_t now){
 for(int i=0;i<TELEMETRY_FIELDS;i++)if((out->valid&(1U<<i))&&(now<out->updated_ms[i]||now-out->updated_ms[i]>TELEMETRY_MAX_AGE_MS))out->stale|=1U<<i;
}
int telemetry_set_capacity(struct modem_telemetry *out,unsigned field,uint64_t used,uint64_t total,uint64_t now){
 if(field!=TELEMETRY_MEMORY&&field!=TELEMETRY_STORAGE)return 0;
 if(!total||used>total){telemetry_source_failed(out,field);return 0;}
 if(field==TELEMETRY_MEMORY){out->memory_used=used;out->memory_total=total;}
 else{out->storage_used=used;out->storage_total=total;}
 updated(out,field,now);return 1;
}
void telemetry_set_uptime(struct modem_telemetry *out,uint64_t seconds,uint64_t now){out->uptime=seconds;updated(out,TELEMETRY_UPTIME,now);}
int telemetry_update_battery(struct modem_telemetry *out,const char *capacity,const char *status,uint64_t now){
 int percent,state=-1;telemetry_source_failed(out,TELEMETRY_BATTERY);
 if(!integer(capacity,0,100,&percent)||!status)return 0;
 if(!strcmp(status,"Charging"))state=BATTERY_CHARGING;
 else if(!strcmp(status,"Discharging"))state=BATTERY_DISCHARGING;
 else if(!strcmp(status,"Not charging"))state=BATTERY_NOT_CHARGING;
 else if(!strcmp(status,"Full"))state=BATTERY_FULL;
 else if(!strcmp(status,"Unknown"))state=BATTERY_UNKNOWN;
 if(state<0)return 0;
 out->battery_percent=percent;out->battery_status=state;updated(out,TELEMETRY_BATTERY,now);return 1;
}
int telemetry_memory_parse(const char *meminfo,uint64_t *used,uint64_t *total){
 if(!meminfo||strlen(meminfo)>16384)return 0;
 uint64_t found_total=0,available=0;unsigned seen=0;
 for(const char *line=meminfo;*line;){
  const char *end=strchr(line,'\n');if(!end)end=line+strlen(line);
  unsigned key=0;size_t prefix=0;
  if((size_t)(end-line)>=9&&!memcmp(line,"MemTotal:",9)){key=1;prefix=9;}
  else if((size_t)(end-line)>=13&&!memcmp(line,"MemAvailable:",13)){key=2;prefix=13;}
  if(key){
   if(seen&key)return 0;const char *p=line+prefix;while(p<end&&(*p==' '||*p=='\t'))p++;
   if(p==end||!isdigit((unsigned char)*p))return 0;
   errno=0;char *tail;unsigned long long value=strtoull(p,&tail,10);
   if(errno||tail==p||value>UINT64_MAX/1024||tail==end||(*tail!=' '&&*tail!='\t'))return 0;
   p=tail;while(p<end&&(*p==' '||*p=='\t'))p++;
   if(end-p!=2||memcmp(p,"kB",2))return 0;
   if(key==1)found_total=(uint64_t)value*1024;else available=(uint64_t)value*1024;seen|=key;
  }
  line=*end?end+1:end;
 }
 if(seen!=3||!found_total||available>found_total)return 0;
 *total=found_total;*used=found_total-available;return 1;
}
int telemetry_uptime_parse(const char *line,uint64_t *seconds){
 if(!line||!*line||strlen(line)>127||!isdigit((unsigned char)*line))return 0;
 errno=0;char *end;double value=strtod(line,&end);
 if(errno||!isfinite(value)||value<0||value>1e12||!isspace((unsigned char)*end))return 0;
 while(isspace((unsigned char)*end))end++;if(!isdigit((unsigned char)*end))return 0;
 errno=0;char *tail;double idle=strtod(end,&tail);
 if(errno||!isfinite(idle)||idle<0)return 0;while(isspace((unsigned char)*tail))tail++;if(*tail)return 0;
 *seconds=(uint64_t)value;return 1;
}
void telemetry_set_number(struct modem_telemetry *out,unsigned field,int value,uint64_t now){
 switch(field){case TELEMETRY_CPU:out->cpu_percent=value;break;case TELEMETRY_CPU_TEMP:out->cpu_temp_tenths=value;break;case TELEMETRY_MODEM_TEMP:out->modem_temp_tenths=value;break;default:return;}updated(out,field,now);
}
int telemetry_cpu_parse(const char *line,uint64_t now,struct telemetry_cpu_sample *out){
 memset(out,0,sizeof *out);if(!line||strncmp(line,"cpu ",4))return 0;
 uint64_t ticks[10]={0};int count=0;const char *p=line+4;
 while(*p&&*p!='\n'){
  while(*p==' '||*p=='\t')p++;if(!*p||*p=='\n')break;
  if(count==10||!isdigit((unsigned char)*p))return 0;
  errno=0;char *end;unsigned long long value=strtoull(p,&end,10);
  if(errno||end==p||(*end&&!isspace((unsigned char)*end)))return 0;
  ticks[count++]=(uint64_t)value;p=end;
 }
 if(count<4)return 0;
 /* Linux guest/guest_nice are already included in user/nice. */
 uint64_t total=0;for(int i=0;i<count&&i<8;i++){if(UINT64_MAX-total<ticks[i])return 0;total+=ticks[i];}
 if(UINT64_MAX-ticks[3]<ticks[4])return 0;
 out->total=total;out->idle=ticks[3]+ticks[4];out->sampled_ms=now;out->valid=1;return 1;
}
int telemetry_cpu_percent(struct telemetry_cpu_sample *previous,const struct telemetry_cpu_sample *current,int *percent){
 if(!current->valid){previous->valid=0;return 0;}
 struct telemetry_cpu_sample old=*previous;*previous=*current;
 if(!old.valid||current->sampled_ms<=old.sampled_ms||current->sampled_ms-old.sampled_ms<250||current->sampled_ms-old.sampled_ms>TELEMETRY_MAX_AGE_MS||current->total<=old.total||current->idle<old.idle)return 0;
 uint64_t total=current->total-old.total,idle=current->idle-old.idle;if(idle>total)return 0;
 *percent=(int)(100.0*(double)(total-idle)/(double)total+0.5);return 1;
}
int telemetry_temperature(const char *s,int *tenths){int milli;if(!integer(s,-39999,149999,&milli))return 0;*tenths=milli/100;return 1;}
static int band(const char *s,int nr,int *out){
 if(!s)return 0;
 const char *p=s;while(isspace((unsigned char)*p))p++;
 const char *prefix=nr?"NR5G BAND ":"LTE BAND ";if(!strncmp(p,prefix,strlen(prefix)))p+=strlen(prefix);
 else if(*p==(nr?'n':'B')||*p==(nr?'N':'b'))p++;
 return integer(p,1,nr?1024:256,out);
}
struct carrier {int nr,band,pci,channel;};
static void add_carrier(struct carrier *list,int *count,int nr,int b,int pci,int channel,int *complete){
 for(int i=0;i<*count;i++)if(list[i].nr==nr&&list[i].pci==pci&&list[i].channel==channel)return;
 if(*count>=16){*complete=0;return;}list[*count]=(struct carrier){nr,b,pci,channel};(*count)++;
}
/* CSV/semicolon fields are bounded before copying and reject empty columns. */
static int split(char *s,char delimiter,char **parts,int max){
 int count=0;char *p=s;for(;;){if(count==max)return -1;parts[count++]=p;char *end=strchr(p,delimiter);if(!end)break;*end=0;p=end+1;}return count;
}
static int serving(const char *b,const char *pci,const char *channel,const char *rsrp,int nr,struct carrier *out){
 int bn,pn,cn;double rn;
 if(!band(b,nr,&bn)||!integer(pci,0,nr?1007:503,&pn)||!integer(channel,1,nr?3279165:262143,&cn)||!number(rsrp,-160,-20,&rn))return 0;
 *out=(struct carrier){nr,bn,pn,cn};return 1;
}
static void lte_carriers(const struct telemetry_radio_fields *f,const struct carrier *primary,struct carrier *list,int *count,int *complete){
 if(!f->lteca||strlen(f->lteca)>4096||!f->ltecasig||strlen(f->ltecasig)>4096){*complete=0;return;}
 char ca[4097],sig[4097];snprintf(ca,sizeof ca,"%s",f->lteca);snprintf(sig,sizeof sig,"%s",f->ltecasig);
 char *segments[33],*signals[33];int n=split(ca,';',segments,33),sn=split(sig,';',signals,33),secondary=0;
 if(n<0||sn<0){*complete=0;return;}
 for(int i=0;i<n;i++){
  if(!segments[i][0]){if(i<n-1){*complete=0;break;}continue;}
  char *parts[16];int fields=split(segments[i],',',parts,16),b,pci,channel;
  if(fields<5||!band(parts[1],0,&b)||!integer(parts[0],0,503,&pci)||!integer(parts[3],1,262143,&channel)){*complete=0;break;}
  if(primary->pci==pci&&primary->channel==channel)continue;
  if(secondary>=sn||!signals[secondary][0]){*complete=0;secondary++;continue;}
  char *sp[12];int sf=split(signals[secondary++],',',sp,12),active;
  if(sf<6||!integer(sp[5],0,2,&active)){*complete=0;continue;}
  if(active==2)add_carrier(list,count,0,b,pci,channel,complete);
 }
 /* Unknown extra signal rows invalidate an exact count; never guess alignment. */
 for(int i=secondary;i<sn;i++)if(signals[i][0])*complete=0;
}
static void nr_carriers(const struct telemetry_radio_fields *f,const struct carrier *primary,struct carrier *list,int *count,int *complete){
 if(!f->nrca||strlen(f->nrca)>4096){*complete=0;return;}
 char ca[4097];snprintf(ca,sizeof ca,"%s",f->nrca);char *segments[33];int n=split(ca,';',segments,33);
 if(n<0){*complete=0;return;}
 for(int i=0;i<n;i++){
  if(!segments[i][0]){if(i<n-1)*complete=0;continue;}
  char *parts[16];int fields=split(segments[i],',',parts,16),b,pci,channel,active;
  if(fields<6||!band(parts[3],1,&b)||!integer(parts[1],0,1007,&pci)||!integer(parts[4],1,3279165,&channel)||!integer(parts[2],0,2,&active)){*complete=0;continue;}
  if(primary->pci==pci&&primary->channel==channel)continue;
  if(active==2)add_carrier(list,count,1,b,pci,channel,complete);
 }
}
/* Values are a closed display vocabulary, never raw firmware strings. */
static int rat(const char *raw,char *name,size_t size,int *lte,int *nr){
 *lte=*nr=0;if(!raw)return 0;const char *value=NULL;
 if(!strcmp(raw,"LTE")){value="LTE";*lte=1;}
 else if(!strcmp(raw,"LTE-NSA")||!strcmp(raw,"5G NSA")||!strcmp(raw,"NR5G-NSA")){value="5G NSA";*lte=*nr=1;}
 else if(!strcmp(raw,"NR5G-SA")||!strcmp(raw,"5G SA")){value="5G SA";*nr=1;}
 else if(!strcmp(raw,"NR5G")||!strcmp(raw,"5G")){value="5G";*nr=1;}
 else if(!strcmp(raw,"UMTS")||!strcmp(raw,"WCDMA")||!strcmp(raw,"HSDPA")||!strcmp(raw,"HSUPA")||!strcmp(raw,"HSPA")||!strcmp(raw,"HSPA+")||!strcmp(raw,"3G"))value="3G";
 else if(!strcmp(raw,"GSM")||!strcmp(raw,"GPRS")||!strcmp(raw,"EDGE")||!strcmp(raw,"2G"))value="2G";
 else if(!strcmp(raw,"NO SERVICE")||!strcmp(raw,"NO_SERVICE")||!strcmp(raw,"NO NETWORK"))value="No service";
 if(!value)return 0;snprintf(name,size,"%s",value);return 1;
}
void telemetry_update_radio(struct modem_telemetry *out,const struct telemetry_radio_fields *f,uint64_t now){
 unsigned fields=TELEMETRY_SIGNAL|TELEMETRY_RAT|TELEMETRY_CARRIERS|TELEMETRY_RSRQ|TELEMETRY_SINR;telemetry_source_failed(out,fields);if(!f)return;
 int lte,nr;char network[24];if(!rat(f->network_type,network,sizeof network,&lte,&nr))return;
 struct carrier lp,np,list[16];int has_lte=lte&&serving(f->wan_active_band,f->lte_pci,f->wan_active_channel,f->lte_rsrp,0,&lp);
 int has_nr=nr&&serving(f->nr5g_action_band,f->nr5g_pci,f->nr5g_action_channel,f->nr5g_rsrp,1,&np);
 if(lte&&nr&&!has_nr)snprintf(network,sizeof network,"LTE (NSA)");
 snprintf(out->network_type,sizeof out->network_type,"%s",network);updated(out,TELEMETRY_RAT,now);
 double strength=0;const char *metric=NULL;
 if(has_nr&&number(f->nr5g_rsrp,-160,-20,&strength))metric="RSRP";
 else if(has_lte&&number(f->lte_rsrp,-160,-20,&strength))metric="RSRP";
 else if(!strcmp(network,"3G")&&number(f->rscp,-140,-20,&strength))metric="RSCP";
 else if(!strcmp(network,"2G")&&number(f->rssi,-130,-20,&strength))metric="RSSI";
 int bars;
 if(metric){out->signal_dbm=(int)(strength+(strength<0?-0.5:0.5));out->signal_bars=-1;snprintf(out->signal_metric,sizeof out->signal_metric,"%s",metric);updated(out,TELEMETRY_SIGNAL,now);}
 else if(strcmp(network,"No service")&&integer(f->signalbar,0,5,&bars)){out->signal_bars=bars;out->signal_dbm=0;snprintf(out->signal_metric,sizeof out->signal_metric,"BARS");updated(out,TELEMETRY_SIGNAL,now);}
 /* B31 nwinfo_get_netinfo exposes direct dB, not scaled integer units:
  * lte_rsrq/lte_snr and nr5g_rsrq/nr5g_snr. Only a validated serving cell
  * makes a numeric zero meaningful. In NSA use NR when it is truly active;
  * otherwise use the LTE anchor, and display that source beside the value. */
 if(has_nr||has_lte){
  double quality;
  if(number(has_nr?f->nr5g_rsrq:f->lte_rsrq,-50,20,&quality)){
   out->rsrq_tenths=(int)(quality*10+(quality<0?-0.5:0.5));out->rsrq_is_nr=has_nr;updated(out,TELEMETRY_RSRQ,now);
  }
  if(number(has_nr?f->nr5g_snr:f->lte_snr,-30,50,&quality)){
   out->sinr_tenths=(int)(quality*10+(quality<0?-0.5:0.5));out->sinr_is_nr=has_nr;updated(out,TELEMETRY_SINR,now);
  }
 }
 /* Generic 5G does not prove SA or rule out an LTE anchor. */
 int count=0,complete=strcmp(network,"5G")!=0;
 if(has_lte){add_carrier(list,&count,0,lp.band,lp.pci,lp.channel,&complete);lte_carriers(f,&lp,list,&count,&complete);}
 if(has_nr){add_carrier(list,&count,1,np.band,np.pci,np.channel,&complete);nr_carriers(f,&np,list,&count,&complete);}
 if((lte&&!has_lte)||(nr&&!has_nr&&strcmp(network,"LTE (NSA)")))complete=0;
 if(count){
  out->carrier_count=(unsigned)count;out->carriers_complete=complete;out->carrier_bands[0]=0;size_t used=0;
  for(int i=0;i<count;i++){int n=snprintf(out->carrier_bands+used,sizeof out->carrier_bands-used,"%s%c%d",i?" + ":"",list[i].nr?'n':'B',list[i].band);if(n<0||(size_t)n>=sizeof out->carrier_bands-used){out->carriers_complete=0;break;}used+=(size_t)n;}
  updated(out,TELEMETRY_CARRIERS,now);
 }else if(!strcmp(network,"No service")){out->carrier_count=0;out->carriers_complete=1;out->carrier_bands[0]=0;updated(out,TELEMETRY_CARRIERS,now);}
}
