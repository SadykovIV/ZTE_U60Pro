#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failed, checks;
static double now(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (double)t.tv_sec+t.tv_nsec/1e9; }
static void delay(long ms) { struct timespec t={ms/1000,ms%1000*1000000};while(nanosleep(&t,&t)<0&&errno==EINTR){} }
static void pidfile(const char *path,pid_t pid) { FILE*f=fopen(path,"w");if(!f)_exit(90);fprintf(f,"%d\n",pid);fclose(f); }
static pid_t readpid(const char *path) { FILE*f=fopen(path,"r");int p=0;if(f){fscanf(f,"%d",&p);fclose(f);}return p; }
static int waitfile(const char *path) { for(int i=0;i<300;i++){if(readpid(path)>1)return 0;delay(10);}return -1; }
static void check(int ok,const char *name) {checks++;if(!ok)failed++;printf("HOST_TIMEOUT_%s %s\n",ok?"PASS":"FAIL",name);}
static int waitcode(pid_t p) {int s;if(waitpid(p,&s,0)!=p)return 125;return WIFEXITED(s)?WEXITSTATUS(s):128+WTERMSIG(s);}
static pid_t launch(char *const args[],int inherited) {pid_t p=fork();if(p==0){if(inherited){signal(SIGCHLD,SIG_IGN);sigset_t mask;sigemptyset(&mask);sigaddset(&mask,SIGTERM);sigprocmask(SIG_BLOCK,&mask,NULL);}execv(args[0],args);_exit(111);}return p;}
static int run(char *const args[]) {return waitcode(launch(args,0));}
static int dead(pid_t p) {return p>1&&kill(p,0)<0&&errno==ESRCH;}
static void loop(void) {for(;;)pause();}

static int fixture(int argc,char**argv) {
 const char *mode=argv[2];
 if(!strcmp(mode,"exit"))return atoi(argv[3]);
 if(!strcmp(mode,"args"))return argc==8&&!strcmp(argv[3],"space value")&&!strcmp(argv[4],"'quoted'")&&!strcmp(argv[5],"$(touch /tmp/not-created)")&&!strcmp(argv[6],"semi;colon")&&!strcmp(argv[7],"")?0:91;
 if(!strcmp(mode,"signal")){raise(SIGUSR1);return 92;}
 if(!strcmp(mode,"sleep")){if(argc>3)pidfile(argv[3],getpid());loop();}
 if(!strcmp(mode,"ignore")){signal(SIGTERM,SIG_IGN);if(argc>3)pidfile(argv[3],getpid());loop();}
 if(!strcmp(mode,"tree")||!strcmp(mode,"orphan")) {
  int pipefd[2];if(pipe(pipefd))return 93;
  signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);signal(SIGHUP,SIG_IGN);
  pidfile(argv[3],getpid());
  pid_t child=fork();if(child<0)return 94;
  if(!child){close(pipefd[0]);pidfile(argv[4],getpid());write(pipefd[1],"Y",1);close(pipefd[1]);loop();}
  close(pipefd[1]);char ready;if(read(pipefd[0],&ready,1)!=1)return 95;close(pipefd[0]);
  if(!strcmp(mode,"orphan"))return 19;
  loop();
 }
 return 96;
}

static void interruption_case(int signo,const char *label,int inherited) {
 char parent[80],desc[80];snprintf(parent,sizeof parent,"/tmp/%s-parent",label);snprintf(desc,sizeof desc,"/tmp/%s-desc",label);
 char *args[]={"/zte-timeout","10","/fixture","--fixture","tree",parent,desc,NULL};
 pid_t helper=launch(args,inherited);
 check(waitfile(parent)==0&&waitfile(desc)==0,label);
 pid_t a=readpid(parent),b=readpid(desc);double start=now();kill(helper,signo);
 int code=waitcode(helper);double elapsed=now()-start;
 char result[120];snprintf(result,sizeof result,"%s exit-code-and-bounded-cleanup",label);
 check(code==128+signo&&elapsed<1.8,result);
 snprintf(result,sizeof result,"%s descendants-gone",label);check(dead(a)&&dead(b),result);
}

static int tests(void) {
 printf("HOST_TIMEOUT_VM_BEGIN\n");
 char *version[]={"/zte-timeout","--version",NULL};check(run(version)==0,"version");
 const char *invalid[]={"0","-1","1.5","86401","","999999999999999999999999"};
 for(unsigned i=0;i<sizeof invalid/sizeof invalid[0];i++){char *args[]={"/zte-timeout",(char*)invalid[i],"/fixture","--fixture","exit","0",NULL};check(run(args)==125,"invalid-deadline");}
 char *usage[]={"/zte-timeout",NULL};check(run(usage)==125,"missing-arguments");
 char *success[]={"/zte-timeout","2","/fixture","--fixture","exit","0",NULL};check(run(success)==0,"preserves-success");
 char *failure[]={"/zte-timeout","2","/fixture","--fixture","exit","37",NULL};check(run(failure)==37,"preserves-exit37");
 char *missing[]={"/zte-timeout","2","/missing-program",NULL};check(run(missing)==127,"missing-executable127");
 int fd=open("/tmp/noexec",O_CREAT|O_WRONLY,0600);write(fd,"x",1);close(fd);
 char *noexec[]={"/zte-timeout","2","/tmp/noexec",NULL};check(run(noexec)==126,"non-executable126");
 char *args[]={"/zte-timeout","2","/fixture","--fixture","args","space value","'quoted'","$(touch /tmp/not-created)","semi;colon","",NULL};check(run(args)==0&&access("/tmp/not-created",F_OK)<0,"preserves-argv-without-shell");
 char *sig[]={"/zte-timeout","2","/fixture","--fixture","signal",NULL};check(run(sig)==128+SIGUSR1,"preserves-child-signal");
 char *sleep[]={"/zte-timeout","1","/fixture","--fixture","sleep",NULL};double start=now();int code=run(sleep);check(code==124&&now()-start>=.9&&now()-start<2,"monotonic-timeout124");
 char *ignore[]={"/zte-timeout","1","/fixture","--fixture","ignore",NULL};start=now();code=run(ignore);double elapsed=now()-start;check(code==124&&elapsed>=1.2&&elapsed<2.2,"term-ignore-escalates-kill");
 char *tree[]={"/zte-timeout","1","/fixture","--fixture","tree","/tmp/tree-parent","/tmp/tree-desc",NULL};check(run(tree)==124,"tree-timeout124");check(dead(readpid("/tmp/tree-parent"))&&dead(readpid("/tmp/tree-desc")),"timeout-removes-descendants");
 char *orphan[]={"/zte-timeout","2","/fixture","--fixture","orphan","/tmp/orphan-parent","/tmp/orphan-desc",NULL};start=now();check(run(orphan)==19&&now()-start<1,"normal-exit-preserved-with-descendant-cleanup");check(dead(readpid("/tmp/orphan-desc")),"normal-exit-removes-orphaned-grandchild");
 interruption_case(SIGTERM,"external-term",0);
 interruption_case(SIGINT,"external-int",0);
 interruption_case(SIGHUP,"external-hup",0);
 interruption_case(SIGTERM,"inherited-ignore-and-blocked-term",1);
 pid_t caller=fork();if(!caller){char *a[]={"/zte-timeout","10","/fixture","--fixture","tree","/tmp/death-parent","/tmp/death-desc",NULL};pid_t helper=launch(a,0);pidfile("/tmp/death-helper",helper);_exit(waitcode(helper));}
 check(waitfile("/tmp/death-helper")==0&&waitfile("/tmp/death-desc")==0,"parent-death-fixture-ready");
 pid_t helper=readpid("/tmp/death-helper"),parent=readpid("/tmp/death-parent"),desc=readpid("/tmp/death-desc");start=now();kill(caller,SIGKILL);waitcode(caller);code=waitcode(helper);
 check(code==143&&now()-start<1.8,"parent-death-initiates-bounded-cleanup");check(dead(parent)&&dead(desc),"parent-death-descendants-gone");
 printf("HOST_TIMEOUT_VM_RESULT checks=%d failures=%d\n",checks,failed);
 return failed?1:0;
}

int main(int argc,char**argv) {
 setbuf(stdout,NULL);setbuf(stderr,NULL);
 if(argc>2&&!strcmp(argv[1],"--fixture"))return fixture(argc,argv);
 mount("proc","/proc","proc",0,NULL);mkdir("/tmp",0700);
 alarm(40);int code=tests();printf("HOST_TIMEOUT_VM_EXIT %d\n",code);sync();reboot(RB_POWER_OFF);return code;
}
