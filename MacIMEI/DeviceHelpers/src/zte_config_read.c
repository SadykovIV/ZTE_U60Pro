/* Read-only, fixed-path backup of modem EFS /config on MU5250 B31.
 * EFS commands: STAT(15), OPEN(2, flags=0, mode=0), READ(4), CLOSE(3).
 * No NV operations, authentication, HELLO, file writes or mode changes.
 * Temporary diagnostic routing is scoped to MPSS/MODEM (mask 2).
 * Every accepted response has a validated HDLC CRC; file bytes are emitted
 * only after all reads, a stable final STAT and a successful CLOSE.
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

#define MAX_FILE_SIZE 51200u
#define READ_CHUNK 1024u
static const char config_path[]="/config";
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
static uint32_t file_crc32(const uint8_t *p,size_t n) {
    uint32_t crc=0xffffffffu;
    for(size_t i=0;i<n;i++) {
        crc^=p[i];
        for(unsigned j=0;j<8;j++) crc=(crc>>1)^((crc&1)?0xedb88320u:0);
    }
    return ~crc;
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
/* Defense in depth: even accidental new callers cannot send a mutable
 * EFS operation through this helper's only DIAG send function. */
static int allowed_request(const uint8_t *p,size_t n) {
    if(n<4||p[0]!=0x4b||p[1]!=0x13||p[3]!=0) return 0;
    switch(p[2]) {
        case 15: return n==4+sizeof(config_path)&&!memcmp(p+4,config_path,sizeof(config_path));
        case 2: return n==12+sizeof(config_path)&&le32(p+4)==0&&le32(p+8)==0&&!memcmp(p+12,config_path,sizeof(config_path));
        case 4: return n==16&&le32(p+4)<=INT32_MAX&&le32(p+8)>0&&le32(p+8)<=READ_CHUNK&&le32(p+12)<=MAX_FILE_SIZE&&le32(p+8)<=MAX_FILE_SIZE-le32(p+12);
        case 3: return n==8&&le32(p+4)<=INT32_MAX;
        default: return 0;
    }
}
static int exchange(uint8_t *request,size_t n,uint8_t *response,size_t *response_len,const char *label) {
    *response_len=0;
    if(!allowed_request(request,n)||(interrupted&&request[2]!=3)) return 0;
    pthread_mutex_lock(&mutex);
    memcpy(wanted,request,4);pending=1;answer_len=0;
    frame_len=0;frame_escape=0;frame_bad=0;
    pthread_mutex_unlock(&mutex);
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
    pending=0;
    pthread_mutex_unlock(&mutex);
    return okay;
}
static int read_stat(struct file_stat *out,const char *label) {
    uint8_t req[4+sizeof(config_path)]={0x4b,0x13,15,0},resp[4096];size_t n;
    memcpy(req+4,config_path,sizeof(config_path));
    if(!exchange(req,sizeof(req),resp,&n,label)||n!=32) return 0;
    uint32_t err=le32(resp+4);
    printf("EFS_STAT label=%s errno=%u mode=0x%x size=%u nlink=%u\n",label,err,le32(resp+8),le32(resp+12),le32(resp+16));
    if(err) return 0;
    out->mode=le32(resp+8);out->size=le32(resp+12);out->nlink=le32(resp+16);
    out->atime=le32(resp+20);out->mtime=le32(resp+24);out->ctime=le32(resp+28);
    return (out->mode&0xf000u)==0x8000u&&out->nlink==1&&out->size>0&&out->size<=MAX_FILE_SIZE;
}
static int open_file(void) {
    uint8_t req[12+sizeof(config_path)]={0x4b,0x13,2,0},resp[4096];size_t n;
    memcpy(req+12,config_path,sizeof(config_path));
    if(!exchange(req,sizeof(req),resp,&n,"open_readonly")||n!=12) { puts("EFS_OPEN_NO_VALID_DESCRIPTOR");return -1; }
    uint32_t fd=le32(resp+4),err=le32(resp+8);
    printf("EFS_OPEN fd=%u errno=%u flags=0 mode=0\n",fd,err);
    if(err||fd>INT32_MAX) return -1;
    return (int)fd;
}
static int read_chunk(int fd,uint32_t offset,uint32_t count,uint8_t *out) {
    uint8_t req[16]={0x4b,0x13,4,0},resp[4096];size_t n;
    put32(req+4,(uint32_t)fd);put32(req+8,count);put32(req+12,offset);
    if(!exchange(req,sizeof(req),resp,&n,"read")||n<20) return 0;
    uint32_t got_fd=le32(resp+4),got_offset=le32(resp+8),got_count=le32(resp+12),err=le32(resp+16);
    int okay=got_fd==(uint32_t)fd&&got_offset==offset&&got_count==count&&err==0&&n==20+(size_t)count;
    printf("EFS_READ fd=%u offset=%u requested=%u returned=%u errno=%u exact=%d\n",got_fd,got_offset,count,got_count,err,okay);
    if(okay) memcpy(out,resp+20,count);
    return okay;
}
static int close_file(int fd) {
    uint8_t req[8]={0x4b,0x13,3,0},resp[4096];size_t n;
    put32(req+4,(uint32_t)fd);
    int okay=exchange(req,sizeof(req),resp,&n,"close")&&n==8&&le32(resp+4)==0;
    printf("EFS_CLOSE fd=%d verified=%d\n",fd,okay);
    return okay;
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
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IOLBF,0);
    if(argc!=2||strcmp(argv[1],"--read-config")) return 2;
    struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=interrupt_handler;sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGTERM,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
    alarm(120);
    void *lib=dlopen("/usr/lib/libdiag.so.1",RTLD_NOW|RTLD_LOCAL);
    if(!lib) return 3;
    unsigned char (*init_fn)(unsigned char*)=dlsym(lib,"Diag_LSM_Init");
    void (*register_fn)(int(*)(unsigned char*,int,void*),void*)=dlsym(lib,"diag_register_callback");
    deinit_fn=dlsym(lib,"Diag_LSM_DeInit");send_fn=dlsym(lib,"diag_callback_send_data");
    ioctl_fn=dlsym(lib,"diag_lsm_comm_ioctl");diag_fd=dlsym(lib,"diag_fd");logging_mode=dlsym(lib,"logging_mode");
    if(!init_fn||!deinit_fn||!register_fn||!send_fn||!ioctl_fn||!diag_fd||!logging_mode) return 4;
    if(!init_fn(NULL)) return 5;
    register_fn(callback,NULL);
    if(interrupted||*logging_mode!=1||query_owner()!=0) { deinit_fn();return 6; }
    struct logging_params lp={6,2,0,1,0,0,0,-22,1};
    int opened=ioctl_fn(*diag_fd,7,&lp,sizeof(lp));
    printf("EFS_SESSION_OPEN %d\n",opened);
    if(opened!=0) { deinit_fn();return 7; }
    *logging_mode=6;
    int owner=query_owner();if(owner<0) owner=query_owner();
    if(owner!=(int)getpid()) {
        puts("EFS_OPEN_OWNERSHIP_UNCERTAIN");
        printf("EFS_EARLY_RELEASE %d\n",release_session());deinit_fn();return 8;
    }
    static uint8_t file_bytes[MAX_FILE_SIZE];
    struct file_stat before={0},after={0};
    int fd=-1,outcome=20,fd_closed=1;
    uint32_t total=0;
    if(!read_stat(&before,"before")) goto finish;
    fd=open_file();if(fd<0) { outcome=21;goto finish; }
    fd_closed=0;
    while(total<before.size) {
        uint32_t count=before.size-total;if(count>READ_CHUNK) count=READ_CHUNK;
        if(interrupted||!read_chunk(fd,total,count,file_bytes+total)) { outcome=22;goto finish; }
        total+=count;
    }
    if(!read_stat(&after,"after")||before.mode!=after.mode||before.size!=after.size||before.nlink!=after.nlink||before.mtime!=after.mtime||before.ctime!=after.ctime) { outcome=23;goto finish; }
    outcome=0;
finish:
    if(fd>=0) fd_closed=close_file(fd);
    if(!fd_closed&&outcome==0) outcome=24;
    if(interrupted&&outcome==0) outcome=25;
    int released=release_session();
    int deinitialized=deinit_fn();
    if(!released||!deinitialized) outcome=30;
    if(outcome==0) {
        for(uint32_t off=0;off<total;) {
            uint32_t count=total-off;if(count>READ_CHUNK) count=READ_CHUNK;
            printf("EFS_DATA_HEX offset=%u length=%u data=",off,count);
            for(uint32_t i=0;i<count;i++) printf("%02x",file_bytes[off+i]);
            putchar('\n');off+=count;
        }
        printf("EFS_FILE_COMPLETE path=/config length=%u crc32=%08x\n",total,file_crc32(file_bytes,total));
    }
    printf("EFS_RESULT outcome=%d bytes=%u file_closed=%d released=%d deinit=%d signal=%d crc_verified_frames=%u bad_crc_frames=%u\n",outcome,total,fd_closed,released,deinitialized,(int)interrupted,valid_frames,bad_crc_frames);
    return outcome;
}
