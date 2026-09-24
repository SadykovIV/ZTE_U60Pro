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
extern void cJSON_Delete(cJSON *);
extern cJSON *cJSON_GetObjectItemCaseSensitive(const cJSON *,const char *);
extern cJSON *cJSON_GetArrayItem(const cJSON *,int);
extern int cJSON_GetArraySize(const cJSON *);
extern int cJSON_IsTrue(const cJSON *);
extern char *cJSON_GetStringValue(const cJSON *);
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static struct snapshot state;
static int pending,started,working;
static char request[160];
extern char **environ;
static long monotonic(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec;}
static char *call(const char *json){
 int in[2],out[2];if(pipe2(in,O_CLOEXEC))return NULL;if(pipe2(out,O_CLOEXEC)){close(in[0]);close(in[1]);return NULL;}
 pid_t pid=fork();
 if(pid==0){prctl(PR_SET_PDEATHSIG,SIGKILL);if(getppid()==1)_exit(127);dup2(in[0],0);dup2(out[1],1);int null=open("/dev/null",O_WRONLY);if(null>=0)dup2(null,2);if(syscall(SYS_close_range,3U,~0U,0)){for(int fd=3;fd<4096;fd++)close(fd);}char *args[]={"/data/zte-vpn/vpnctl","request",NULL};execve(args[0],args,environ);_exit(127);}
 close(in[0]);close(out[1]);
 if(pid<0){close(in[1]);close(out[0]);return NULL;}
 /* Request is shorter than PIPE_BUF. No URI or arbitrary command is accepted. */
 size_t len=strlen(json);ssize_t written=write(in[1],json,len);close(in[1]);
 char *buf=malloc(262145);size_t used=0;int failed=!buf||written!=(ssize_t)len,status=0,done=0,reaped=0;long deadline=monotonic()+220;
 fcntl(out[0],F_SETFL,O_NONBLOCK);
 while(!failed&&monotonic()<deadline){
  struct pollfd p={out[0],POLLIN,0};int n=poll(&p,1,200);
  if(n<0&&errno!=EINTR){failed=1;break;}
  for(;;){if(used==262144){failed=1;break;}ssize_t r=read(out[0],buf+used,262144-used);if(r>0){used+=r;continue;}if(r==0)done=1;else if(errno!=EAGAIN&&errno!=EINTR)failed=1;break;}
  if(done){pid_t w=waitpid(pid,&status,WNOHANG);if(w==pid){reaped=1;break;}if(w<0&&errno!=EINTR){failed=1;break;}struct timespec pause={0,100000000};nanosleep(&pause,NULL);}
 }
 close(out[0]);if(!reaped){kill(pid,SIGKILL);while(waitpid(pid,&status,0)<0&&errno==EINTR){}failed=1;}
 if(failed||!done||!WIFEXITED(status)||WEXITSTATUS(status)){free(buf);return NULL;}buf[used]=0;return buf;
}
static cJSON *get(cJSON *o,const char *key){return cJSON_GetObjectItemCaseSensitive(o,key);}
static int truth(cJSON *o,const char *key){return cJSON_IsTrue(get(o,key));}
static int uuid(const char *s){if(!s||strlen(s)!=36)return 0;for(int i=0;i<36;i++){if(i==8||i==13||i==18||i==23){if(s[i]!='-')return 0;}else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;}return 1;}
static void memory(struct snapshot *s){
 FILE *f=fopen("/proc/meminfo","r");char line[160];unsigned long long n;
 if(f){while(fgets(line,sizeof line,f)){if(sscanf(line,"MemTotal: %llu kB",&n)==1)s->ram_total=n*1024;if(sscanf(line,"MemAvailable: %llu kB",&n)==1)s->ram_free=n*1024;}fclose(f);}
 struct statvfs st;if(!statvfs("/data",&st)){s->disk_total=(uint64_t)st.f_blocks*st.f_frsize;s->disk_free=(uint64_t)st.f_bavail*st.f_frsize;}
 f=fopen("/proc/uptime","r");double seconds;if(f){if(fscanf(f,"%lf",&seconds)==1&&seconds>=0)s->uptime=(uint64_t)seconds;fclose(f);}
}
static int parse(struct snapshot *s,const char *json){
 cJSON *root=cJSON_Parse(json);if(!root)return 0;
 cJSON *data=get(root,"data"),*profiles=get(data,"profiles");int ok=truth(root,"ok")&&data&&profiles;
 if(ok){s->valid=1;s->enabled=truth(data,"enabled");s->running=truth(data,"core_running");s->network_ok=truth(data,"network_ok");s->count=0;
 int count=cJSON_GetArraySize(profiles);if(count>MAX_PROFILES)count=MAX_PROFILES;
 for(int i=0;i<count;i++){cJSON *p=cJSON_GetArrayItem(profiles,i);const char *id=cJSON_GetStringValue(get(p,"id")),*name=cJSON_GetStringValue(get(p,"name"));if(!uuid(id)||!name)continue;struct profile_summary *dst=&s->profiles[s->count++];snprintf(dst->id,sizeof dst->id,"%s",id);snprintf(dst->name,sizeof dst->name,"%s",name);dst->active=truth(p,"active");}}
 cJSON_Delete(root);return ok;
}
static void *worker(void *unused){(void)unused;
 /* Never let an early helper exit deliver SIGPIPE to the stock launcher. */
 sigset_t blocked;sigemptyset(&blocked);sigaddset(&blocked,SIGPIPE);pthread_sigmask(SIG_BLOCK,&blocked,NULL);
 for(;;){pthread_mutex_lock(&mutex);while(!pending)pthread_cond_wait(&cond,&mutex);int action=pending;char cmd[160];memcpy(cmd,request,sizeof cmd);pending=0;working=1;struct snapshot next=state;pthread_mutex_unlock(&mutex);
 char *result=call(action==2?cmd:"{\"action\":\"status\"}");int ok=result&&parse(&next,result);free(result);memory(&next);
 pthread_mutex_lock(&mutex);next.error=!ok;next.busy=0;next.generation=state.generation+1;if(action==2||!state.busy)state=next;working=0;pthread_mutex_unlock(&mutex);
 }
 return NULL;
}
void backend_start(void){if(started)return;pthread_t thread;if(!pthread_create(&thread,NULL,worker,NULL)){pthread_detach(thread);started=1;backend_refresh();}}
void backend_refresh(void){pthread_mutex_lock(&mutex);if(!pending&&!working&&!state.busy){pending=1;pthread_cond_signal(&cond);}pthread_mutex_unlock(&mutex);}
void backend_snapshot(struct snapshot *out){pthread_mutex_lock(&mutex);*out=state;pthread_mutex_unlock(&mutex);}
int backend_action(int enable,const char *id){
 if(enable<0&&!uuid(id))return 0;
 pthread_mutex_lock(&mutex);if(!started||state.busy||pending==2){pthread_mutex_unlock(&mutex);return 0;}
 if(enable<0)snprintf(request,sizeof request,"{\"action\":\"activate\",\"id\":\"%s\"}",id);
 else snprintf(request,sizeof request,"{\"action\":\"set_enabled\",\"enabled\":%s}",enable?"true":"false");
 state.busy=1;state.error=0;state.generation++;pending=2;pthread_cond_signal(&cond);pthread_mutex_unlock(&mutex);return 1;
}
