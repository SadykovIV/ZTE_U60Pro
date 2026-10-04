#define _GNU_SOURCE
#include "../vpn-process.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern int vpn_process_test_proof_mode;
extern int vpn_process_test_proc_fallback;
extern int vpn_process_test_parse_ppid(const char *,size_t,pid_t *);
extern int vpn_process_test_proc_record(const unsigned char *,size_t,size_t *,pid_t *);
static char executable[PATH_MAX],scratch[PATH_MAX];
static volatile sig_atomic_t reaped,interrupted;
static unsigned groups, skipped;
static const char success[]="{\"ok\":true,\"data\":{}}\n";
static const char refused[]="{\"ok\":false,\"code\":\"VPN_BUSY\"}\n";
static uint64_t millis(void){struct timespec t;assert(!clock_gettime(CLOCK_MONOTONIC,&t));return (uint64_t)t.tv_sec*1000U+(uint64_t)t.tv_nsec/1000000U;}
static void pause_ms(long ms){struct timespec t={ms/1000,(ms%1000)*1000000};while(nanosleep(&t,&t)<0&&errno==EINTR){}}
static void send_bytes(const void *bytes,size_t length){while(length){ssize_t n=write(1,bytes,length);if(n<0&&errno==EINTR)continue;if(n<=0)_exit(91);bytes=(const char*)bytes+n;length-=(size_t)n;}}
static void marker(const char *name){char path[PATH_MAX];assert(snprintf(path,sizeof path,"%s/%s",scratch,name)<(int)sizeof path);int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0600);assert(fd>=0);assert(write(fd,"x",1)==1);close(fd);}
static int child(const char *mode){
 alarm(8); /* Bound synthetic descendants even if the harness assertion fails. */
 marker("dispatch");
 if(!strcmp(mode,"early-close")){close(0);pause_ms(20);send_bytes(refused,sizeof refused-1);return 1;}
 if(!strcmp(mode,"duplex")){char b[8192];memset(b,'d',sizeof b);for(int i=0;i<8;i++)send_bytes(b,sizeof b);}
 char input[4096];size_t total=0;
 for(;;){ssize_t n=read(0,input,sizeof input);if(n<0&&errno==EINTR)continue;if(n<=0)break;total+=(size_t)n;}
 if(!strcmp(mode,"duplex"))return total==VPN_PROCESS_INPUT_LIMIT?0:92;
 if(!strcmp(mode,"refusal")){send_bytes(refused,sizeof refused-1);return 1;}
 if(!strcmp(mode,"signal")){send_bytes(success,sizeof success-1);raise(SIGTERM);return 93;}
 if(!strcmp(mode,"exact")||!strcmp(mode,"oversize")||!strcmp(mode,"flood")){
  char b[8192];memset(b,'x',sizeof b);for(unsigned i=0;i<VPN_PROCESS_OUTPUT_LIMIT/sizeof b;i++)send_bytes(b,sizeof b);
  if(!strcmp(mode,"oversize"))send_bytes("x",1);
  if(!strcmp(mode,"flood"))for(;;)send_bytes(b,sizeof b);
  return 0;
 }
 if(!strcmp(mode,"nul")){const char data[]={'a',0,'b'};send_bytes(data,sizeof data);return 0;}
 if(!strcmp(mode,"timeout")){pause_ms(10000);return 0;}
 if(!strcmp(mode,"tree")||!strcmp(mode,"orphan-tree")){
  pid_t manager=fork();assert(manager>=0);
  if(!manager){alarm(8);assert(!setpgid(0,0));dprintf(1,"%ld\n",(long)getpid());pid_t grand=fork();assert(grand>=0);
   if(!grand){alarm(8);assert(setsid()>0);dprintf(1,"%ld\n",(long)getpid());for(;;)pause();}
   for(;;)pause();}
  dprintf(1,"%ld\n",(long)getpid());if(!strcmp(mode,"orphan-tree"))return 0;for(;;)pause();
 }
 if(!strcmp(mode,"same-group")){
  pid_t grand=fork();assert(grand>=0);if(!grand){alarm(8);dprintf(1,"%ld\n",(long)getpid());for(;;)pause();}for(;;)pause();
 }
 if(!strcmp(mode,"background")){
  pid_t service=fork();assert(service>=0);if(!service){close(0);close(1);close(2);pause_ms(180);marker("background-survived");_exit(0);}send_bytes(success,sizeof success-1);return 0;
 }
 if(!strcmp(mode,"fd")){if(fcntl(5000,F_GETFD)>=0||errno!=EBADF)return 94;}
 if(!strcmp(mode,"fragmented")){for(size_t i=0;i<sizeof success-1;i++){send_bytes(success+i,1);pause_ms(2);}return 0;}
 if(!strcmp(mode,"delayed-exit")){send_bytes(success,sizeof success-1);close(1);pause_ms(100);return 0;}
 send_bytes(success,sizeof success-1);return 0;
}
static void reaper(int sig){(void)sig;int saved=errno,s;while(waitpid(-1,&s,WNOHANG)>0)reaped++;errno=saved;}
static void alarmed(int sig){(void)sig;interrupted++;}
static void timer(int on){struct itimerval t={{0,on?1000:0},{0,on?1000:0}};assert(!setitimer(ITIMER_REAL,&t,NULL));}
static size_t dispatches(void){char p[PATH_MAX];assert(snprintf(p,sizeof p,"%s/dispatch",scratch)<(int)sizeof p);struct stat s;return stat(p,&s)?0:(size_t)s.st_size;}
static int run(const char *mode,const char *input,size_t len,unsigned timeout,struct vpn_process_result *r){char *args[]={executable,"--child",(char*)mode,scratch,NULL};return vpn_process_run(args,input,len,timeout,r);}
static void complete(const struct vpn_process_result *r,int code){assert(r->proof_valid&&r->status_valid&&r->cleanup_complete&&WIFEXITED(r->exit_status)&&WEXITSTATUS(r->exit_status)==code&&!r->timed_out&&!r->output_limit);}
static int descriptors(void){int n=0;for(int fd=0;fd<512;fd++)if(fcntl(fd,F_GETFD)>=0)n++;return n;}
static void proc_parser_tests(void){
 pid_t parent=-1;const char *valid[]={"Name:\ttest\nPPid:\t1234\nUid:\t0\n","PPid:  0 \t\n","PPid:\t2147483647\n"};
 const pid_t expected[]={1234,0,INT_MAX};
 for(size_t i=0;i<sizeof valid/sizeof valid[0];i++){assert(vpn_process_test_parse_ppid(valid[i],strlen(valid[i]),&parent));assert(parent==expected[i]);}
 const char *bad[]={"Name: test\n","PPid: 2", "PPid: \n", "PPid: -1\n", "PPid: 2147483648\n", "PPid: 12x\n", "PPid: 2\nPPid: 3\n", "PPid: 2\nPPid: 2\n", "PPid: 2\r\n"};
 for(size_t i=0;i<sizeof bad/sizeof bad[0];i++)assert(!vpn_process_test_parse_ppid(bad[i],strlen(bad[i]),&parent));groups++;
 unsigned char record[64]={0};uint16_t length=24;memcpy(record+16,&length,2);memcpy(record+19,"123",4);size_t step=0;pid_t pid=0;
 assert(vpn_process_test_proc_record(record,24,&step,&pid)==1&&step==24&&pid==123);
 assert(vpn_process_test_proc_record(record,23,&step,&pid)==-1);
 assert(vpn_process_test_proc_record(record,19,&step,&pid)==-1);
 memcpy(record+19,"self",5);assert(vpn_process_test_proc_record(record,24,&step,&pid)==0);
 memcpy(record+19,"12x",4);assert(vpn_process_test_proc_record(record,24,&step,&pid)==0);
 memset(record+19,'9',5);assert(vpn_process_test_proc_record(record,24,&step,&pid)==-1);
 length=40;memcpy(record+16,&length,2);memcpy(record+19,"2147483648",11);assert(vpn_process_test_proc_record(record,40,&step,&pid)==-1);
 length=0;memcpy(record+16,&length,2);assert(vpn_process_test_proc_record(record,40,&step,&pid)==-1);groups++;
}
static void tests(void){
 proc_parser_tests();
 struct rlimit original_limit,test_limit;assert(!getrlimit(RLIMIT_NOFILE,&original_limit));test_limit=original_limit;
 if(test_limit.rlim_cur>512){test_limit.rlim_cur=512;assert(!setrlimit(RLIMIT_NOFILE,&test_limit));}
 struct sigaction original,action={0},old_alarm;sigemptyset(&action.sa_mask);action.sa_handler=reaper;assert(!sigaction(SIGCHLD,&action,&original));
 action.sa_handler=alarmed;assert(!sigaction(SIGALRM,&action,&old_alarm));int initial=descriptors();struct vpn_process_result r;
 assert(run("normal","{}",2,1000,&r));complete(&r,0);assert(r.output_length==sizeof success-1&&!memcmp(r.output,success,r.output_length));vpn_process_free(&r);groups++;
 assert(run("refusal","{}",2,1000,&r));complete(&r,1);assert(!strcmp(r.output,refused));vpn_process_free(&r);groups++;
 action.sa_handler=SIG_IGN;action.sa_flags=SA_NOCLDWAIT;assert(!sigaction(SIGCHLD,&action,NULL));
 assert(run("normal","{}",2,1000,&r));complete(&r,0);assert(r.wait_errno==ECHILD);vpn_process_free(&r);groups++;
 action.sa_handler=reaper;action.sa_flags=0;assert(!sigaction(SIGCHLD,&action,NULL));
 reaped=0;assert(run("delayed-exit","{}",2,1000,&r));complete(&r,0);vpn_process_free(&r);groups++;
 timer(1);assert(run("fragmented","{}",2,1500,&r));timer(0);complete(&r,0);assert(interrupted>10&&!strcmp(r.output,success));vpn_process_free(&r);groups++;
 char *large=malloc(VPN_PROCESS_INPUT_LIMIT+1U);assert(large);memset(large,'a',VPN_PROCESS_INPUT_LIMIT+1U);
 timer(1);assert(run("duplex",large,VPN_PROCESS_INPUT_LIMIT,1500,&r));timer(0);complete(&r,0);assert(r.output_length==65536);vpn_process_free(&r);groups++;
 assert(run("exact","{}",2,1000,&r));complete(&r,0);assert(r.output_length==VPN_PROCESS_OUTPUT_LIMIT&&r.output[r.output_length]==0);vpn_process_free(&r);groups++;
 for(int i=0;i<2;i++){size_t before=dispatches();uint64_t start=millis();assert(!run(i?"flood":"oversize","{}",2,1000,&r));assert(r.output_limit&&r.output_length==VPN_PROCESS_OUTPUT_LIMIT&&millis()-start<2500&&dispatches()==before+1);vpn_process_free(&r);groups++;}
 assert(run("nul","{}",2,1000,&r));complete(&r,0);assert(r.output_length==3&&r.output[1]==0&&r.output[2]=='b');vpn_process_free(&r);groups++;
 assert(!run("signal","{}",2,1000,&r));assert(r.status_valid&&WIFSIGNALED(r.exit_status)&&WTERMSIG(r.exit_status)==SIGTERM);vpn_process_free(&r);groups++;
 for(int mode=1;mode<=5;mode++){vpn_process_test_proof_mode=mode;assert(!run("normal","{}",2,1000,&r));assert(!r.proof_valid&&!r.status_valid);vpn_process_free(&r);groups++;}vpn_process_test_proof_mode=0;
 char *missing[]={"/no/such/vpn-process-fixture",NULL};assert(vpn_process_run(missing,NULL,0,1000,&r));complete(&r,127);vpn_process_free(&r);groups++;
 size_t before=dispatches();assert(!run("normal",large,VPN_PROCESS_INPUT_LIMIT+1U,1000,&r));assert(r.write_errno==EINVAL&&dispatches()==before);vpn_process_free(&r);free(large);groups++;
 before=dispatches();assert(!run("normal","{}",2,0,&r));assert(r.write_errno==EINVAL&&dispatches()==before);vpn_process_free(&r);groups++;
 large=malloc(VPN_PROCESS_INPUT_LIMIT);assert(large);memset(large,'a',VPN_PROCESS_INPUT_LIMIT);int ok=run("early-close",large,VPN_PROCESS_INPUT_LIMIT,1000,&r);assert(ok?r.status_valid:(r.write_errno||r.read_errno||r.broker_errno));vpn_process_free(&r);free(large);groups++;
 before=dispatches();uint64_t start=millis();assert(!run("timeout","{}",2,100,&r));
 if(!(r.timed_out&&r.proof_valid&&r.status_valid&&millis()-start<1500&&dispatches()==before+1))fprintf(stderr,"timeout diagnostic: timed=%d proof=%d status=%d cleanup=%d r=%d w=%d wait=%d broker=%d elapsed=%llu dispatch_delta=%zu\n",r.timed_out,r.proof_valid,r.status_valid,r.cleanup_complete,r.read_errno,r.write_errno,r.wait_errno,r.broker_errno,(unsigned long long)(millis()-start),dispatches()-before);
 assert(r.timed_out&&r.proof_valid&&r.status_valid&&millis()-start<1500&&dispatches()==before+1);
#ifdef __linux__
 assert(r.cleanup_complete);
#else
 assert(!r.cleanup_complete);
#endif
 vpn_process_free(&r);groups++;
 assert(!run("same-group","{}",2,150,&r));assert(r.timed_out&&r.status_valid);vpn_process_free(&r);groups++;
#ifdef __linux__
 for(int orphan=0;orphan<2;orphan++){
  before=dispatches();start=millis();assert(!run(orphan?"orphan-tree":"tree","{}",2,200,&r));assert(r.timed_out&&r.proof_valid&&r.cleanup_complete&&millis()-start<1500&&dispatches()==before+1);
  char *cursor=r.output;unsigned count=0;while(*cursor){char *end;long pid=strtol(cursor,&end,10);assert(end!=cursor&&pid>1&&*end=='\n');assert(kill((pid_t)pid,0)<0&&errno==ESRCH);cursor=end+1;count++;}assert(count==3);vpn_process_free(&r);groups++;
 }
 /* Forced fallback also covers kernels which do provide task/children. A
  * sibling owned by the test process must remain alive throughout the scan. */
 sigset_t hold,prior;sigemptyset(&hold);sigaddset(&hold,SIGCHLD);assert(!sigprocmask(SIG_BLOCK,&hold,&prior));
 pid_t sibling=fork();assert(sibling>=0);if(!sibling){signal(SIGALRM,SIG_DFL);alarm(8);for(;;)pause();}
 vpn_process_test_proc_fallback=1;
 for(int variant=0;variant<3;variant++){
  before=dispatches();start=millis();const char *mode=variant==0?"timeout":variant==1?"tree":"orphan-tree";
  assert(!run(mode,"{}",2,200,&r));assert(r.timed_out&&r.proof_valid&&r.cleanup_complete&&millis()-start<1500&&dispatches()==before+1);
  if(variant){char *cursor=r.output;unsigned count=0;while(*cursor){char *end;long pid=strtol(cursor,&end,10);assert(end!=cursor&&pid>1&&*end=='\n');assert(kill((pid_t)pid,0)<0&&errno==ESRCH);cursor=end+1;count++;}assert(count==3);}
  assert(!kill(sibling,0));vpn_process_free(&r);groups++;
 }
 vpn_process_test_proc_fallback=2;assert(!run("timeout","{}",2,100,&r));assert(r.timed_out&&r.proof_valid&&!r.cleanup_complete);vpn_process_free(&r);groups++;
 vpn_process_test_proc_fallback=0;
 siginfo_t owned;memset(&owned,0,sizeof owned);assert(!waitid(P_PID,(id_t)sibling,&owned,WEXITED|WNOHANG|WNOWAIT));assert(!owned.si_pid);
 assert(!kill(sibling,SIGTERM));int sibling_status;assert(waitpid(sibling,&sibling_status,0)==sibling);assert(WIFSIGNALED(sibling_status)&&WTERMSIG(sibling_status)==SIGTERM);assert(!sigprocmask(SIG_SETMASK,&prior,NULL));
#endif
 assert(run("background","{}",2,1000,&r));complete(&r,0);vpn_process_free(&r);char path[PATH_MAX];assert(snprintf(path,sizeof path,"%s/background-survived",scratch)<(int)sizeof path);for(int i=0;i<100&&access(path,F_OK);i++)pause_ms(10);assert(!access(path,F_OK));groups++;
 struct rlimit saved_limit,limit;assert(!getrlimit(RLIMIT_NOFILE,&saved_limit));
 if(saved_limit.rlim_max==RLIM_INFINITY||saved_limit.rlim_max>=5001){
  limit=saved_limit;if(limit.rlim_cur<=5000){limit.rlim_cur=5001;assert(!setrlimit(RLIMIT_NOFILE,&limit));}
  int source=open("/dev/null",O_RDONLY);assert(source>=0);assert(dup2(source,5000)==5000);close(source);assert(run("fd","{}",2,1000,&r));complete(&r,0);assert(fcntl(5000,F_GETFD)>=0);vpn_process_free(&r);close(5000);assert(!setrlimit(RLIMIT_NOFILE,&saved_limit));groups++;
 }else{puts("SKIP high-fd fixture: hard RLIMIT_NOFILE below 5001");skipped++;}
 int saved[3];for(int i=0;i<3;i++){saved[i]=fcntl(i,F_DUPFD_CLOEXEC,10);assert(saved[i]>=0);close(i);}ok=run("normal","{}",2,1000,&r);for(int i=0;i<3;i++){assert(dup2(saved[i],i)==i);close(saved[i]);}assert(ok);complete(&r,0);vpn_process_free(&r);groups++;
 struct sigaction preserved;assert(!sigaction(SIGCHLD,NULL,&preserved));assert(preserved.sa_handler==reaper);assert(descriptors()==initial);assert(!sigaction(SIGCHLD,&original,NULL));assert(!sigaction(SIGALRM,&old_alarm,NULL));assert(!setrlimit(RLIMIT_NOFILE,&original_limit));groups++;
 printf("vpn process: %u groups PASS; %u SKIP; native host=%s; nested-group and forced-proc-fallback tests=%s\n",groups,skipped,
#ifdef __linux__
 "Linux","executed"
#else
 "non-Linux","not executed (Linux-only)"
#endif
 );
}
int main(int argc,char **argv){
 if(argc==4&&!strcmp(argv[1],"--child")){assert(strlen(argv[3])<sizeof scratch);strcpy(scratch,argv[3]);return child(argv[2]);}
 assert(realpath(argv[0],executable));char pattern[]="/tmp/vpn-process-test-XXXXXX";char *dir=mkdtemp(pattern);assert(dir);strcpy(scratch,dir);tests();
 char path[PATH_MAX+32];snprintf(path,sizeof path,"%s/dispatch",scratch);assert(!unlink(path));snprintf(path,sizeof path,"%s/background-survived",scratch);assert(!unlink(path));assert(!rmdir(scratch));return 0;
}
