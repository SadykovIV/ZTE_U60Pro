#define _GNU_SOURCE
#include "backend.h"
#include "vpn-process.h"
#include "vpn-model.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/statvfs.h>
#include <sys/stat.h>
#include <syslog.h>
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
static int uuid(const char *s){if(!s||strlen(s)!=36)return 0;for(int i=0;i<36;i++){if(i==8||i==13||i==18||i==23){if(s[i]!='-')return 0;}else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;}return 1;}
/* Fixed metadata only. Never copy protocol JSON, profile ids, names or SSIDs. */
static void vpn_diagnostic(int action,int ok,const char *code,const struct vpn_process_result *r){
 char text[512];snprintf(text,sizeof text,"operation=%s ok=%d code=%s status_valid=%d exit=%d proof_valid=%d timed_out=%d cleanup_complete=%d read_errno=%d write_errno=%d wait_errno=%d\n",action==2?"change":"status",ok,code?code:"none",r->status_valid,r->status_valid&&WIFEXITED(r->exit_status)?WEXITSTATUS(r->exit_status):-1,r->proof_valid,r->timed_out,r->cleanup_complete,r->read_errno,r->write_errno,r->wait_errno);
 if(!ok)syslog(LOG_USER|LOG_WARNING,"zte-launcher VPN: %s",text);
 int dir=open("/tmp/zte-launcher",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
 if(dir<0)return;if(fstat(dir,&st)||st.st_uid||(st.st_mode&0777)!=0700){close(dir);return;}
 const char *names[]={"vpn-status","vpn-error","vpn-last-change"};
 for(int i=0;i<3;i++){
  if((i==1&&ok)||(i==2&&action!=2))continue;
  int fd=openat(dir,names[i],O_WRONLY|O_CREAT|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0)continue;
  if(!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==0&&(st.st_mode&07777)==0600&&st.st_nlink==1){if(!ftruncate(fd,0)){size_t used=0,n=strlen(text);while(used<n){ssize_t k=write(fd,text+used,n-used);if(k<0&&errno==EINTR)continue;if(k<=0)break;used+=(size_t)k;}}}close(fd);
 }close(dir);
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
  cJSON *item=cJSON_GetObjectItemCaseSensitive(root,keys[i]);const char *value=cJSON_GetStringValue(item);
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
 const char *input=action==2?cmd:"{\"action\":\"status\"}";char *args[]={"/data/zte-vpn/vpnctl","request",NULL};struct vpn_process_result process={0};
 int transport=vpn_process_run(args,input,strlen(input),220000,&process);
 int exited=transport&&process.status_valid&&WIFEXITED(process.exit_status),success=exited&&WEXITSTATUS(process.exit_status)==0;
 int text_valid=process.output&&strlen(process.output)==process.output_length;
 int ok=success&&text_valid&&vpn_parse_status(&next,process.output);
 const char *code=NULL;if(!ok){code=exited&&WEXITSTATUS(process.exit_status)==1&&text_valid?vpn_error_code(process.output):NULL;if(!code)code=success?"VPN_INVALID_STATUS":"VPN_RESULT_UNKNOWN";}
 vpn_diagnostic(action,ok,code,&process);vpn_process_free(&process);
 if(action==2){snprintf(next.operation_error,sizeof next.operation_error,"%s",ok?"":code);next.error_code[0]=0;if(!ok)next.valid=0;}
 else {snprintf(next.error_code,sizeof next.error_code,"%s",ok?"":code);if(!ok)next.valid=0;}
 pthread_mutex_lock(&mutex);next.error=next.error_code[0]||next.operation_error[0];next.busy=0;next.generation=state.generation+1;next.telemetry=state.telemetry;next.layout=state.layout;if(action==2||!state.busy)state=next;working=0;pthread_mutex_unlock(&mutex);
 }
 return NULL;
}
void backend_start(void){if(started)return;pthread_t thread;if(!pthread_create(&thread,NULL,worker,NULL)){pthread_detach(thread);started=1;backend_refresh();if(!pthread_create(&thread,NULL,telemetry_worker,NULL))pthread_detach(thread);}}
void backend_refresh(void){pthread_mutex_lock(&mutex);if(!telemetry_pending&&!telemetry_working){telemetry_pending=1;pthread_cond_signal(&telemetry_cond);}if(!pending&&!working&&!state.busy){pending=1;pthread_cond_signal(&cond);}pthread_mutex_unlock(&mutex);}
void backend_snapshot(struct snapshot *out){pthread_mutex_lock(&mutex);*out=state;pthread_mutex_unlock(&mutex);telemetry_expire(&out->telemetry,monotonic_ms());}
int backend_action(int enable,const char *id){
 if(enable<0&&!uuid(id))return 0;
 pthread_mutex_lock(&mutex);if(!started||!state.valid||state.busy||pending==2){pthread_mutex_unlock(&mutex);return 0;}
 if(enable<0)snprintf(request,sizeof request,"{\"action\":\"activate\",\"id\":\"%s\"}",id);
 else snprintf(request,sizeof request,"{\"action\":\"set_enabled\",\"enabled\":%s}",enable?"true":"false");
 state.busy=1;state.error=0;state.error_code[0]=0;state.operation_error[0]=0;state.generation++;pending=2;pthread_cond_signal(&cond);pthread_mutex_unlock(&mutex);return 1;
}
