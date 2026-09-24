/* Guarded MU5250 B31 NV550 pair operations. Runtime plans contain exactly
 * original0[128], original1[128], target0[128], target1[128]. No private
 * records are embedded. No SPC, auth, legacy-write or partition operations.
 */
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "plan_io.h"
static uint8_t original[2][128],target[2][128];

struct logging_params { uint32_t mode,mask,pd; uint8_t mode_param,diag_id,pd_val,reserved; int32_t peripheral,device; };
struct query_params { uint32_t mask,pd; int32_t pid,device,kill_op,kill_count; };
_Static_assert(sizeof(struct logging_params)==24,"logging ABI");
_Static_assert(sizeof(struct query_params)==24,"query ABI");
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static uint8_t wanted[8],answer[4096],frame[4096];
static size_t want_len=0,answer_len=0,frame_len=0;
static int frame_escape=0,frame_bad=0;
static unsigned char (*deinit_fn)(void);
static int (*send_fn)(int,unsigned char*,int);
static int (*ioctl_fn)(int,unsigned long,void*,unsigned int);
static int *diag_fd,*logging_mode;
static unsigned write_attempts=0;
static volatile sig_atomic_t interrupted=0;
static void interrupt_handler(int sig) { interrupted=sig; }

static uint16_t crc16(const uint8_t *p,size_t n) {
    uint16_t crc=0xffff;
    for(size_t i=0;i<n;i++) {
        crc^=p[i];
        for(int j=0;j<8;j++) crc=(crc&1)?(uint16_t)((crc>>1)^0x8408):(uint16_t)(crc>>1);
    }
    return (uint16_t)~crc;
}
static int is_error(uint8_t v) { return (v>=0x13&&v<=0x18)||v==0x42||v==0x47; }
static void accept_frame(void) {
    if(frame_bad||frame_escape||frame_len<3||!want_len||answer_len) return;
    size_t n=frame_len-2;
    if(crc16(frame,n)!=(uint16_t)(frame[n]|((uint16_t)frame[n+1]<<8))) {
        puts("PAIR_FRAME_BAD_CRC");return;
    }
    int match=n>=want_len&&!memcmp(frame,wanted,want_len);
    if(is_error(frame[0])&&n>=want_len+1&&!memcmp(frame+1,wanted,want_len)) match=1;
    if(match) { memcpy(answer,frame,n);answer_len=n;pthread_cond_signal(&cond); }
}
static int callback(unsigned char *p,int n,void *ctx) {
    (void)ctx;
    if(!p||n<=0) return 0;
    pthread_mutex_lock(&mutex);
    for(int i=0;i<n;i++) {
        uint8_t v=p[i];
        if(v==0x7e) { accept_frame();frame_len=0;frame_escape=0;frame_bad=0;continue; }
        if(frame_bad) continue;
        if(frame_escape) { v^=0x20;frame_escape=0; }
        else if(v==0x7d) { frame_escape=1;continue; }
        if(frame_len==sizeof(frame)) { frame_bad=1;continue; }
        frame[frame_len++]=v;
    }
    pthread_mutex_unlock(&mutex);
    return 0;
}
static int exchange(uint8_t *request,size_t n,size_t header_len,uint8_t *data,const char *label) {
    pthread_mutex_lock(&mutex);
    memcpy(wanted,request,header_len);want_len=header_len;answer_len=0;
    frame_len=0;frame_escape=0;frame_bad=0;
    pthread_mutex_unlock(&mutex);
    int sent=send_fn(0,request,(int)n);
    struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=4;
    pthread_mutex_lock(&mutex);
    while(!answer_len&&sent==0) {
        int r=pthread_cond_timedwait(&cond,&mutex,&until);
        if(r!=0) break;
    }
    int status=-1,error=-1,okay=0;
    if(answer_len&&is_error(answer[0])) error=answer[0];
    else if(answer_len==n&&!memcmp(answer,request,header_len)) {
        status=answer[n-2]|((int)answer[n-1]<<8);
        if(status==0&&sent==0) { if(data) memcpy(data,answer+header_len,128);okay=1; }
    }
    printf("PAIR_REQUEST label=%s send=%d length=%zu status=%d diag_error=%d verified=%d\n",label,sent,answer_len,status,error,okay);
    want_len=0;
    pthread_mutex_unlock(&mutex);
    return okay;
}
static int read_item(int index,uint8_t data[128]) {
    uint8_t req[138]={0};char label[32];
    if(index<0) {
        req[0]=0x26;req[1]=0x26;req[2]=2;
        return exchange(req,133,3,data,"read_legacy");
    }
    req[0]=0x4b;req[1]=0x30;req[2]=1;req[4]=0x26;req[5]=2;req[6]=(uint8_t)index;
    snprintf(label,sizeof(label),"read_index%d",index);
    return exchange(req,sizeof(req),8,data,label);
}
static int write_item(int index,const uint8_t data[128],int restoring) {
    if(index<0||index>1) return 0;
    if(interrupted&&!restoring) return 0;
    if(memcmp(data,original[index],128)&&memcmp(data,target[index],128)) return 0;
    uint8_t req[138]={0x4b,0x30,2,0,0x26,2,0,0};
    req[6]=(uint8_t)index;memcpy(req+8,data,128);
    char label[40];snprintf(label,sizeof(label),"%s_index%d",restoring?"restore":"write",index);
    write_attempts++;
    return exchange(req,sizeof(req),8,NULL,label);
}
static int snapshot(uint8_t pair[2][128]) {
    uint8_t legacy[128];
    int a=read_item(0,pair[0]),b=read_item(1,pair[1]),c=read_item(-1,legacy);
    int alias=a&&c&&!memcmp(legacy,pair[0],128);
    printf("PAIR_SNAPSHOT readable=%d legacy_alias=%d\n",a&&b&&c,alias);
    return a&&b&&c&&alias;
}
static int same(const uint8_t a[2][128],const uint8_t b[2][128]) { return !memcmp(a,b,256); }
static int valid_imei_record(const uint8_t *p) {
    if(p[0]!=8||(p[1]&15)!=10) return 0;
    int digits[15],sum=0;digits[0]=p[1]>>4;
    for(int i=0;i<7;i++) { digits[1+2*i]=p[2+i]&15;digits[2+2*i]=p[2+i]>>4; }
    for(int i=0;i<15;i++) { int d=digits[i];if(d>9) return 0;if(i%2){d*=2;if(d>9)d-=9;}sum+=d; }
    return sum%10==0;
}
static int plan_valid(void) {
    for(int i=0;i<2;i++) if(!valid_imei_record(original[i])||
        !valid_imei_record(target[i])||memcmp(original[i]+9,target[i]+9,119)) return 0;
    return memcmp(target[0],target[1],9)!=0;
}
static int load_plan(const char *path) {
    uint8_t bytes[512];
    if(!read_exact_plan(path,bytes,sizeof(bytes))) return 0;
    memcpy(original,bytes,256);memcpy(target,bytes+256,256);
    return plan_valid();
}
static int query_owner(void) {
    struct query_params q={2,0,-22,1,0,0};
    int r=ioctl_fn(*diag_fd,41,&q,sizeof(q));
    printf("PAIR_OWNER ret=%d pid=%d self=%d\n",r,q.pid,(int)getpid());
    return r==0?q.pid:-22;
}
static int release_session(void) {
    for(int attempt=0;attempt<2;attempt++) {
        int owner=query_owner();
        if(owner<0) owner=query_owner();
        if(owner!=(int)getpid()) { puts("PAIR_RELEASE_OWNERSHIP_UNCERTAIN");return 0; }
        struct logging_params lp={1,2,0,1,0,0,0,-22,1};
        int r=ioctl_fn(*diag_fd,7,&lp,sizeof(lp));
        if(r==0) *logging_mode=1;
        owner=query_owner();
        if(owner<0) owner=query_owner();
        printf("PAIR_RELEASE ret=%d owner=%d local_mode=%d\n",r,owner,*logging_mode);
        if(r==0&&owner==0) return 1;
        if(owner!=(int)getpid()) return 0;
    }
    return 0;
}
static int restore_originals(void) {
    uint8_t state[2][128],record[128];
    for(int i=1;i>=0;i--) {
        if(!read_item(i,record)) { printf("PAIR_ROLLBACK_SLOT_UNREADABLE %d\n",i);continue; }
        if(memcmp(record,original[i],128)) {
            if(memcmp(record,target[i],128)) {
                printf("PAIR_ROLLBACK_UNKNOWN_SLOT %d\n",i);continue;
            }
            int ack=write_item(i,original[i],1);
            int readable=read_item(i,record);
            printf("PAIR_RESTORE index=%d ack=%d original_matches=%d\n",i,ack,readable&&!memcmp(record,original[i],128));
        }
    }
    int okay=snapshot(state)&&same(state,original);
    printf("PAIR_ORIGINALS_RESTORED %d\n",okay);return okay;
}
/* Explicit recovery may start after a reboot or a previous process exit.
 * Refuse the complete operation unless every byte in both slots is known.
 * This is separate from the existing apply failure recovery above.
 */
static int restore_known_pair(const uint8_t baseline[2][128]) {
    uint8_t expected[2][128],state[2][128];
    for(int i=0;i<2;i++) {
        if(memcmp(baseline[i],original[i],128)&&memcmp(baseline[i],target[i],128)) {
            printf("PAIR_EXPLICIT_RESTORE_UNKNOWN_SLOT %d\n",i);return 0;
        }
    }
    memcpy(expected,baseline,sizeof(expected));
    for(int i=1;i>=0;i--) {
        if(!memcmp(expected[i],original[i],128)) continue;
        int ack=write_item(i,original[i],1);
        int readable=snapshot(state);
        memcpy(expected[i],original[i],128);
        int matches=readable&&same(state,expected);
        printf("PAIR_EXPLICIT_RESTORE index=%d ack=%d complete_state_matches=%d\n",i,ack,matches);
        if(!ack||!matches) return 0;
    }
    puts("PAIR_EXPLICIT_ORIGINALS_VERIFIED 1");return 1;
}
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IOLBF,0);
    int export_snapshot=argc==2&&!strcmp(argv[1],"--snapshot");
    int apply=argc==3&&!strcmp(argv[1],"--apply-plan");
    int verify=argc==3&&!strcmp(argv[1],"--verify-plan");
    int check=argc==3&&!strcmp(argv[1],"--check-plan-original");
    int restore=argc==3&&!strcmp(argv[1],"--restore-plan-original");
    if(!export_snapshot&&!apply&&!verify&&!check&&!restore) return 2;
    if(!export_snapshot&&!load_plan(argv[2])) { puts("PAIR_PLAN_VALIDATION_FAILED");return 3; }
    struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=interrupt_handler;sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGTERM,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
    alarm(120);
    void *lib=dlopen("/usr/lib/libdiag.so.1",RTLD_NOW|RTLD_LOCAL);
    if(!lib) return 4;
    unsigned char (*init_fn)(unsigned char*)=dlsym(lib,"Diag_LSM_Init");
    void (*register_fn)(int(*)(unsigned char*,int,void*),void*)=dlsym(lib,"diag_register_callback");
    deinit_fn=dlsym(lib,"Diag_LSM_DeInit");send_fn=dlsym(lib,"diag_callback_send_data");
    ioctl_fn=dlsym(lib,"diag_lsm_comm_ioctl");diag_fd=dlsym(lib,"diag_fd");logging_mode=dlsym(lib,"logging_mode");
    if(!init_fn||!deinit_fn||!register_fn||!send_fn||!ioctl_fn||!diag_fd||!logging_mode) return 5;
    if(!init_fn(NULL)) return 6;
    register_fn(callback,NULL);
    if(*logging_mode!=1||query_owner()!=0) { deinit_fn();return 7; }
    struct logging_params lp={6,2,0,1,0,0,0,-22,1};
    int opened=ioctl_fn(*diag_fd,7,&lp,sizeof(lp));
    printf("PAIR_SESSION_OPEN %d\n",opened);
    if(opened!=0) { deinit_fn();return 8; }
    *logging_mode=6;
    int owner=query_owner();if(owner<0) owner=query_owner();
    if(owner!=(int)getpid()) {
        puts("PAIR_OPEN_OWNERSHIP_UNCERTAIN");
        printf("PAIR_EARLY_RELEASE %d\n",release_session());deinit_fn();return 9;
    }
    uint8_t state[2][128],expected_state[2][128];
    int outcome=20;
    if(!snapshot(state)) goto finish;
    if(export_snapshot) {
        outcome=valid_imei_record(state[0])&&valid_imei_record(state[1])?0:23;
        goto finish;
    }
    printf("PAIR_BASELINE originals=%d targets=%d\n",same(state,original),same(state,target));
    if(verify) { outcome=same(state,target)?0:21;goto finish; }
    if(restore) { outcome=restore_known_pair(state)?0:32;goto finish; }
    if(!same(state,original)) { outcome=22;goto finish; }
    if(check) { outcome=0;goto finish; }
    memcpy(expected_state,original,256);
    for(int i=0;i<2;i++) {
        int ack=write_item(i,target[i],0);
        int readable=snapshot(state);
        memcpy(expected_state[i],target[i],128);
        int matches=readable&&same(state,expected_state);
        printf("PAIR_STEP index=%d ack=%d complete_state_matches=%d\n",i,ack,matches);
        if(!ack||!matches||interrupted) { outcome=restore_originals()?30:31;goto finish; }
    }
    puts("PAIR_TARGETS_VERIFIED 1");outcome=0;
finish:
    { int released=release_session();
      int closed=deinit_fn();
      printf("PAIR_RESULT outcome=%d write_attempts=%u released=%d deinit=%d signal=%d\n",outcome,write_attempts,released,closed,(int)interrupted);
      if(!released||!closed) return 40;
    }
    alarm(0);
    if(interrupted&&outcome==0) return 41;
    if(export_snapshot&&outcome==0) for(int i=0;i<2;i++) {
        printf("APP_NV index=%d data=",i);
        for(int j=0;j<128;j++) printf("%02x",state[i][j]);
        putchar('\n');
    }
    return outcome;
}
