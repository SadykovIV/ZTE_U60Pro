#define _GNU_SOURCE
#include "esim-process.h"
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#define MAX_LINE (9U*1024U*1024U)
extern char **environ;
#ifdef ESIM_PROCESS_TEST
/* Fault injection is absent from production builds. 1:none, 2:short,
 * 3:bad magic, 4:extra byte, 5:impossible status. */
int esim_process_test_proof_mode;
#endif
static int make_pipe(int p[2]){
#ifdef __linux__
 if(pipe2(p,O_CLOEXEC))return -1;
#else
 if(pipe(p))return -1;for(int i=0;i<2;i++)if(fcntl(p[i],F_SETFD,FD_CLOEXEC)<0){int error=errno;close(p[0]);close(p[1]);errno=error;return -1;}
#endif
 /* Avoid dup2 collisions and same-fd CLOEXEC when caller's stdio is closed. */
 for(int i=0;i<2;i++)if(p[i]<4){int next=fcntl(p[i],F_DUPFD_CLOEXEC,4);if(next<0){int error=errno;close(p[0]);close(p[1]);errno=error;return -1;}close(p[i]);p[i]=next;}
 return 0;
}
static size_t write_all(int fd,const void *data,size_t length,int *error){size_t n=0;while(n<length){ssize_t got=write(fd,(const char*)data+n,length-n);if(got<0&&errno==EINTR)continue;if(got<=0){if(error)*error=got<0?errno:EIO;break;}n+=(size_t)got;}return n;}
static size_t write_no_sigpipe(int fd,const void *data,size_t length,int *error){
 sigset_t set,old,pending;sigemptyset(&set);sigaddset(&set,SIGPIPE);
 int failure=pthread_sigmask(SIG_BLOCK,&set,&old);if(failure){*error=failure;return 0;}
 int had=0;if(!sigpending(&pending))had=sigismember(&pending,SIGPIPE);
 size_t sent=write_all(fd,data,length,error);
 /* Consume only a signal created by our write, before restoring the mask. */
 if(!had&&!sigpending(&pending)&&sigismember(&pending,SIGPIPE)){int signal;sigwait(&set,&signal);}
 failure=pthread_sigmask(SIG_SETMASK,&old,NULL);if(failure&&!*error)*error=failure;
 return sent;
}
static void close_above(int first,int limit){
#ifdef __linux__
 if(!syscall(SYS_close_range,(unsigned)first,~0U,0))return;
#endif
 for(int fd=first;fd<limit;fd++)close(fd);
}
static int status_valid(uint32_t value){
 if(value>0xffffU)return 0;int status=(int)value;
 if(WIFEXITED(status))return (value&0xffU)==0;
 if(WIFSIGNALED(status))return !(value&0xff00U)&&WTERMSIG(status)>0&&WTERMSIG(status)<NSIG;
 return 0;
}
int esim_process_run(char *const argv[],const char *input,int (*line)(const char *,void *),void *context,struct esim_process_result *r){
 if(!r)return 0;memset(r,0,sizeof *r);r->exit_status=-1;
 if(!argv||!argv[0]||!input||!line){r->protocol_error=1;return 0;}
 size_t length=strlen(input);if(length>MAX_LINE){r->protocol_error=1;return 0;}
 struct rlimit limits;int limit=4096;
 if(!getrlimit(RLIMIT_NOFILE,&limits)&&limits.rlim_cur!=RLIM_INFINITY&&limits.rlim_cur<(rlim_t)INT_MAX)limit=(int)limits.rlim_cur;
 else{long n=sysconf(_SC_OPEN_MAX);if(n>0&&n<INT_MAX)limit=(int)n;}
 int in[2],out[2],proof[2];
 if(make_pipe(in)){r->read_errno=errno;return 0;}if(make_pipe(out)){r->read_errno=errno;close(in[0]);close(in[1]);return 0;}
 if(make_pipe(proof)){r->read_errno=errno;close(in[0]);close(in[1]);close(out[0]);close(out[1]);return 0;}
 pid_t broker=fork();
 if(broker==0){
  /* Stock UI has its own SIGCHLD handler. The broker alone owns agent waitpid;
   * its separate proof pipe survives any reaping done by the stock parent.
   * Only async-signal-safe calls are used between fork and exec/exit. */
  struct sigaction action;memset(&action,0,sizeof action);sigemptyset(&action.sa_mask);action.sa_handler=SIG_DFL;if(sigaction(SIGCHLD,&action,NULL))_exit(126);
  action.sa_handler=SIG_IGN;if(sigaction(SIGHUP,&action,NULL)||sigaction(SIGPIPE,&action,NULL))_exit(126);
  sigset_t mask;sigemptyset(&mask);if(sigprocmask(SIG_SETMASK,&mask,NULL))_exit(126);
  if(dup2(in[0],0)<0||dup2(out[1],1)<0)_exit(126);
  int null=open("/dev/null",O_WRONLY);if(null<0||dup2(null,2)<0)_exit(126);if(null>2)close(null);
  if(dup2(proof[1],3)<0)_exit(126);close_above(4,limit);
  pid_t agent=fork();
  if(agent==0){close(3);execve(argv[0],argv,environ);_exit(127);}
  close(0);close(1);int status=-1;
  if(agent>0){pid_t got;do{got=waitpid(agent,&status,0);}while(got<0&&errno==EINTR);if(got!=agent)status=-1;}
  uint32_t data[2]={0x4553494dU,(uint32_t)status};size_t proof_size=sizeof data;
#ifdef ESIM_PROCESS_TEST
  if(esim_process_test_proof_mode==1)proof_size=0;
  if(esim_process_test_proof_mode==2)proof_size--;
  if(esim_process_test_proof_mode==3)data[0]=0;
  if(esim_process_test_proof_mode==5)data[1]=0x10000U;
#endif
  write_all(3,data,proof_size,NULL);
#ifdef ESIM_PROCESS_TEST
  if(esim_process_test_proof_mode==4)write_all(3,"x",1,NULL);
#endif
  close(3);_exit(status<0?1:0);
 }
 close(in[0]);close(out[1]);close(proof[1]);
 if(broker<0){r->wait_errno=errno;close(in[1]);close(out[0]);close(proof[0]);return 0;}
 int sent=write_no_sigpipe(in[1],input,length,&r->write_errno)==length;close(in[1]);
 char *buffer=malloc(MAX_LINE+1);size_t used=0;int dropping=0;unsigned char chunk[8192];
 if(!buffer)r->read_errno=ENOMEM;
 for(;;){
  ssize_t n=read(out[0],chunk,sizeof chunk);if(n<0&&errno==EINTR)continue;if(n<0){r->read_errno=errno;break;}if(n==0)break;
  for(ssize_t i=0;i<n;i++){
   if(chunk[i]=='\n'){
    if(!buffer||dropping){r->protocol_error=1;}else{buffer[used]=0;if(!line(buffer,context))r->protocol_error=1;}
    used=0;dropping=0;
   }else if(!buffer||chunk[i]==0||used==MAX_LINE){dropping=1;r->protocol_error=1;}
   else if(!dropping)buffer[used++]=(char)chunk[i];
  }
 }
 if(used||dropping)r->protocol_error=1;free(buffer);close(out[0]);
 uint32_t status[2];size_t got=0;unsigned char extra;int eof=0;
 for(;;){ssize_t n=read(proof[0],got<sizeof status?(void*)((char*)status+got):&extra,got<sizeof status?sizeof status-got:1);if(n<0&&errno==EINTR)continue;if(n==0){eof=1;break;}if(n<0)break;if(got==sizeof status){got++;break;}got+=(size_t)n;}
 close(proof[0]);r->status_valid=eof&&got==sizeof status&&status[0]==0x4553494dU&&status_valid(status[1]);r->exit_status=r->status_valid?(int)status[1]:-1;
 int ignored;while(waitpid(broker,&ignored,0)<0){if(errno==EINTR)continue;r->wait_errno=errno;break;}
 /* ECHILD is safe only with the broker's independent, complete exit proof. */
 return sent&&!r->write_errno&&!r->read_errno&&(!r->wait_errno||r->wait_errno==ECHILD)&&!r->protocol_error&&r->status_valid&&WIFEXITED(r->exit_status)&&WEXITSTATUS(r->exit_status)==0;
}
