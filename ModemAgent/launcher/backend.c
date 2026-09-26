#define _GNU_SOURCE
#include "backend.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/statvfs.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
/* cJSON is exported by the exact stock executable; parsing stays in this worker. */
typedef struct cJSON cJSON;
extern cJSON *cJSON_Parse(const char *);
extern cJSON *cJSON_ParseWithOpts(const char *,const char **,int);
extern int cJSON_IsNumber(const cJSON *);
extern int cJSON_IsObject(const cJSON *);
extern char *cJSON_PrintUnformatted(const cJSON *);
extern void cJSON_free(void *);
extern void cJSON_Delete(cJSON *);
extern cJSON *cJSON_GetObjectItemCaseSensitive(const cJSON *,const char *);
extern cJSON *cJSON_GetArrayItem(const cJSON *,int);
extern int cJSON_GetArraySize(const cJSON *);
extern int cJSON_IsTrue(const cJSON *);
extern char *cJSON_GetStringValue(const cJSON *);
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static pthread_cond_t telemetry_cond=PTHREAD_COND_INITIALIZER;
static struct snapshot state;
static int pending,started,working,telemetry_pending,telemetry_working;
static char request[160];
extern char **environ;
static uint64_t monotonic_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;}
static char *call_args(char *const args[],const char *json,size_t limit,unsigned timeout_ms){
 int in[2],out[2];if(pipe2(in,O_CLOEXEC))return NULL;if(pipe2(out,O_CLOEXEC)){close(in[0]);close(in[1]);return NULL;}
 pid_t pid=fork();
 if(pid==0){prctl(PR_SET_PDEATHSIG,SIGKILL);if(getppid()==1)_exit(127);dup2(in[0],0);dup2(out[1],1);int null=open("/dev/null",O_WRONLY);if(null>=0)dup2(null,2);if(syscall(SYS_close_range,3U,~0U,0)){for(int fd=3;fd<4096;fd++)close(fd);}execve(args[0],args,environ);_exit(127);}
 close(in[0]);close(out[1]);
 if(pid<0){close(in[1]);close(out[0]);return NULL;}
 /* Request is shorter than PIPE_BUF. No URI or arbitrary command is accepted. */
 size_t len=json?strlen(json):0;ssize_t written=len?write(in[1],json,len):0;close(in[1]);
 char *buf=malloc(limit+1);size_t used=0;int failed=!buf||written!=(ssize_t)len,status=0,done=0,reaped=0;uint64_t deadline=monotonic_ms()+timeout_ms;
 fcntl(out[0],F_SETFL,O_NONBLOCK);
 while(!failed&&monotonic_ms()<deadline){
  struct pollfd p={out[0],POLLIN,0};int n=poll(&p,1,200);
  if(n<0&&errno!=EINTR){failed=1;break;}
  for(;;){if(used==limit){failed=1;break;}ssize_t r=read(out[0],buf+used,limit-used);if(r>0){used+=r;continue;}if(r==0)done=1;else if(errno!=EAGAIN&&errno!=EINTR)failed=1;break;}
  if(done){pid_t w=waitpid(pid,&status,WNOHANG);if(w==pid){reaped=1;break;}if(w<0&&errno!=EINTR){failed=1;break;}struct timespec pause={0,100000000};nanosleep(&pause,NULL);}
 }
 close(out[0]);if(!reaped){kill(pid,SIGKILL);while(waitpid(pid,&status,0)<0&&errno==EINTR){}failed=1;}
 if(failed||!done||!WIFEXITED(status)||WEXITSTATUS(status)){free(buf);return NULL;}buf[used]=0;return buf;
}
static char *call(const char *json){char *args[]={"/data/zte-vpn/vpnctl","request",NULL};return call_args(args,json,262144,220000);}
static cJSON *get(cJSON *o,const char *key){return cJSON_GetObjectItemCaseSensitive(o,key);}
static int truth(cJSON *o,const char *key){return cJSON_IsTrue(get(o,key));}
static int uuid(const char *s){if(!s||strlen(s)!=36)return 0;for(int i=0;i<36;i++){if(i==8||i==13||i==18||i==23){if(s[i]!='-')return 0;}else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;}return 1;}
static void ssid_value(char out[33],cJSON *data,const char *key){
 const char *s=cJSON_GetStringValue(get(data,key));out[0]=0;
 if(!s||strlen(s)>32)return;for(const unsigned char *p=(const unsigned char *)s;*p;p++)if(*p<32||*p==127)return;
 snprintf(out,33,"%s",s);
}
static int parse(struct snapshot *s,const char *json){
 cJSON *root=cJSON_Parse(json);if(!root)return 0;
 cJSON *data=get(root,"data"),*profiles=get(data,"profiles");int ok=truth(root,"ok")&&data&&profiles;
 if(ok){s->valid=1;s->enabled=truth(data,"enabled");s->running=truth(data,"core_running");s->network_ok=truth(data,"network_ok");s->count=0;
 ssid_value(s->ssid,data,"ssid");ssid_value(s->ssid_2g,data,"ssid_2g");ssid_value(s->ssid_5g,data,"ssid_5g");
 int count=cJSON_GetArraySize(profiles);if(count>MAX_PROFILES)count=MAX_PROFILES;
 for(int i=0;i<count;i++){cJSON *p=cJSON_GetArrayItem(profiles,i);const char *id=cJSON_GetStringValue(get(p,"id")),*name=cJSON_GetStringValue(get(p,"name"));if(!uuid(id)||!name)continue;struct profile_summary *dst=&s->profiles[s->count++];snprintf(dst->id,sizeof dst->id,"%s",id);snprintf(dst->name,sizeof dst->name,"%s",name);dst->active=truth(p,"active");}}
 cJSON_Delete(root);return ok;
}
/* This read-only sampler is independent of the long-running VPN worker. */
static int read_line(const char *path,char *out,size_t size){
 FILE *f=fopen(path,"r");if(!f)return 0;int ok=fgets(out,(int)size,f)!=NULL;fclose(f);if(!ok)return 0;
 size_t n=strlen(out);if(n==size-1&&out[n-1]!='\n')return 0;while(n&&(out[n-1]=='\n'||out[n-1]=='\r'))out[--n]=0;return 1;
}
static void system_metrics(struct modem_telemetry *out,uint64_t now){
 char text[16385];uint64_t used=0,total=0;int ok=0;
 FILE *f=fopen("/proc/meminfo","r");
 if(f){size_t n=fread(text,1,sizeof text-1,f);if(!ferror(f)&&feof(f)){text[n]=0;ok=telemetry_memory_parse(text,&used,&total);}fclose(f);}
 if(ok)telemetry_set_capacity(out,TELEMETRY_MEMORY,used,total,now);else telemetry_source_failed(out,TELEMETRY_MEMORY);
 struct statvfs st;
 if(!statvfs("/data",&st)&&st.f_frsize&&st.f_blocks&&st.f_bfree<=st.f_blocks&&(uint64_t)st.f_blocks<=UINT64_MAX/(uint64_t)st.f_frsize){
  total=(uint64_t)st.f_blocks*(uint64_t)st.f_frsize;used=((uint64_t)st.f_blocks-(uint64_t)st.f_bfree)*(uint64_t)st.f_frsize;
  telemetry_set_capacity(out,TELEMETRY_STORAGE,used,total,now);
 }else telemetry_source_failed(out,TELEMETRY_STORAGE);
 uint64_t seconds;
 if(read_line("/proc/uptime",text,128)&&telemetry_uptime_parse(text,&seconds))telemetry_set_uptime(out,seconds,now);else telemetry_source_failed(out,TELEMETRY_UPTIME);
 char capacity[64],status[64];
 if(read_line("/sys/class/power_supply/battery/capacity",capacity,sizeof capacity)&&read_line("/sys/class/power_supply/battery/status",status,sizeof status))telemetry_update_battery(out,capacity,status,now);
 else telemetry_source_failed(out,TELEMETRY_BATTERY);
}
static void thermal(struct modem_telemetry *out,uint64_t now){
 int has_cpu=0,has_modem=0,cpu=0,modem=0;
 for(int i=0;i<64;i++){
  char path[96],type[64],value[64];snprintf(path,sizeof path,"/sys/class/thermal/thermal_zone%d/type",i);
  if(!read_line(path,type,sizeof type))continue;
  int is_cpu=!strcmp(type,"cpuss-0")||!strcmp(type,"cpuss-1")||!strcmp(type,"cpuss-2")||!strcmp(type,"cpuss-3");
  int is_modem=!strcmp(type,"mdmq6-0");if(!is_cpu&&!is_modem)continue;
  snprintf(path,sizeof path,"/sys/class/thermal/thermal_zone%d/temp",i);int tenths;
  if(!read_line(path,value,sizeof value)||!telemetry_temperature(value,&tenths))continue;
  if(is_cpu&&(!has_cpu||tenths>cpu)){cpu=tenths;has_cpu=1;}
  if(is_modem){modem=tenths;has_modem=1;}
 }
 if(has_cpu)telemetry_set_number(out,TELEMETRY_CPU_TEMP,cpu,now);else telemetry_source_failed(out,TELEMETRY_CPU_TEMP);
 if(has_modem)telemetry_set_number(out,TELEMETRY_MODEM_TEMP,modem,now);else telemetry_source_failed(out,TELEMETRY_MODEM_TEMP);
}
static void radio(struct modem_telemetry *out){
 const char *paths[]={"/bin/ubus","/sbin/ubus","/usr/bin/ubus","/usr/sbin/ubus"};const char *path=NULL;
 for(unsigned i=0;i<sizeof paths/sizeof paths[0];i++)if(!access(paths[i],X_OK)){path=paths[i];break;}
 char *result=NULL;if(path){char *args[]={(char *)path,"-t","2","call","zte_nwinfo_api","nwinfo_get_netinfo","{}",NULL};result=call_args(args,NULL,65536,3000);}
 cJSON *root=result?cJSON_ParseWithOpts(result,NULL,1):NULL;
 if(!root||!cJSON_IsObject(root)){telemetry_update_radio(out,NULL,monotonic_ms());if(root)cJSON_Delete(root);free(result);return;}
 const char *keys[]={"network_type","wan_active_band","wan_active_channel","lte_pci","lte_rsrp","lte_rssi","nr5g_action_band","nr5g_action_channel","nr5g_pci","nr5g_rsrp","rscp","rssi","signalbar","lteca","ltecasig","nrca","lte_rsrq","lte_snr","nr5g_rsrq","nr5g_snr"};
 const char *values[20]={0};char *owned[20]={0};
 for(int i=0;i<20;i++){
  cJSON *item=get(root,keys[i]);const char *value=cJSON_GetStringValue(item);
  if(value&&strlen(value)<=4096)values[i]=value;
  else if(cJSON_IsNumber(item)){owned[i]=cJSON_PrintUnformatted(item);if(owned[i]&&strlen(owned[i])<=63)values[i]=owned[i];}
 }
 struct telemetry_radio_fields fields={values[0],values[1],values[2],values[3],values[4],values[5],values[6],values[7],values[8],values[9],values[10],values[11],values[12],values[13],values[14],values[15],values[16],values[17],values[18],values[19]};
 telemetry_update_radio(out,&fields,monotonic_ms());
 for(int i=0;i<20;i++)if(owned[i])cJSON_free(owned[i]);cJSON_Delete(root);free(result);
}
static void *telemetry_worker(void *unused){
 (void)unused;struct modem_telemetry metrics={0};struct telemetry_cpu_sample previous={0};
 char line[512];if(read_line("/proc/stat",line,sizeof line))telemetry_cpu_parse(line,monotonic_ms(),&previous);
 for(;;){
  pthread_mutex_lock(&mutex);while(!telemetry_pending)pthread_cond_wait(&telemetry_cond,&mutex);telemetry_pending=0;telemetry_working=1;pthread_mutex_unlock(&mutex);
  struct info_layout layout;info_layout_read(&layout);
  system_metrics(&metrics,monotonic_ms());radio(&metrics);uint64_t now=monotonic_ms();
  struct telemetry_cpu_sample sample={0};int percent;
  if(read_line("/proc/stat",line,sizeof line))telemetry_cpu_parse(line,now,&sample);
  if(telemetry_cpu_percent(&previous,&sample,&percent))telemetry_set_number(&metrics,TELEMETRY_CPU,percent,now);else telemetry_source_failed(&metrics,TELEMETRY_CPU);
  thermal(&metrics,now);telemetry_expire(&metrics,monotonic_ms());
  pthread_mutex_lock(&mutex);state.telemetry=metrics;state.layout=layout;state.generation++;telemetry_working=0;pthread_mutex_unlock(&mutex);
 }
 return NULL;
}
static void *worker(void *unused){(void)unused;
 /* Never let an early helper exit deliver SIGPIPE to the stock launcher. */
 sigset_t blocked;sigemptyset(&blocked);sigaddset(&blocked,SIGPIPE);pthread_sigmask(SIG_BLOCK,&blocked,NULL);
 for(;;){pthread_mutex_lock(&mutex);while(!pending)pthread_cond_wait(&cond,&mutex);int action=pending;char cmd[160];memcpy(cmd,request,sizeof cmd);pending=0;working=1;struct snapshot next=state;pthread_mutex_unlock(&mutex);
 char *result=call(action==2?cmd:"{\"action\":\"status\"}");int ok=result&&parse(&next,result);free(result);
 pthread_mutex_lock(&mutex);next.error=!ok;next.busy=0;next.generation=state.generation+1;next.telemetry=state.telemetry;next.layout=state.layout;if(action==2||!state.busy)state=next;working=0;pthread_mutex_unlock(&mutex);
 }
 return NULL;
}
void backend_start(void){if(started)return;pthread_t thread;if(!pthread_create(&thread,NULL,worker,NULL)){pthread_detach(thread);started=1;backend_refresh();if(!pthread_create(&thread,NULL,telemetry_worker,NULL))pthread_detach(thread);}}
void backend_refresh(void){pthread_mutex_lock(&mutex);if(!telemetry_pending&&!telemetry_working){telemetry_pending=1;pthread_cond_signal(&telemetry_cond);}if(!pending&&!working&&!state.busy){pending=1;pthread_cond_signal(&cond);}pthread_mutex_unlock(&mutex);}
void backend_snapshot(struct snapshot *out){pthread_mutex_lock(&mutex);*out=state;pthread_mutex_unlock(&mutex);telemetry_expire(&out->telemetry,monotonic_ms());}
int backend_action(int enable,const char *id){
 if(enable<0&&!uuid(id))return 0;
 pthread_mutex_lock(&mutex);if(!started||state.busy||pending==2){pthread_mutex_unlock(&mutex);return 0;}
 if(enable<0)snprintf(request,sizeof request,"{\"action\":\"activate\",\"id\":\"%s\"}",id);
 else snprintf(request,sizeof request,"{\"action\":\"set_enabled\",\"enabled\":%s}",enable?"true":"false");
 state.busy=1;state.error=0;state.generation++;pending=2;pthread_cond_signal(&cond);pthread_mutex_unlock(&mutex);return 1;
}
