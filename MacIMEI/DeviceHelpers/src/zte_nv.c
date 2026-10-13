/* Guarded MU5250 NV550 operations. Runtime plans contain one or two full
 * original[128] records followed by the same number of target[128] records. No private
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
#ifndef ZTE_SUPPORT_READONLY
#include "plan_io.h"
static uint8_t original[2][128],target[2][128];
static int last_nv_status=-1;
static int plan_count=2;
#endif

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
#ifdef ZTE_SUPPORT_READONLY
static unsigned valid_frames,bad_crc_frames;
static unsigned unmatched_frames,last_unmatched_opcode;
static size_t last_unmatched_length;
static int support_readable[3],support_alias;
#endif
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
#ifdef ZTE_SUPPORT_READONLY
        bad_crc_frames++;
#endif
        puts("PAIR_FRAME_BAD_CRC");return;
    }
    int match=n>=want_len&&!memcmp(frame,wanted,want_len);
    if(is_error(frame[0])&&n>=want_len+1&&!memcmp(frame+1,wanted,want_len)) match=1;
    if(match) {
#ifdef ZTE_SUPPORT_READONLY
        valid_frames++;
#endif
        memcpy(answer,frame,n);answer_len=n;pthread_cond_signal(&cond);
    }
#ifdef ZTE_SUPPORT_READONLY
    else { unmatched_frames++;last_unmatched_opcode=frame[0];last_unmatched_length=n; }
#endif
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
#ifdef ZTE_SUPPORT_READONLY
    /* No mutable command can reach DIAG in the research-only executable. */
    const uint8_t indexed[]={0x4b,0x30,1,0,0x26,2};
    const uint8_t legacy[]={0x26,0x26,2};
    if(interrupted) return 0;
    if(n==138&&header_len==8&&!memcmp(request,indexed,sizeof(indexed))&&request[6]<=1&&request[7]==0) {
        for(size_t i=8;i<n;i++) if(request[i]) return 0;
    } else if(n==133&&header_len==3&&!memcmp(request,legacy,sizeof(legacy))) {
        for(size_t i=3;i<n;i++) if(request[i]) return 0;
    } else return 0;
#endif
    pthread_mutex_lock(&mutex);
    memcpy(wanted,request,header_len);want_len=header_len;answer_len=0;
    frame_len=0;frame_escape=0;frame_bad=0;
#ifdef ZTE_SUPPORT_READONLY
    unmatched_frames=last_unmatched_opcode=0;last_unmatched_length=0;
#endif
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
#ifndef ZTE_SUPPORT_READONLY
    last_nv_status=sent==0?status:-1;
#endif
    printf("PAIR_REQUEST label=%s send=%d length=%zu status=%d diag_error=%d verified=%d\n",label,sent,answer_len,status,error,okay);
#ifdef ZTE_SUPPORT_READONLY
    printf("SUPPORT_NV_RESPONSE label=%s unmatched_frames=%u last_unmatched_length=%zu last_unmatched_opcode=%u\n",label,unmatched_frames,last_unmatched_length,last_unmatched_opcode);
#endif
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
#ifndef ZTE_SUPPORT_READONLY
static int write_item(int index,const uint8_t data[128],int restoring) {
    if(index<0||index>=plan_count) return 0;
    if(interrupted&&!restoring) return 0;
    if(memcmp(data,original[index],128)&&memcmp(data,target[index],128)) return 0;
    uint8_t req[138]={0x4b,0x30,2,0,0x26,2,0,0};
    req[6]=(uint8_t)index;memcpy(req+8,data,128);
    char label[40];snprintf(label,sizeof(label),"%s_index%d",restoring?"restore":"write",index);
    write_attempts++;
    return exchange(req,sizeof(req),8,NULL,label);
}
#endif
static int snapshot(uint8_t pair[2][128]) {
    uint8_t legacy[128];
    int a=read_item(0,pair[0]),b=read_item(1,pair[1]),c=read_item(-1,legacy);
    int alias=a&&c&&!memcmp(legacy,pair[0],128);
#ifdef ZTE_SUPPORT_READONLY
    support_readable[0]=a;support_readable[1]=b;support_readable[2]=c;support_alias=alias;
#endif
    printf("PAIR_SNAPSHOT readable=%d legacy_alias=%d\n",a&&b&&c,alias);
    return a&&b&&c&&alias;
}
#ifndef ZTE_SUPPORT_READONLY
static int same(const uint8_t a[2][128],const uint8_t b[2][128]) { return !memcmp(a,b,(size_t)plan_count*128); }
#endif
static int valid_imei_record(const uint8_t *p) {
    if(p[0]!=8||(p[1]&15)!=10) return 0;
    int digits[15],sum=0;digits[0]=p[1]>>4;
    for(int i=0;i<7;i++) { digits[1+2*i]=p[2+i]&15;digits[2+2*i]=p[2+i]>>4; }
    for(int i=0;i<15;i++) { int d=digits[i];if(d>9) return 0;if(i%2){d*=2;if(d>9)d-=9;}sum+=d; }
    return sum%10==0;
}
#ifndef ZTE_SUPPORT_READONLY
/* Exact NV_NOTACTIVE_S is the only accepted absence of NV1. Transport,
 * framing, DIAG and every other NV error remain failures. */
static int read_imeis(uint8_t records[2][128],int *secondary_active) {
    uint8_t legacy[128];
    int first=read_item(0,records[0]);
    int second=read_item(1,records[1]),second_status=last_nv_status;
    int alias=read_item(-1,legacy)&&first&&!memcmp(records[0],legacy,128);
    if(!first||!alias||(!second&&second_status!=5)) return 20;
    if(!valid_imei_record(records[0])||(second&&!valid_imei_record(records[1]))) return 23;
    *secondary_active=second;
    return 0;
}
static int snapshot_available(uint8_t records[2][128],int required_count) {
    int active=0;
    if(read_imeis(records,&active)!=0) return 0;
    int count=active?2:1;
    if(required_count&&count!=required_count) { puts("APP_NV_TOPOLOGY_CHANGED");return 0; }
    return count;
}
static int plan_snapshot(uint8_t records[2][128]) { return snapshot_available(records,plan_count)!=0; }
static void print_imei(int index,const uint8_t *record) {
    printf("APP_IMEI index=%d value=%u",index,(unsigned)(record[1]>>4));
    for(int i=2;i<9;i++) printf("%u%u",(unsigned)(record[i]&15),(unsigned)(record[i]>>4));
    putchar('\n');
}
static int plan_valid(void) {
    for(int i=0;i<plan_count;i++) if(!valid_imei_record(original[i])||
        !valid_imei_record(target[i])||memcmp(original[i]+9,target[i]+9,119)) return 0;
    return plan_count==1||memcmp(target[0],target[1],9)!=0;
}
static int load_plan(const char *path) {
    uint8_t bytes[512];
    /* Legacy pair plans are exactly 512 bytes; single plans are 256 bytes.
     * Both contain complete original records followed by complete targets. */
    if(read_exact_plan(path,bytes,sizeof(bytes))) plan_count=2;
    else if(read_exact_plan(path,bytes,256)) plan_count=1;
    else return 0;
    memset(original,0,sizeof(original));memset(target,0,sizeof(target));
    memcpy(original,bytes,(size_t)plan_count*128);memcpy(target,bytes+plan_count*128,(size_t)plan_count*128);
    return plan_valid();
}
#endif
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
#ifndef ZTE_SUPPORT_READONLY
static int restore_originals(void) {
    uint8_t state[2][128],record[128];
    if(!plan_snapshot(state)) return 0;
    for(int i=plan_count-1;i>=0;i--) {
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
    int okay=plan_snapshot(state)&&same(state,original);
    printf("PAIR_ORIGINALS_RESTORED %d\n",okay);return okay;
}
/* Explicit recovery may start after a reboot or a previous process exit.
 * Refuse the complete operation unless every byte in each active slot is known.
 * This is separate from the existing apply failure recovery above.
 */
static int restore_known_pair(const uint8_t baseline[2][128]) {
    uint8_t expected[2][128],state[2][128];
    for(int i=0;i<plan_count;i++) {
        if(memcmp(baseline[i],original[i],128)&&memcmp(baseline[i],target[i],128)) {
            printf("PAIR_EXPLICIT_RESTORE_UNKNOWN_SLOT %d\n",i);return 0;
        }
    }
    memcpy(expected,baseline,sizeof(expected));
    for(int i=plan_count-1;i>=0;i--) {
        if(!memcmp(expected[i],original[i],128)) continue;
        int ack=write_item(i,original[i],1);
        int readable=plan_snapshot(state);
        memcpy(expected[i],original[i],128);
        int matches=readable&&same(state,expected);
        printf("PAIR_EXPLICIT_RESTORE index=%d ack=%d complete_state_matches=%d\n",i,ack,matches);
        if(!ack||!matches) return 0;
    }
    puts("PAIR_EXPLICIT_ORIGINALS_VERIFIED 1");return 1;
}
#endif
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IOLBF,0);
#ifdef ZTE_SUPPORT_READONLY
    if(argc!=2||strcmp(argv[1],"--inspect-nv550")) return 2;
    puts("SUPPORT_NV_V1");
#else
    int export_snapshot=argc==2&&!strcmp(argv[1],"--snapshot");
    int available_snapshot=argc==2&&!strcmp(argv[1],"--snapshot-available"),available_count=0;
    int read_imei=argc==2&&!strcmp(argv[1],"--read-imei"),secondary_active=0;
    int apply=argc==3&&!strcmp(argv[1],"--apply-plan");
    int verify=argc==3&&!strcmp(argv[1],"--verify-plan");
    int check=argc==3&&!strcmp(argv[1],"--check-plan-original");
    int restore=argc==3&&!strcmp(argv[1],"--restore-plan-original");
    if(!export_snapshot&&!available_snapshot&&!read_imei&&!apply&&!verify&&!check&&!restore) return 2;
    if(!export_snapshot&&!available_snapshot&&!read_imei&&!load_plan(argv[2])) { puts("PAIR_PLAN_VALIDATION_FAILED");return 3; }
#endif
    struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=interrupt_handler;sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGTERM,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
    alarm(120);
    void *lib=dlopen("/usr/lib/libdiag.so.1",RTLD_NOW|RTLD_LOCAL);
#ifdef ZTE_SUPPORT_READONLY
    printf("SUPPORT_NV_LOAD library=%d\n",lib!=NULL);
#endif
    if(!lib) return 4;
    unsigned char (*init_fn)(unsigned char*)=dlsym(lib,"Diag_LSM_Init");
    void (*register_fn)(int(*)(unsigned char*,int,void*),void*)=dlsym(lib,"diag_register_callback");
    deinit_fn=dlsym(lib,"Diag_LSM_DeInit");send_fn=dlsym(lib,"diag_callback_send_data");
    ioctl_fn=dlsym(lib,"diag_lsm_comm_ioctl");diag_fd=dlsym(lib,"diag_fd");logging_mode=dlsym(lib,"logging_mode");
#ifdef ZTE_SUPPORT_READONLY
    printf("SUPPORT_NV_SYMBOLS init=%d deinit=%d callback=%d send=%d ioctl=%d fd=%d mode=%d\n",init_fn!=NULL,deinit_fn!=NULL,register_fn!=NULL,send_fn!=NULL,ioctl_fn!=NULL,diag_fd!=NULL,logging_mode!=NULL);
#endif
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
    uint8_t state[2][128];
#ifndef ZTE_SUPPORT_READONLY
    uint8_t expected_state[2][128];
#endif
    int outcome=20;
#ifndef ZTE_SUPPORT_READONLY
    if(read_imei) { outcome=read_imeis(state,&secondary_active);goto finish; }
    if(available_snapshot) { available_count=snapshot_available(state,0);outcome=available_count?0:20;goto finish; }
    if(export_snapshot ? !snapshot(state) : !plan_snapshot(state)) goto finish;
#else
    if(!snapshot(state)) goto finish;
#endif
#ifdef ZTE_SUPPORT_READONLY
    outcome=valid_imei_record(state[0])&&valid_imei_record(state[1])?0:23;
#else
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
    for(int i=0;i<plan_count;i++) {
        int ack=write_item(i,target[i],0);
        int readable=plan_snapshot(state);
        memcpy(expected_state[i],target[i],128);
        int matches=readable&&same(state,expected_state);
        printf("PAIR_STEP index=%d ack=%d complete_state_matches=%d\n",i,ack,matches);
        if(!ack||!matches||interrupted) { outcome=restore_originals()?30:31;goto finish; }
    }
    puts("PAIR_TARGETS_VERIFIED 1");outcome=0;
#endif
finish:
#ifdef ZTE_SUPPORT_READONLY
    for(int i=0;i<2;i++) printf("SUPPORT_NV_RECORD index=%d readable=%d encoding_valid=%d\n",i,support_readable[i],support_readable[i]?valid_imei_record(state[i]):-1);
    printf("SUPPORT_NV_STRUCTURE legacy_readable=%d legacy_alias=%d crc_verified_frames=%u bad_crc_frames=%u\n",support_readable[2],support_alias,valid_frames,bad_crc_frames);
#endif
    { int released=release_session();
      int closed=deinit_fn();
      printf("PAIR_RESULT outcome=%d write_attempts=%u released=%d deinit=%d signal=%d\n",outcome,write_attempts,released,closed,(int)interrupted);
#ifdef ZTE_SUPPORT_READONLY
      printf("SUPPORT_NV_RESULT outcome=%d released=%d deinit=%d writes=0\n",(!released||!closed)?40:(interrupted&&outcome==0)?41:outcome,released,closed);
#endif
      if(!released||!closed) return 40;
    }
    alarm(0);
    if(interrupted&&outcome==0) return 41;
#ifndef ZTE_SUPPORT_READONLY
    if(read_imei&&outcome==0) {
        print_imei(0,state[0]);
        if(secondary_active) print_imei(1,state[1]);
        else puts("APP_IMEI index=1 state=not-active nv_status=5");
    }
    if((export_snapshot||available_snapshot)&&outcome==0) for(int i=0;i<(export_snapshot?2:available_count);i++) {
        printf("APP_NV index=%d data=",i);
        for(int j=0;j<128;j++) printf("%02x",state[i][j]);
        putchar('\n');
    }
    if(available_snapshot&&outcome==0) printf("APP_NV_TOPOLOGY count=%d secondary=%s\n",available_count,available_count==1?"not-active-status5":"active");
#endif
    return outcome;
}
