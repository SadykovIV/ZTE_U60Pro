/* Guarded MU5250 B31 EFS /config replacement. No NV/auth/radio operations.
 * Runtime exact original/candidate differ only at flag102 offset499 and CRC.
 * /config can be opened only READONLY; replacement is a single EFS RENAME14
 * from a verified, exclusively-created sibling. Preverified rollback sibling.
 * All writes constrained to validated plan bytes in owned temporary files.
 * This binary does not reboot or apply IMEI changes.
 */
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "plan_io.h"
#define CONFIG_SIZE 15073u
static uint8_t config_original[CONFIG_SIZE],config_candidate[CONFIG_SIZE];
#define CHUNK_SIZE 1024u
static const char config_path[]="/config";
static const char stage_path[]="/codex_cfg_stage_09b1f7a5d4372e80";
static const char rollback_path[]="/codex_cfg_rollback_09b1f7a5d4372e80";
static const uint8_t *before_bytes,*after_bytes;
static int file_fd=-1,file_access,file_index,owned_stage,owned_rollback;
static int commit_ready,commit_attempted,rollback_ready,rolling_back;
static uint16_t sync_sequence;
static uint32_t sync_token;
static unsigned send_count;
struct logging_params { uint32_t mode,mask,pd; uint8_t mode_param,diag_id,pd_val,reserved; int32_t peripheral,device; };
struct query_params { uint32_t mask,pd; int32_t pid,device,kill_op,kill_count; };
struct file_stat { uint32_t mode,size,nlink,atime,mtime,ctime; };
_Static_assert(sizeof(struct logging_params)==24,"logging ABI");
_Static_assert(sizeof(struct query_params)==24,"query ABI");
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static uint8_t wanted[4],answer[4096],frame[4096];
static size_t answer_len,frame_len;
static int pending,frame_escape,frame_bad;
static unsigned valid_frames,bad_crc_frames;
static volatile sig_atomic_t interrupted;
static unsigned char (*deinit_fn)(void);
static int (*send_fn)(int,unsigned char*,int);
static int (*ioctl_fn)(int,unsigned long,void*,unsigned int);
static int *diag_fd,*logging_mode;

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static void put32(uint8_t *p,uint32_t n) {
    for(unsigned i=0;i<4;i++) p[i]=(uint8_t)(n>>(8*i));
}
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
    if(frame_bad||frame_escape||frame_len<3||!pending||answer_len) return;
    size_t n=frame_len-2;
    if(crc16(frame,n)!=(uint16_t)(frame[n]|((uint16_t)frame[n+1]<<8))) { bad_crc_frames++;return; }
    int match=n>=4&&!memcmp(frame,wanted,4);
    if(is_error(frame[0])&&n>=5&&!memcmp(frame+1,wanted,4)) match=1;
    if(match) { memcpy(answer,frame,n);answer_len=n;valid_frames++;pthread_cond_signal(&cond); }
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
static int transport_uncertain;
static int path_match(const uint8_t *p,size_t n,size_t off,const char *path) {
    size_t z=strlen(path)+1;return n==off+z&&!memcmp(p+off,path,z);
}
static const char *file_path(int ix) { return ix==0?config_path:ix==1?stage_path:rollback_path; }
static int path_index(const uint8_t *p,size_t n,size_t off) {
    for(int i=0;i<3;i++) if(path_match(p,n,off,file_path(i))) return i;
    return -1;
}
static int is_owned(int ix) { return ix==1?owned_stage:ix==2?owned_rollback:0; }
static const uint8_t *expected_for(int ix) { return ix==1?after_bytes:before_bytes; }
static int allowed_request(const uint8_t *p,size_t n) {
    if(n<4||p[0]!=0x4b||p[1]!=0x13||p[3]!=0) return 0;
    /* A timed-out OPEN/STAT has no echoed pathname. Do not reuse that
     * opcode or guess a descriptor after transport ambiguity. */
    if(transport_uncertain&&p[2]!=3) return 0;
    int ix;uint32_t count,off;
    switch(p[2]) {
        case 15: return path_index(p,n,4)>=0;
        case 2:
            if(n<12||file_fd>=0) return 0;
            ix=path_index(p,n,12);if(ix<0) return 0;
            return (ix>0&&le32(p+4)==0xc1&&le32(p+8)==0xd00)||(le32(p+4)==0&&le32(p+8)==0&&(ix==0||is_owned(ix)));
        case 3: return n==8&&file_fd>=0&&le32(p+4)==(uint32_t)file_fd;
        case 4:
            if(n!=16||file_fd<0||file_access!=0||le32(p+4)!=(uint32_t)file_fd) return 0;
            count=le32(p+8);off=le32(p+12);return count>0&&count<=CHUNK_SIZE&&off<CONFIG_SIZE&&count<=CONFIG_SIZE-off;
        case 5:
            if(n<=12||n>12+CHUNK_SIZE||file_fd<0||file_access!=1||file_index==0||!is_owned(file_index)||le32(p+4)!=(uint32_t)file_fd) return 0;
            off=le32(p+8);return off<CONFIG_SIZE&&n-12<=CONFIG_SIZE-off&&!memcmp(p+12,expected_for(file_index)+off,n-12);
        case 8: return is_owned(path_index(p,n,4))&&file_fd<0;
        case 14:
            if(file_fd>=0) return 0;
            for(int i=1;i<=2;i++) {
                const char *from=file_path(i);size_t z=strlen(from)+1;
                if(n==4+z+sizeof(config_path)&&!memcmp(p+4,from,z)&&!memcmp(p+4+z,config_path,sizeof(config_path)))
                    return is_owned(i)&&(i==1?commit_ready&&!rolling_back:rollback_ready&&commit_attempted&&rolling_back);
            }
            return 0;
        case 48: return n==8&&p[4]==(uint8_t)sync_sequence&&p[5]==(uint8_t)(sync_sequence>>8)&&p[6]=='/'&&p[7]==0;
        case 49: return n==12&&p[4]==(uint8_t)sync_sequence&&p[5]==(uint8_t)(sync_sequence>>8)&&le32(p+6)==sync_token&&p[10]=='/'&&p[11]==0;
        default: return 0;
    }
}
static int exchange(uint8_t *request,size_t n,uint8_t *response,size_t *response_len,const char *label) {
    *response_len=0;
    if(!allowed_request(request,n)||(interrupted&&!rolling_back&&request[2]!=3&&request[2]!=8&&request[2]!=15)) return 0;
    pthread_mutex_lock(&mutex);
    memcpy(wanted,request,4);pending=1;answer_len=0;
    frame_len=0;frame_escape=0;frame_bad=0;
    pthread_mutex_unlock(&mutex);
    send_count++;
    int sent=send_fn(0,request,(int)n);
    struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=4;
    pthread_mutex_lock(&mutex);
    while(!answer_len&&sent==0) {
        int r=pthread_cond_timedwait(&cond,&mutex,&until);
        if(r!=0) break;
    }
    int error=answer_len&&is_error(answer[0])?answer[0]:-1;
    int okay=sent==0&&answer_len>=4&&error<0&&!memcmp(answer,request,4);
    if(okay) { memcpy(response,answer,answer_len);*response_len=answer_len; }
    printf("EFS_REQUEST label=%s send=%d length=%zu diag_error=%d crc_valid=%d\n",label,sent,answer_len,error,answer_len!=0);
    if(sent!=0||answer_len==0) transport_uncertain=1;
    pending=0;
    pthread_mutex_unlock(&mutex);
    return okay;
}
static uint32_t config_crc(const uint8_t *p) {
    uint32_t crc=0;
    for(size_t i=0;i<CONFIG_SIZE;i++) {
        crc^=(uint32_t)((i>=12&&i<16)?0:p[i])<<24;
        for(unsigned j=0;j<8;j++) crc=(crc<<1)^((crc&0x80000000u)?0x04c11db7u:0);
    }
    return crc;
}
static int schema_valid(const uint8_t *p,unsigned flag) {
    if(le32(p)!=0x78563412u||le32(p+4)!=249||le32(p+8)!=CONFIG_SIZE||
       le32(p+CONFIG_SIZE-4)!=0x21436587u||config_crc(p)!=le32(p+12)) return 0;
    uint32_t ids[249];size_t offset=16;int found=0;
    for(unsigned i=0;i<249;i++) {
        if(offset>CONFIG_SIZE-20) return 0;
        uint32_t ident=le32(p+offset),length=le32(p+offset+4);
        if(ident>UINT16_MAX||length<16||length>CONFIG_SIZE-4-offset||
           le32(p+offset+8)!=0x18080820u) return 0;
        for(unsigned j=0;j<i;j++) if(ids[j]==ident) return 0;
        ids[i]=ident;
        if(ident==102) {
            if(i!=5||offset!=483||length!=17||le32(p+offset+12)!=0||p[499]!=flag) return 0;
            found++;
        }
        offset+=length;
    }
    return found==1&&offset==CONFIG_SIZE-4;
}
static int plan_valid(void) {
    if(!schema_valid(config_original,0)||!schema_valid(config_candidate,1)) return 0;
    if(config_original[499]!=0||config_candidate[499]!=1) return 0;
    for(size_t i=0;i<CONFIG_SIZE;i++) if(i!=499&&(i<12||i>=16)&&config_original[i]!=config_candidate[i]) return 0;
    return config_crc(config_original)==le32(config_original+12)&&config_crc(config_candidate)==le32(config_candidate+12);
}
static int load_plan(const char *path) {
    static uint8_t bytes[2*CONFIG_SIZE];
    if(!read_exact_plan(path,bytes,sizeof(bytes))) return 0;
    memcpy(config_original,bytes,CONFIG_SIZE);
    memcpy(config_candidate,bytes+CONFIG_SIZE,CONFIG_SIZE);
    return plan_valid();
}
/* 1=present, 0=ENOENT, -1=error. */
static int stat_path(int ix,struct file_stat *out) {
    uint8_t req[128]={0x4b,0x13,15,0},resp[4096];size_t n;
    const char *path=file_path(ix);size_t z=strlen(path)+1;memcpy(req+4,path,z);
    if(!exchange(req,4+z,resp,&n,"stat")) return -1;
    if(n!=32) { transport_uncertain=1;return -1; }
    uint32_t err=le32(resp+4);
    printf("CONFIG_STAT index=%d errno=%u mode=0x%x size=%u nlink=%u\n",ix,err,le32(resp+8),le32(resp+12),le32(resp+16));
    if(err==2) return 0;
    if(err) return -1;
    out->mode=le32(resp+8);out->size=le32(resp+12);out->nlink=le32(resp+16);
    out->atime=le32(resp+20);out->mtime=le32(resp+24);out->ctime=le32(resp+28);return 1;
}
static int open_path(int ix,int create) {
    uint8_t req[128]={0x4b,0x13,2,0},resp[4096];size_t n;
    put32(req+4,create?0xc1:0);put32(req+8,create?0xd00:0);
    const char *path=file_path(ix);size_t z=strlen(path)+1;memcpy(req+12,path,z);
    if(!exchange(req,12+z,resp,&n,create?"open_excl":"open_readonly")) return 0;
    if(n!=12) { transport_uncertain=1;return 0; }
    uint32_t fd=le32(resp+4),err=le32(resp+8);
    printf("CONFIG_OPEN index=%d create=%d fd=%u errno=%u\n",ix,create,fd,err);
    if(err) return 0;
    if(fd>INT32_MAX) { transport_uncertain=1;return 0; }
    file_fd=(int)fd;file_access=create?1:0;file_index=ix;
    if(create) { if(ix==1) owned_stage=1;else if(ix==2) owned_rollback=1; }
    return 1;
}
static int close_file(void) {
    if(file_fd<0) return 1;
    uint8_t req[8]={0x4b,0x13,3,0},resp[4096];size_t n;
    put32(req+4,(uint32_t)file_fd);
    int received=exchange(req,sizeof(req),resp,&n,"close");
    if(received&&n!=8) transport_uncertain=1;
    int okay=received&&n==8&&le32(resp+4)==0;
    printf("CONFIG_CLOSE fd=%d verified=%d\n",file_fd,okay);
    if(okay) file_fd=-1;
    return okay;
}
static int read_file(int ix,uint8_t out[CONFIG_SIZE]) {
    struct file_stat st,after;
    if(stat_path(ix,&st)!=1) return 0;
    /* B31 boot restored exact original bytes with S_IRGRP (0040=0x20)
     * added. Accept only these two observed live modes; owned staging
     * files still require the exact create mode verified by the probe. */
    int mode_ok=st.mode==0x8d00||(ix==0&&st.mode==0x8d20);
    if(!mode_ok||st.size!=CONFIG_SIZE||st.nlink!=1||!open_path(ix,0)) return 0;
    int okay=1;
    for(uint32_t off=0;off<CONFIG_SIZE;) {
        uint32_t count=CONFIG_SIZE-off;if(count>CHUNK_SIZE) count=CHUNK_SIZE;
        uint8_t req[16]={0x4b,0x13,4,0},resp[4096];size_t n;
        put32(req+4,(uint32_t)file_fd);put32(req+8,count);put32(req+12,off);
        if(!exchange(req,16,resp,&n,"read")) { okay=0;break; }
        if(n<20||le32(resp+4)!=(uint32_t)file_fd||le32(resp+8)!=off) { transport_uncertain=1;okay=0;break; }
        if(n!=20+count||le32(resp+12)!=count||le32(resp+16)!=0) { okay=0;break; }
        memcpy(out+off,resp+20,count);off+=count;
    }
    int closed=close_file();
    if(!okay||!closed||stat_path(ix,&after)!=1) return 0;
    return st.mode==after.mode&&st.size==after.size&&st.nlink==after.nlink&&st.mtime==after.mtime&&st.ctime==after.ctime;
}
static int stage_file(int ix) {
    if(ix<1||ix>2||!open_path(ix,1)) return 0;
    int okay=1;
    for(uint32_t off=0;off<CONFIG_SIZE;) {
        uint32_t count=CONFIG_SIZE-off;if(count>CHUNK_SIZE) count=CHUNK_SIZE;
        uint8_t req[12+CHUNK_SIZE]={0x4b,0x13,5,0},resp[4096];size_t n;
        put32(req+4,(uint32_t)file_fd);put32(req+8,off);memcpy(req+12,expected_for(ix)+off,count);
        if(!exchange(req,12+count,resp,&n,"write_staging")) { okay=0;break; }
        if(n!=20||le32(resp+4)!=(uint32_t)file_fd||le32(resp+8)!=off) { transport_uncertain=1;okay=0;break; }
        if(le32(resp+12)!=count||le32(resp+16)!=0) { okay=0;break; }
        off+=count;
    }
    int closed=close_file();
    static uint8_t check[CONFIG_SIZE];
    int match=okay&&closed&&read_file(ix,check)&&!memcmp(check,expected_for(ix),CONFIG_SIZE);
    printf("CONFIG_STAGED index=%d exact=%d\n",ix,match);return match;
}
static int rename_into_config(int ix) {
    uint8_t req[128]={0x4b,0x13,14,0},resp[4096];size_t n;
    const char *path=file_path(ix);size_t z=strlen(path)+1;memcpy(req+4,path,z);memcpy(req+4+z,config_path,sizeof(config_path));
    int received=exchange(req,4+z+sizeof(config_path),resp,&n,ix==1?"commit_rename":"rollback_rename");
    if(received&&n!=8) transport_uncertain=1;
    int okay=received&&n==8&&le32(resp+4)==0;
    printf("CONFIG_RENAME index=%d acknowledged=%d\n",ix,okay);return okay;
}
static int cleanup_one(int ix) {
    if(!is_owned(ix)) return 1;
    if(file_fd>=0||transport_uncertain) return 0;
    struct file_stat st;int exists=stat_path(ix,&st);
    if(exists<0) return 0;
    if(exists==1) {
        uint8_t req[128]={0x4b,0x13,8,0},resp[4096];size_t n;
        const char *path=file_path(ix);size_t z=strlen(path)+1;memcpy(req+4,path,z);
        if(!exchange(req,4+z,resp,&n,"unlink_owned_staging")||n!=8||le32(resp+4)!=0||stat_path(ix,&st)!=0) return 0;
    }
    if(ix==1) owned_stage=0;else owned_rollback=0;return 1;
}
static int sync_filesystem(void) {
    uint8_t req[12]={0x4b,0x13,48,0},resp[4096];size_t n;
    ++sync_sequence;req[4]=(uint8_t)sync_sequence;req[5]=(uint8_t)(sync_sequence>>8);req[6]='/';
    if(!exchange(req,8,resp,&n,"sync_start")||n!=14||resp[4]!=req[4]||resp[5]!=req[5]) return 0;
    uint32_t err=le32(resp+10);sync_token=le32(resp+6);
    printf("EFS_SYNC_START sequence=%u token=%u errno=%u\n",sync_sequence,sync_token,err);
    /* fs_get_diag_errno maps ENOTHINGTOSYNC to 306. */
    if(err==306) return 1;
    if(err) return 0;
    for(unsigned i=0;i<100;i++) {
        struct timespec pause={0,100000000};nanosleep(&pause,NULL);
        memset(req,0,sizeof(req));req[0]=0x4b;req[1]=0x13;req[2]=49;
        /* A fresh sequence avoids fs_diag memoizing the last pending reply. */
        ++sync_sequence;req[4]=(uint8_t)sync_sequence;req[5]=(uint8_t)(sync_sequence>>8);put32(req+6,sync_token);req[10]='/';
        if(!exchange(req,12,resp,&n,"sync_status")||n!=11||resp[4]!=req[4]||resp[5]!=req[5]||le32(resp+7)!=0) return 0;
        printf("EFS_SYNC_STATUS sequence=%u status=%u\n",sync_sequence,resp[6]);
        /* Qualcomm fs_sys_types.h: PENDING=0, COMPLETE=1. */
        if(resp[6]==1) return 1;
        if(resp[6]!=0) return 0;
    }
    return 0;
}
static int query_owner(void) {
    struct query_params q={2,0,-22,1,0,0};
    int r=ioctl_fn(*diag_fd,41,&q,sizeof(q));
    printf("EFS_OWNER ret=%d pid=%d self=%d\n",r,q.pid,(int)getpid());
    return r==0?q.pid:-22;
}
static int release_session(void) {
    for(int attempt=0;attempt<2;attempt++) {
        int owner=query_owner();if(owner<0) owner=query_owner();
        if(owner!=(int)getpid()) { puts("EFS_RELEASE_OWNERSHIP_UNCERTAIN");return 0; }
        struct logging_params lp={1,2,0,1,0,0,0,-22,1};
        int r=ioctl_fn(*diag_fd,7,&lp,sizeof(lp));
        if(r==0) *logging_mode=1;
        owner=query_owner();if(owner<0) owner=query_owner();
        printf("EFS_RELEASE ret=%d owner=%d local_mode=%d\n",r,owner,*logging_mode);
        if(r==0&&owner==0) return 1;
        if(owner!=(int)getpid()) return 0;
    }
    return 0;
}

static int target_verified,rollback_verified,retain_files;
static int exact_file(int ix,const uint8_t *expected) {
    static uint8_t actual[CONFIG_SIZE];
    return read_file(ix,actual)&&!memcmp(actual,expected,CONFIG_SIZE);
}
/* On a known response failure, classify the live file before considering
 * rollback. An unknown transport outcome forbids all new path requests in
 * this process: keep recovery files and require a fresh diagnostic session. */
static int recover_before(void) {
    if(transport_uncertain) { retain_files=1;return 0; }
    rolling_back=1;
    static uint8_t actual[CONFIG_SIZE];
    if(!read_file(0,actual)) { retain_files=1;return 0; }
    if(!memcmp(actual,before_bytes,CONFIG_SIZE)) {
        rollback_verified=1;
        if(sync_filesystem()) return 1;
        retain_files=1;return 0;
    }
    if(memcmp(actual,after_bytes,CONFIG_SIZE)) {
        puts("CONFIG_RECOVERY_REFUSED_UNKNOWN_LIVE_BYTES");retain_files=1;return 0;
    }
    if(!rollback_ready||!exact_file(2,before_bytes)||!rename_into_config(2)||
       !exact_file(0,before_bytes)||!sync_filesystem()||!exact_file(0,before_bytes)) {
        retain_files=1;return 0;
    }
    rollback_verified=1;puts("CONFIG_ROLLBACK_VERIFIED");return 1;
}
static int run_operation(int check_only) {
    int outcome=20;
    static uint8_t actual[CONFIG_SIZE];
    struct file_stat st;
    if(!read_file(0,actual)) goto finish;
    if(check_only) {
        target_verified=!memcmp(actual,after_bytes,CONFIG_SIZE);
        outcome=target_verified?0:21;goto finish;
    }
    if(!memcmp(actual,after_bytes,CONFIG_SIZE)) {
        puts("CONFIG_ALREADY_TARGET");
        if(sync_filesystem()&&exact_file(0,after_bytes)) { target_verified=1;outcome=0; }
        goto finish;
    }
    if(memcmp(actual,before_bytes,CONFIG_SIZE)) {
        puts("CONFIG_REFUSED_UNKNOWN_LIVE_BYTES");outcome=22;goto finish;
    }
    puts("CONFIG_LIVE_BEFORE_EXACT");
    /* Refuse pre-existing siblings. Their ownership is not established by
     * a matching filename or matching payload. */
    if(stat_path(1,&st)!=0||stat_path(2,&st)!=0) { outcome=23;goto finish; }
    if(!stage_file(2)) { outcome=24;goto finish; }
    rollback_ready=1;
    if(!stage_file(1)||!sync_filesystem()) { outcome=25;goto finish; }
    if(!exact_file(1,after_bytes)||!exact_file(2,before_bytes)||!exact_file(0,before_bytes)) {
        outcome=26;goto finish;
    }
    if(interrupted) { outcome=27;goto finish; }
    commit_ready=1;commit_attempted=1;
    if(!rename_into_config(1)||!exact_file(0,after_bytes)||!sync_filesystem()||
       !exact_file(0,after_bytes)||interrupted) {
        outcome=recover_before()?28:29;goto finish;
    }
    target_verified=1;outcome=0;puts("CONFIG_TARGET_VERIFIED");
finish:;
    int closed=close_file();
    if(transport_uncertain) retain_files=1;
    int had_owned=owned_stage||owned_rollback;
    int clean_stage=1,clean_rollback=1;
    if(!retain_files) { clean_stage=cleanup_one(1);clean_rollback=cleanup_one(2); }
    else { clean_stage=!owned_stage;clean_rollback=!owned_rollback; }
    if(!closed||!clean_stage||!clean_rollback) outcome=30;
    /* Cleanup must survive the reboot too, otherwise a durable rollback
     * sibling can reappear and correctly block the later restore command. */
    int cleanup_synced=1;
    if(had_owned&&!retain_files&&closed&&clean_stage&&clean_rollback) {
        cleanup_synced=sync_filesystem()&&stat_path(1,&st)==0&&stat_path(2,&st)==0;
        if(!cleanup_synced) { retain_files=1;outcome=30; }
    }
    if(interrupted&&outcome==0) outcome=27;
    printf("CONFIG_OPERATION outcome=%d check_only=%d target_verified=%d rollback_verified=%d commit_attempted=%d transport_uncertain=%d retain_files=%d cleaned_stage=%d cleaned_rollback=%d cleanup_synced=%d file_closed=%d\n",
           outcome,check_only,target_verified,rollback_verified,commit_attempted,transport_uncertain,retain_files,clean_stage,clean_rollback,cleanup_synced,closed);
    return outcome;
}
int main(int argc,char **argv) {
    int check_only=0,want_candidate;
    if(argc!=3) return 2;
    if(!strcmp(argv[1],"--enable-flag")) want_candidate=1;
    else if(!strcmp(argv[1],"--restore-original-config")) want_candidate=0;
    else if(!strcmp(argv[1],"--check-original")) { want_candidate=0;check_only=1; }
    else if(!strcmp(argv[1],"--check-candidate")) { want_candidate=1;check_only=1; }
    else return 2;
    before_bytes=want_candidate?config_original:config_candidate;
    after_bytes=want_candidate?config_candidate:config_original;
    setvbuf(stdout,NULL,_IONBF,0);
    if(!load_plan(argv[2])) { puts("CONFIG_PLAN_VALIDATION_FAILED");return 3; }
    printf("CONFIG_EXPECTED size=%u target_flag102=%u plan_validated=1\n",
           CONFIG_SIZE,after_bytes[499]);
    printf("CONFIG_PATHS stage=%s rollback=%s\n",stage_path,rollback_path);
    signal(SIGINT,interrupt_handler);signal(SIGTERM,interrupt_handler);signal(SIGHUP,interrupt_handler);signal(SIGALRM,interrupt_handler);alarm(180);
    void *lib=dlopen("/usr/lib/libdiag.so.1",RTLD_NOW|RTLD_LOCAL);
    if(!lib) return 4;
    unsigned char (*init_fn)(unsigned char*)=dlsym(lib,"Diag_LSM_Init");
    void (*register_fn)(int(*)(unsigned char*,int,void*),void*)=dlsym(lib,"diag_register_callback");
    deinit_fn=dlsym(lib,"Diag_LSM_DeInit");send_fn=dlsym(lib,"diag_callback_send_data");
    ioctl_fn=dlsym(lib,"diag_lsm_comm_ioctl");diag_fd=dlsym(lib,"diag_fd");logging_mode=dlsym(lib,"logging_mode");
    if(!init_fn||!deinit_fn||!register_fn||!send_fn||!ioctl_fn||!diag_fd||!logging_mode) return 5;
    if(!init_fn(NULL)) return 6;
    register_fn(callback,NULL);
    if(interrupted||*logging_mode!=1||query_owner()!=0) { deinit_fn();return 7; }
    struct logging_params lp={6,2,0,1,0,0,0,-22,1};
    int opened=ioctl_fn(*diag_fd,7,&lp,sizeof(lp));
    printf("EFS_SESSION_OPEN %d\n",opened);
    if(opened!=0) { deinit_fn();return 8; }
    *logging_mode=6;
    int owner=query_owner();if(owner<0) owner=query_owner();
    if(owner!=(int)getpid()) {
        puts("EFS_OPEN_OWNERSHIP_UNCERTAIN");
        printf("EFS_EARLY_RELEASE %d\n",release_session());deinit_fn();return 9;
    }
    int outcome=run_operation(check_only);
    int released=release_session(),deinitialized=deinit_fn();
    alarm(0);
    if(!released||!deinitialized) outcome=31;
    printf("CONFIG_RESULT outcome=%d target_flag102=%u target_verified=%d rollback_verified=%d commit_attempted=%d transport_uncertain=%d retained_stage=%d retained_rollback=%d released=%d deinit=%d signal=%d crc_verified_frames=%u bad_crc_frames=%u sends=%u\n",
           outcome,after_bytes[499],target_verified,rollback_verified,commit_attempted,transport_uncertain,owned_stage,owned_rollback,released,deinitialized,(int)interrupted,valid_frames,bad_crc_frames,send_count);
    return outcome;
}
