#define _GNU_SOURCE
#include "../esim-process.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern int esim_process_test_proof_mode;
static char executable[PATH_MAX];
static volatile sig_atomic_t reaped,interrupted;
static const char progress[]="{\"type\":\"progress\"}";
static const char result[]="{\"type\":\"result\",\"ok\":true}";
static void pause_ms(long ms){struct timespec t={ms/1000,(ms%1000)*1000000};while(nanosleep(&t,&t)&&errno==EINTR){}}
static void send_bytes(const void *p,size_t n){while(n){ssize_t k=write(1,p,n);if(k<0&&errno==EINTR)continue;if(k<=0)_exit(93);p=(const char*)p+k;n-=(size_t)k;}}
static void send_line(const char *p){send_bytes(p,strlen(p));send_bytes("\n",1);}
static int child(const char *mode){
 if(!strcmp(mode,"close_input")){close(0);pause_ms(30);return 0;}
 if(!strcmp(mode,"slow_input"))pause_ms(60);
 char b[4096];for(;;){ssize_t n=read(0,b,sizeof b);if(n<0&&errno==EINTR)continue;if(n<=0)break;}
 if(!strcmp(mode,"fd_check")){if(fcntl(5000,F_GETFD)!=-1||errno!=EBADF)return 92;send_line(result);return 0;}
 if(!strcmp(mode,"fragmented")||!strcmp(mode,"slow_input")){
  const char *rows[]={progress,result};for(unsigned row=0;row<2;row++){for(size_t i=0;i<strlen(rows[row]);i++){send_bytes(rows[row]+i,1);pause_ms(1);}send_bytes("\n",1);}return 0;
 }
 if(!strcmp(mode,"truncated")){send_bytes(result,strlen(result));return 0;}
 if(!strcmp(mode,"nul")){send_bytes(result,8);send_bytes("\0",1);send_bytes(result+8,strlen(result)-8);send_bytes("\n",1);return 0;}
 if(!strcmp(mode,"malformed")){send_line("not-json");send_line(result);return 0;}
 if(!strcmp(mode,"oversized")){char bytes[8192];memset(bytes,'x',sizeof bytes);for(unsigned i=0;i<1153;i++)send_bytes(bytes,sizeof bytes);send_bytes("\n",1);send_line(result);return 0;}
 send_line(progress);send_line(result);
 if(!strcmp(mode,"proof_delay")){close(1);pause_ms(80);}
 if(!strcmp(mode,"signal")){raise(SIGTERM);return 91;}
 return !strcmp(mode,"nonzero")?7:0;
}
static void reaper(int signal){(void)signal;int saved=errno,status;while(waitpid(-1,&status,WNOHANG)>0)reaped++;errno=saved;}
static void alarmed(int signal){(void)signal;interrupted++;}
struct context{unsigned lines;int slow,reject;};
static int line(const char *value,void *opaque){
 struct context *c=opaque;c->lines++;
 if(c->slow)pause_ms(80);
 return !c->reject&&(!strcmp(value,progress)||!strcmp(value,result));
}
static int run(const char *mode,const char *input,struct context *c,struct esim_process_result *r){char *args[]={executable,"--child",(char*)mode,NULL};return esim_process_run(args,input,line,c,r);}
static int descriptors(void){int n=0;for(int fd=0;fd<512;fd++)if(fcntl(fd,F_GETFD)>=0)n++;return n;}
static void timer(int on){struct itimerval timer={{0,on?1000:0},{0,on?1000:0}};assert(setitimer(ITIMER_REAL,&timer,NULL)==0);}
static void tests(void){
 struct sigaction original,action={0};sigemptyset(&action.sa_mask);action.sa_handler=reaper;assert(sigaction(SIGCHLD,&action,&original)==0);
 struct sigaction old_alarm;action.sa_handler=alarmed;assert(sigaction(SIGALRM,&action,&old_alarm)==0); /* no SA_RESTART */
 int initial=descriptors();struct esim_process_result r;struct context c={0};
 assert(run("complete","{}\n",&c,&r));assert(c.lines==2&&r.status_valid&&WEXITSTATUS(r.exit_status)==0);
 c=(struct context){.slow=1};reaped=0;assert(run("complete","{}\n",&c,&r));assert(reaped>0&&r.wait_errno==ECHILD&&r.status_valid);
 c=(struct context){0};timer(1);assert(run("fragmented","{}\n",&c,&r));timer(0);assert(c.lines==2&&interrupted>10);
 char *large=malloc(2U*1024U*1024U+1);assert(large);memset(large,'x',2U*1024U*1024U);large[2U*1024U*1024U]=0;
 c=(struct context){0};timer(1);assert(run("slow_input",large,&c,&r));timer(0);assert(c.lines==2&&!r.write_errno);
 c=(struct context){0};timer(1);assert(run("proof_delay","{}\n",&c,&r));timer(0);assert(r.status_valid);
 c=(struct context){0};assert(!run("close_input",large,&c,&r));assert(r.write_errno==EPIPE);free(large);
 const char *bad[]={"truncated","nul","malformed","oversized"};for(unsigned i=0;i<4;i++){c=(struct context){0};assert(!run(bad[i],"{}\n",&c,&r));assert(r.protocol_error&&r.status_valid);}
 c=(struct context){.reject=1};assert(!run("complete","{}\n",&c,&r));assert(r.protocol_error&&r.status_valid&&c.lines==2);
 c=(struct context){0};assert(!run("nonzero","{}\n",&c,&r));assert(r.status_valid&&WIFEXITED(r.exit_status)&&WEXITSTATUS(r.exit_status)==7);
 c=(struct context){0};assert(!run("signal","{}\n",&c,&r));assert(r.status_valid&&WIFSIGNALED(r.exit_status)&&WTERMSIG(r.exit_status)==SIGTERM);
 for(int mode=1;mode<=5;mode++){esim_process_test_proof_mode=mode;c=(struct context){0};assert(!run("complete","{}\n",&c,&r));assert(!r.status_valid&&r.exit_status==-1);}esim_process_test_proof_mode=0;
 char *missing[]={"/no/such/zte-esim-test-binary",NULL};c=(struct context){0};assert(!esim_process_run(missing,"{}\n",line,&c,&r));assert(r.status_valid&&WEXITSTATUS(r.exit_status)==127);
 /* Explicit SIGCHLD ignore/NOCLDWAIT on the parent cannot steal the agent's
  * status inside its broker; only the outer wait becomes ECHILD. */
 action.sa_handler=SIG_IGN;action.sa_flags=SA_NOCLDWAIT;assert(sigaction(SIGCHLD,&action,NULL)==0);
 c=(struct context){0};assert(run("complete","{}\n",&c,&r));assert(r.status_valid&&r.wait_errno==ECHILD);
 action.sa_handler=reaper;action.sa_flags=0;assert(sigaction(SIGCHLD,&action,NULL)==0);
 /* High inherited descriptors must be closed only in broker/agent, never parent. */
 struct rlimit limit;assert(getrlimit(RLIMIT_NOFILE,&limit)==0);struct rlimit raised=limit;
 if(raised.rlim_cur<=5000){raised.rlim_cur=5001;assert(setrlimit(RLIMIT_NOFILE,&raised)==0);}
 int source=open("/dev/null",O_RDONLY);assert(source>=0);assert(dup2(source,5000)==5000);close(source);
 c=(struct context){0};assert(run("fd_check","{}\n",&c,&r));assert(fcntl(5000,F_GETFD)>=0);close(5000);assert(setrlimit(RLIMIT_NOFILE,&limit)==0);
 /* A caller with closed stdio still supplies a working request and stdout to
  * the exec child; dup2 must not retain the pipe's CLOEXEC on the same fd. */
 int saved[3];for(int i=0;i<3;i++){saved[i]=fcntl(i,F_DUPFD_CLOEXEC,10);assert(saved[i]>=0);close(i);}
 c=(struct context){0};int ok=run("complete","{}\n",&c,&r);
 for(int i=0;i<3;i++){assert(dup2(saved[i],i)==i);close(saved[i]);}assert(ok&&c.lines==2&&r.status_valid);
 assert(descriptors()==initial);assert(sigaction(SIGCHLD,&original,NULL)==0);assert(sigaction(SIGALRM,&old_alarm,NULL)==0);
 puts("esim process: reaper, EINTR, framing, exit proof, SIGPIPE and FD cleanup PASS");
}
int main(int argc,char **argv){if(argc==3&&!strcmp(argv[1],"--child"))return child(argv[2]);assert(realpath(argv[0],executable));tests();return 0;}
