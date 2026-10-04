#define _GNU_SOURCE
#include "vpn-process.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

extern char **environ;
#define MAGIC 0x56504e31U
#define P_STATUS 1U
#define P_TIMEOUT 2U
#define P_CLEAN 4U
#define P_ABORT 8U
#define PROOF_WORDS 5U
#ifdef VPN_PROCESS_TEST
/* Absent in production: missing, short, wrong magic, excess, invalid status. */
int vpn_process_test_proof_mode;
int vpn_process_test_proc_fallback;
#endif

static uint64_t now_ms(void) {
 struct timespec ts;
 if(clock_gettime(CLOCK_MONOTONIC,&ts))return 0;
 return (uint64_t)ts.tv_sec*1000U+(uint64_t)ts.tv_nsec/1000000U;
}
static int nonblock(int fd) {
 int flags=fcntl(fd,F_GETFL);
 return flags<0?-1:fcntl(fd,F_SETFL,flags|O_NONBLOCK);
}
static int pipe_safe(int p[2]) {
#ifdef __linux__
 if(pipe2(p,O_CLOEXEC))return -1;
#else
 if(pipe(p))return -1;
 for(int i=0;i<2;i++)if(fcntl(p[i],F_SETFD,FD_CLOEXEC)<0)goto fail;
#endif
 for(int i=0;i<2;i++)if(p[i]<5){int next=fcntl(p[i],F_DUPFD_CLOEXEC,5);if(next<0)goto fail;close(p[i]);p[i]=next;}
 return 0;
fail: {int error=errno;close(p[0]);close(p[1]);errno=error;return -1;}
}
static void close_above(int first,int limit) {
#ifdef __linux__
 if(!syscall(SYS_close_range,(unsigned)first,~0U,0))return;
#endif
 for(int fd=first;fd<limit;fd++)close(fd);
}
static int valid_status(uint32_t value) {
 if(value>0xffffU)return 0;
 int status=(int)value;
 if(WIFEXITED(status))return (value&255U)==0;
 return WIFSIGNALED(status)&&!(value&0xff00U)&&WTERMSIG(status)>0&&WTERMSIG(status)<NSIG;
}
static int owned_child(pid_t pid,siginfo_t *info) {
 memset(info,0,sizeof *info);
 int rc;
 do {rc=waitid(P_PID,(id_t)pid,info,WEXITED|WNOHANG|WNOWAIT);}while(rc<0&&errno==EINTR);
 return rc==0;
}
static int peek_status(const siginfo_t *info,int *status) {
 if(!info->si_pid)return 0;
 if(info->si_code==CLD_EXITED)*status=info->si_status<<8;
 else if(info->si_code==CLD_KILLED)*status=info->si_status;
 else if(info->si_code==CLD_DUMPED)*status=info->si_status|128;
 else return 0;
 return valid_status((uint32_t)*status);
}
/* The broker never reaps between ownership proof and signalling. The unreaped
 * child's PID therefore cannot be recycled into an unrelated process/group. */
static int stop_owned(pid_t child) {
 siginfo_t info;
 if(child<=1||!owned_child(child,&info))return 0;
 if(getpgid(child)==child) {if(kill(-child,SIGKILL)<0&&errno!=ESRCH)return 0;}
 if(!info.si_pid&&kill(child,SIGKILL)<0&&errno!=ESRCH)return 0;
 return 1;
}
#if defined(__linux__) || defined(VPN_PROCESS_TEST)
/* Parse only a complete, unique PPid line from bounded procfs bytes. The value
 * is a discovery hint, NEVER the authority to send a signal. */
static int parse_ppid(const char *bytes,size_t length,pid_t *parent) {
 size_t pos=0;int found=0;
 while(pos<length){size_t end=pos;while(end<length&&bytes[end]!='\n')end++;
  if(end-pos>=5&&!memcmp(bytes+pos,"PPid:",5)){
   if(found||end==length)return 0;size_t i=pos+5;
   while(i<end&&(bytes[i]==' '||bytes[i]=='\t'))i++;
   unsigned value=0;size_t first=i;
   while(i<end&&bytes[i]>='0'&&bytes[i]<='9'){unsigned digit=(unsigned)(bytes[i++]-'0');if(value>((unsigned)INT_MAX-digit)/10)return 0;value=value*10+digit;}
   if(i==first)return 0;while(i<end&&(bytes[i]==' '||bytes[i]=='\t'))i++;
   if(i!=end)return 0;*parent=(pid_t)value;found=1;
  }
  pos=end<length?end+1:end;
 }
 return found;
}
/* linux_dirent64 uses a 19-byte fixed prefix. memcpy avoids unaligned access.
 * Return -1 for malformed records, 0 for non-PID names, 1 for a numeric PID. */
static int proc_record(const unsigned char *bytes,size_t length,size_t *step,pid_t *pid) {
 if(length<20)return -1;uint16_t reclen;memcpy(&reclen,bytes+16,sizeof reclen);
 if(reclen<20||reclen>length)return -1;*step=reclen;
 size_t end=19;while(end<reclen&&bytes[end])end++;if(end==reclen)return -1;
 if(end==19)return -1;unsigned value=0;
 for(size_t i=19;i<end;i++){
  if(bytes[i]<'0'||bytes[i]>'9')return 0;
  unsigned digit=(unsigned)(bytes[i]-'0');if(value>((unsigned)INT_MAX-digit)/10)return -1;value=value*10+digit;
 }
 if(value<=1)return 0;*pid=(pid_t)value;return 1;
}
#ifdef VPN_PROCESS_TEST
int vpn_process_test_parse_ppid(const char *s,size_t n,pid_t *p){return parse_ppid(s,n,p);}
int vpn_process_test_proc_record(const unsigned char *s,size_t n,size_t *step,pid_t *p){return proc_record(s,n,step,p);}
#endif
#endif
#ifdef __linux__
static void status_path(char path[40],pid_t pid) {
 char digits[24];size_t count=0,n=0;unsigned value=(unsigned)pid;
 do{digits[count++]=(char)('0'+value%10);value/=10;}while(value);
 while(count)path[n++]=digits[--count];memcpy(path+n,"/status",8);
}
/* Some B31 kernels do not expose task/children.
 * Enumerate procfs directly: no malloc, opendir, readdir or stdio after fork.
 * Directory/status races may remove a process. All other failures remain
 * cleanup_unknown; a complete scan alone is never proof of cleanup. */
static int kill_adopted_scan(uint64_t until) {
 int dir=open("/proc",O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(dir<0)return 0;
 unsigned char entries[8192];char status[8192];int good=1;size_t visited=0;
 for(;;){
  if(now_ms()>=until){good=0;break;}
  long n=syscall(SYS_getdents64,dir,entries,sizeof entries);
  if(n<0&&errno==EINTR)continue;if(n<0){good=0;break;}if(!n)break;
  size_t at=0;
  while(at<(size_t)n){
   if(now_ms()>=until||++visited>131072U){good=0;break;}
   size_t step=0;pid_t pid=0;int kind=proc_record(entries+at,(size_t)n-at,&step,&pid);
   if(kind<0){good=0;break;}at+=step;if(!kind||pid==getpid())continue;
   char path[40];status_path(path,pid);int fd=openat(dir,path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
   if(fd<0){if(errno==ENOENT||errno==ESRCH)continue;good=0;break;}
   size_t used=0;int read_ok=1,vanished=0;
   for(;;){if(now_ms()>=until){read_ok=0;break;}
    ssize_t got=read(fd,status+used,sizeof status-used);
    if(got<0&&errno==EINTR)continue;
    if(got<0){if(errno==ENOENT||errno==ESRCH)vanished=1;else read_ok=0;break;}
    if(!got)break;used+=(size_t)got;if(used==sizeof status){read_ok=0;break;}
   }
   close(fd);if(vanished)continue;if(!read_ok){good=0;break;}
   pid_t parent=0;if(!parse_ppid(status,used,&parent)){good=0;break;}
   if(parent==getpid()&&!stop_owned(pid)){good=0;break;}
  }
  if(!good)break;
 }
 close(dir);return good;
}
static void children_path(char path[80]) {
 const char prefix[]="/proc/self/task/";size_t n=sizeof prefix-1;
 memcpy(path,prefix,n);char digits[24];size_t count=0;unsigned value=(unsigned)getpid();
 do {digits[count++]=(char)('0'+value%10);value/=10;}while(value);
 while(count)path[n++]=digits[--count];
 memcpy(path+n,"/children",10);
}
/* Linux reparenting to this private subreaper also captures descendants that
 * setsid/setpgid away from the helper's original process group. */
static int kill_adopted(const char *path,uint64_t until) {
#ifdef VPN_PROCESS_TEST
 if(vpn_process_test_proc_fallback==1)return kill_adopted_scan(until);
 if(vpn_process_test_proc_fallback==2)return 0;
#endif
 int fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0)return kill_adopted_scan(until);
 char bytes[65537];size_t used=0;int ok=1;
 for(;;){ssize_t n=read(fd,bytes+used,sizeof bytes-used);if(n<0&&errno==EINTR)continue;
  if(n<0){ok=0;break;}if(!n)break;used+=(size_t)n;if(used==sizeof bytes){ok=0;break;}}
 close(fd);if(!ok)return 0;
 size_t i=0;
 while(i<used){while(i<used&&(bytes[i]==' '||bytes[i]=='\n'))i++;if(i==used)break;
  unsigned pid=0;size_t first=i;
  while(i<used&&bytes[i]>='0'&&bytes[i]<='9'){unsigned digit=(unsigned)(bytes[i++]-'0');if(pid>((unsigned)INT_MAX-digit)/10)return 0;pid=pid*10+digit;}
  if(i==first||(i<used&&bytes[i]!=' '&&bytes[i]!='\n')||pid<=1)return 0;
  if(!stop_owned((pid_t)pid))return 0;
 }
 return 1;
}
#endif
static int cleanup_owned(pid_t child,int *status,int *has_status) {
 int good=stop_owned(child);uint64_t until=now_ms()+VPN_PROCESS_CLEANUP_MS;
#ifdef __linux__
 char path[80];children_path(path);
#endif
 for(;;){
#ifdef __linux__
  if(!kill_adopted(path,until))good=0;
#endif
  int s;pid_t got;
  do {got=waitpid(-1,&s,WNOHANG);if(got==child){*status=s;*has_status=valid_status((uint32_t)s);}}while(got>0||(got<0&&errno==EINTR));
  if(got<0&&errno==ECHILD){
#ifdef __linux__
   return good;
#else
   /* No subreaper: same-group SIGKILL was sent, but escaped descendants cannot
    * be proven absent. Never promote that uncertainty to confirmed cleanup. */
   (void)good;
   return 0;
#endif
  }
  if(got<0)good=0;
  if(now_ms()>=until)return 0;
  struct timespec pause={0,10000000};nanosleep(&pause,NULL);
 }
}
static void send_proof(int status,int has_status,unsigned flags,int error) {
 uint32_t proof[PROOF_WORDS]={MAGIC,1U,(uint32_t)status,flags|(has_status?P_STATUS:0U),(uint32_t)error};
 size_t size=sizeof proof;
#ifdef VPN_PROCESS_TEST
 if(vpn_process_test_proof_mode==1)size=0;
 if(vpn_process_test_proof_mode==2)size--;
 if(vpn_process_test_proof_mode==3)proof[0]=0;
 if(vpn_process_test_proof_mode==5)proof[2]=0x10000U;
#endif
 size_t sent=0;while(sent<size){ssize_t n=write(3,(char*)proof+sent,size-sent);if(n<0&&errno==EINTR)continue;if(n<=0)break;sent+=(size_t)n;}
#ifdef VPN_PROCESS_TEST
 if(vpn_process_test_proof_mode==4)(void)write(3,"x",1);
#endif
 close(3);
}
static void broker(char *const argv[],int in,int out,int proof,int control,int fd_limit,uint64_t deadline) {
 /* Only async-signal-safe operations between fork and exec; signal dispositions
  * below belong exclusively to the private broker, never to the stock UI. */
 struct sigaction action;memset(&action,0,sizeof action);sigemptyset(&action.sa_mask);
 action.sa_handler=SIG_DFL;if(sigaction(SIGCHLD,&action,NULL))_exit(126);
 action.sa_handler=SIG_IGN;if(sigaction(SIGHUP,&action,NULL)||sigaction(SIGPIPE,&action,NULL))_exit(126);
 sigset_t mask;sigemptyset(&mask);if(sigprocmask(SIG_SETMASK,&mask,NULL))_exit(126);
 if(dup2(in,0)<0||dup2(out,1)<0||dup2(proof,3)<0||dup2(control,4)<0)_exit(126);
 int null=open("/dev/null",O_WRONLY);if(null<0||dup2(null,2)<0)_exit(126);if(null>4)close(null);
 close_above(5,fd_limit);
 int error=0;
 if(setsid()<0)error=errno;
#ifdef __linux__
 if(!error&&prctl(PR_SET_CHILD_SUBREAPER,1)<0)error=errno;
#endif
 if(!error&&nonblock(4)<0)error=errno;
 if(error){close(0);close(1);send_proof(-1,0,P_CLEAN|P_ABORT,error);_exit(1);}
 pid_t child=fork();
 if(child==0){if(setpgid(0,0)<0)_exit(126);close(3);close(4);execve(argv[0],argv,environ);_exit(127);}
 close(0);close(1);
 if(child<0){send_proof(-1,0,P_CLEAN|P_ABORT,errno);_exit(1);}
 /* Child performs setpgid before exec; redundant parent call narrows the
  * pre-exec race but is not relied on as ownership evidence for killing. */
 (void)setpgid(child,child);
 int status=-1,has_status=0,done=0,abort=0,timed_out=0;
 for(;;){
  siginfo_t info;
  if(!owned_child(child,&info)){error=errno;abort=1;break;}
  has_status=peek_status(&info,&status);
  char msg;ssize_t n=read(4,&msg,1);
  if(n==1){if(msg=='D'&&!done)done=1;else{abort=1;break;}}
  else if(!n){abort=1;break;}
  else if(errno!=EAGAIN&&errno!=EINTR){error=errno;abort=1;break;}
  if(done&&has_status)break;
  uint64_t now=now_ms();if(now>=deadline){timed_out=1;abort=1;break;}
  struct pollfd f={4,POLLIN,0};int wait=(int)(deadline-now);if(wait>10)wait=10;
  if(poll(&f,1,wait)<0&&errno!=EINTR){error=errno;abort=1;break;}
 }
 close(4);unsigned flags=0;
 if(abort){flags=P_ABORT|(timed_out?P_TIMEOUT:0U);if(cleanup_owned(child,&status,&has_status))flags|=P_CLEAN;}
 else {pid_t got;do{got=waitpid(child,&status,0);}while(got<0&&errno==EINTR);
  has_status=got==child&&valid_status((uint32_t)status);if(has_status)flags=P_CLEAN;else error=errno;}
 send_proof(status,has_status,flags,error);_exit(0);
}

void vpn_process_free(struct vpn_process_result *r){if(r){free(r->output);r->output=NULL;r->output_length=0;}}
int vpn_process_run(char *const argv[],const char *input,size_t length,unsigned timeout_ms,struct vpn_process_result *r) {
 if(!r)return 0;memset(r,0,sizeof *r);r->exit_status=-1;
 if(!argv||!argv[0]||(!input&&length)||length>VPN_PROCESS_INPUT_LIMIT||!timeout_ms||timeout_ms>600000U){r->write_errno=EINVAL;return 0;}
 uint64_t start=now_ms();if(!start){r->read_errno=EIO;return 0;}
 uint64_t deadline=start+timeout_ms,finish=deadline+VPN_PROCESS_CLEANUP_MS+250U;
 r->output=malloc(VPN_PROCESS_OUTPUT_LIMIT+1U);if(!r->output){r->read_errno=ENOMEM;return 0;}r->output[0]=0;
 int pipes[4][2]={{-1,-1},{-1,-1},{-1,-1},{-1,-1}},created=0;
 for(;created<4;created++)if(pipe_safe(pipes[created]))break;
 if(created<4){r->read_errno=errno;for(int i=0;i<created;i++){close(pipes[i][0]);close(pipes[i][1]);}return 0;}
 if(nonblock(pipes[0][1])||nonblock(pipes[1][0])||nonblock(pipes[2][0])||nonblock(pipes[3][1])){
  r->read_errno=errno;for(int i=0;i<4;i++){close(pipes[i][0]);close(pipes[i][1]);}return 0;
 }
 int fd_limit=4096;struct rlimit lim;
 if(!getrlimit(RLIMIT_NOFILE,&lim)&&lim.rlim_cur!=RLIM_INFINITY&&lim.rlim_cur<INT_MAX)fd_limit=(int)lim.rlim_cur;
 else {long n=sysconf(_SC_OPEN_MAX);if(n>0&&n<INT_MAX)fd_limit=(int)n;}
 pid_t pid=fork();
 if(pid==0)broker(argv,pipes[0][0],pipes[1][1],pipes[2][1],pipes[3][0],fd_limit,deadline);
 close(pipes[0][0]);close(pipes[1][1]);close(pipes[2][1]);close(pipes[3][0]);
 int input_fd=pipes[0][1],output_fd=pipes[1][0],proof_fd=pipes[2][0],control_fd=pipes[3][1];
 if(pid<0){r->wait_errno=errno;close(input_fd);close(output_fd);close(proof_fd);close(control_fd);return 0;}
 int abort=0,notified=0,output_eof=0,proof_eof=0,mask_set=0,had_sigpipe=0;
 sigset_t block,old,pending;sigemptyset(&block);sigaddset(&block,SIGPIPE);
 int err=pthread_sigmask(SIG_BLOCK,&block,&old);
 if(err){r->write_errno=err;abort=1;}else{mask_set=1;if(!sigpending(&pending))had_sigpipe=sigismember(&pending,SIGPIPE);}
 unsigned char proof[PROOF_WORDS*sizeof(uint32_t)+1];size_t proof_used=0,sent=0;
 for(;;){
  uint64_t now=now_ms();if(now>=deadline&&!notified){r->timed_out=1;abort=1;}
  if(abort&&input_fd>=0){close(input_fd);input_fd=-1;}
  if(input_fd>=0){if(sent<length){ssize_t n=write(input_fd,input+sent,length-sent);
    if(n>0)sent+=(size_t)n;else if(n<0&&errno!=EAGAIN&&errno!=EINTR){r->write_errno=errno;abort=1;}}
   if(sent==length){close(input_fd);input_fd=-1;}}
  unsigned char bytes[8192];
  if(!output_eof){size_t drained=0;for(;;){ssize_t n=read(output_fd,bytes,sizeof bytes);
    if(n>0){size_t room=VPN_PROCESS_OUTPUT_LIMIT-r->output_length,take=(size_t)n<room?(size_t)n:room;
     memcpy(r->output+r->output_length,bytes,take);r->output_length+=take;r->output[r->output_length]=0;
     if(take<(size_t)n){r->output_limit=1;abort=1;}drained+=(size_t)n;if(drained>=65536U)break;continue;}
    if(!n)output_eof=1;else if(errno!=EAGAIN&&errno!=EINTR){r->read_errno=errno;abort=1;output_eof=1;}break;}}
  if(!proof_eof){for(;;){unsigned char extra;void *dst=proof_used<sizeof proof?proof+proof_used:&extra;size_t room=proof_used<sizeof proof?sizeof proof-proof_used:1;
    ssize_t n=read(proof_fd,dst,room);if(n>0){if(proof_used<sizeof proof)proof_used+=(size_t)n;else proof_used=sizeof proof;continue;}
    if(!n)proof_eof=1;else if(errno!=EAGAIN&&errno!=EINTR){r->read_errno=errno;abort=1;proof_eof=1;}break;}}
  if(!notified&&(abort||(input_fd<0&&output_eof))){char msg=abort?'A':'D';
   ssize_t n=mask_set?write(control_fd,&msg,1):-1;
   if(n==1)notified=1;else if(!mask_set||(errno!=EINTR&&errno!=EAGAIN)){notified=1;close(control_fd);control_fd=-1;}}
  if(proof_eof&&output_eof)break;
  if(now_ms()>=finish){if(!r->read_errno)r->read_errno=ETIMEDOUT;abort=1;break;}
  struct pollfd f[3]={{input_fd,input_fd>=0?POLLOUT:0,0},{output_eof?-1:output_fd,POLLIN,0},{proof_eof?-1:proof_fd,POLLIN,0}};
  if(poll(f,3,10)<0&&errno!=EINTR){r->read_errno=errno;abort=1;}
 }
 if(input_fd>=0)close(input_fd);close(output_fd);close(proof_fd);if(control_fd>=0)close(control_fd);
 if(mask_set){if(!had_sigpipe&&!sigpending(&pending)&&sigismember(&pending,SIGPIPE)){int signal;sigwait(&block,&signal);}pthread_sigmask(SIG_SETMASK,&old,NULL);}
 if(proof_eof&&proof_used==PROOF_WORDS*sizeof(uint32_t)){
  uint32_t words[PROOF_WORDS];memcpy(words,proof,sizeof words);unsigned flags=words[3];
  if(words[0]==MAGIC&&words[1]==1U&&!(flags&~15U)&&words[4]<=INT_MAX&&(!(flags&P_STATUS)||valid_status(words[2]))){
   r->proof_valid=1;r->status_valid=!!(flags&P_STATUS);if(r->status_valid)r->exit_status=(int)words[2];
   r->timed_out|=!!(flags&P_TIMEOUT);r->cleanup_complete=!!(flags&P_CLEAN);r->broker_errno=(int)words[4];abort|=!!(flags&P_ABORT);
  }
 }
 if(!r->proof_valid&&!r->read_errno)r->read_errno=EBADMSG;
 int ignored;pid_t got;
 do {got=waitpid(pid,&ignored,WNOHANG);if(got==0&&now_ms()<finish){struct timespec pause={0,1000000};nanosleep(&pause,NULL);}}while((got==0&&now_ms()<finish)||(got<0&&errno==EINTR));
 if(got<0)r->wait_errno=errno;else if(!got)r->wait_errno=ETIMEDOUT;
 return !abort&&!r->read_errno&&!r->write_errno&&!r->broker_errno&&(!r->wait_errno||r->wait_errno==ECHILD)&&r->proof_valid&&r->status_valid&&r->cleanup_complete&&!r->timed_out&&!r->output_limit&&WIFEXITED(r->exit_status);
}
