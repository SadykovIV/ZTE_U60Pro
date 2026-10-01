#define _GNU_SOURCE
#include "esim-backend.h"
#include "esim-process.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <syslog.h>
#include <errno.h>
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static struct esim_snapshot state;
static int started,pending,working,busy_retry;
static char *expected,*request;
struct response {struct esim_snapshot *next;char **canonical;int mutation,seen;char error[64],component[64];};
static int receive_line(const char *line,void *context){
 struct response *r=context;char stage[40];if(r->seen)return 0;
 if(esim_parse_progress(line,stage)){
  pthread_mutex_lock(&mutex);snprintf(state.stage,sizeof state.stage,"%s",stage);state.generation++;pthread_mutex_unlock(&mutex);return 1;
 }
 if(esim_parse_result(line,r->next,r->canonical,r->mutation)){r->seen=1;return 1;}
 if(esim_parse_error(line,r->error,r->component)){r->seen=1;return 1;}
 return 0;
}
/* Metadata only: never copy raw protocol, ICCID, EID, APDU or request text. */
static void diagnostic(int action,int ok,const char *error,const char *component,const struct esim_process_result *r){
 char text[512];snprintf(text,sizeof text,"operation=%s ok=%d error=%s component_error=%s status_valid=%d exit=%d read_errno=%d write_errno=%d wait_errno=%d protocol_error=%d\n",action==2?"enable":"list",ok,error[0]?error:"none",component[0]?component:"none",r->status_valid,r->status_valid&&WIFEXITED(r->exit_status)?WEXITSTATUS(r->exit_status):-1,r->read_errno,r->write_errno,r->wait_errno,r->protocol_error);
 if(!ok)syslog(LOG_USER|LOG_WARNING,"zte-launcher eSIM: %s",text);
 int dir=open("/tmp/zte-launcher",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
 if(dir<0)return;if(fstat(dir,&st)||st.st_uid||(st.st_mode&0777)!=0700){close(dir);return;}
 const char *names[]={"esim-status","esim-error","esim-last-enable"};
 for(int i=0;i<3;i++){
  if((i==1&&ok)||(i==2&&action!=2))continue;
  int fd=openat(dir,names[i],O_WRONLY|O_CREAT|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0)continue;
  if(!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==0&&(st.st_mode&07777)==0600&&st.st_nlink==1){if(!ftruncate(fd,0)){size_t used=0,n=strlen(text);while(used<n){ssize_t k=write(fd,text+used,n-used);if(k<0&&errno==EINTR)continue;if(k<=0)break;used+=(size_t)k;}}}close(fd);
 }close(dir);
}
/* Never kill on timeout, screen sleep, or UI exit. The agent owns recovery. */
static int call(const char *input,struct response *response,struct esim_process_result *result){
 const char *path="/data/zte-agent";struct stat st;memset(result,0,sizeof *result);
 if(lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_uid||st.st_mode&022){snprintf(response->error,sizeof response->error,"agent_unavailable");return 0;}
 char *args[]={(char*)path,"--esim-launcher",NULL};
 int transport=esim_process_run(args,input,receive_line,response,result);
 int ok=transport&&response->seen&&!response->error[0];
 if(!ok&&!response->error[0])snprintf(response->error,sizeof response->error,"%s",!result->status_valid?"agent_exit_unknown":result->protocol_error?"agent_protocol_error":"agent_process_failed");
 return ok;
}
static void *worker(void *unused){
 (void)unused;sigset_t blocked;sigemptyset(&blocked);sigaddset(&blocked,SIGPIPE);pthread_sigmask(SIG_BLOCK,&blocked,NULL);
 for(;;){
  pthread_mutex_lock(&mutex);while(!pending)pthread_cond_wait(&cond,&mutex);
  int action=pending;pending=0;working=1;char *input=request;request=NULL;pthread_mutex_unlock(&mutex);
  struct esim_snapshot *next=calloc(1,sizeof *next);char *canonical=NULL;
  struct response response={.next=next,.canonical=&canonical,.mutation=action==2};struct esim_process_result process={0};
  int ok=next&&call(input?input:"{\"protocol\":1,\"operation\":\"list\"}\n",&response,&process);free(input);
  if(!next)snprintf(response.error,sizeof response.error,"memory_unavailable");
  diagnostic(action,ok,response.error,response.component,&process);
  pthread_mutex_lock(&mutex);unsigned generation=state.generation+1;
  if(ok){state=*next;free(expected);expected=canonical;canonical=NULL;busy_retry=1;}
  else {if(action==2)busy_retry=0;state.mutation_failed=action==2;state.valid=0;state.verified=0;free(expected);expected=NULL;snprintf(state.error_code,sizeof state.error_code,"%s",response.error);snprintf(state.component_error,sizeof state.component_error,"%s",response.component);}
  state.busy=0;state.error=!ok;state.generation=generation;state.stage[0]=0;working=0;
  pthread_mutex_unlock(&mutex);free(canonical);free(next);
 }
 return NULL;
}
void esim_start(void){if(started)return;pthread_t thread;if(!pthread_create(&thread,NULL,worker,NULL)){pthread_detach(thread);started=1;}}
static void refresh(int manual){
 pthread_mutex_lock(&mutex);
 if(started&&!pending&&!working&&!state.busy&&(manual||!state.error||(busy_retry&&!strcmp(state.error_code,"esim_busy")))){
  if(manual)busy_retry=1;else if(state.error)busy_retry=0;
  pending=1;state.busy=1;state.generation++;snprintf(state.stage,sizeof state.stage,"checking_card");pthread_cond_signal(&cond);
 }pthread_mutex_unlock(&mutex);
}
void esim_refresh(void){refresh(1);}
void esim_poll(void){refresh(0);}
void esim_snapshot(struct esim_snapshot *out){pthread_mutex_lock(&mutex);*out=state;pthread_mutex_unlock(&mutex);}
int esim_enable(const char *iccid,unsigned generation){
 pthread_mutex_lock(&mutex);int ok=0;
 if(!started||!state.valid||state.busy||pending||working||!expected||generation!=state.generation)goto end;
 int found=0;for(int i=0;i<state.count;i++)if(!strcmp(iccid,state.profiles[i].iccid))found=1;if(!found)goto end;
 size_t cap=strlen(expected)+256;request=malloc(cap);if(!request)goto end;
 snprintf(request,cap,"{\"protocol\":1,\"operation\":\"enable\",\"iccid\":\"%s\",\"expected_snapshot\":%s}\n",iccid,expected);
 state.busy=1;state.error=0;state.error_code[0]=0;state.generation++;snprintf(state.stage,sizeof state.stage,"checking_card");pending=2;pthread_cond_signal(&cond);ok=1;
end:pthread_mutex_unlock(&mutex);return ok;
}
