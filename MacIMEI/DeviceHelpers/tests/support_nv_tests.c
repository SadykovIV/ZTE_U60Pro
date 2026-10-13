/* The entire diagnostic CLI runs against a synthetic in-process DIAG library. */
#define ZTE_SUPPORT_READONLY 1
#define dlopen support_dlopen
#define dlsym support_dlsym
#define main support_main
#include "../src/zte_nv.c"
#undef main
#undef dlopen
#undef dlsym
#include <assert.h>
#include <stdlib.h>

static int mock_mode,mock_fd=7,mock_owner,mock_calls,load_calls,scenario;
static int loaded_symbol;
static uint8_t records[2][128];
static void inject(const uint8_t *bytes,size_t n,int bad_crc) {
    uint8_t data[4096],wire[8192];size_t w=0;
    assert(n+2<=sizeof(data));memcpy(data,bytes,n);
    uint16_t crc=crc16(data,n);if(bad_crc) crc^=1;
    data[n++]=(uint8_t)crc;data[n++]=(uint8_t)(crc>>8);
    for(size_t i=0;i<n;i++) {
        if(data[i]==0x7e||data[i]==0x7d) {wire[w++]=0x7d;wire[w++]=data[i]^0x20;}
        else wire[w++]=data[i];
    }
    wire[w++]=0x7e;
    for(size_t i=0;i<w;i++) callback(wire+i,1,NULL);
}
static int mock_send(int proc,unsigned char *request,int n) {
    assert(proc==0);mock_calls++;
    assert((n==138&&request[0]==0x4b&&request[1]==0x30&&request[2]==1&&request[6]<=1)||
           (n==133&&request[0]==0x26&&request[1]==0x26&&request[2]==2));
    size_t head=n==138?8:3;for(int i=(int)head;i<n;i++) assert(!request[i]);
    uint8_t response[160]={0};memcpy(response,request,(size_t)n);
    unsigned index=n==138?request[6]:0;
    memcpy(response+head,records[index],128);
    if(scenario==1&&index==1) response[n-2]=5; /* explicit NV status */
    if(scenario==2&&n==133) response[head+9]^=1; /* legacy alias differs */
    if(scenario==3&&index==0) {response[0]=0x47;memcpy(response+1,request,head);inject(response,head+1,0);return 0;}
    if(scenario==4) {inject(response,(size_t)n,1);return -1;}
    if(scenario==5) {inject(response,(size_t)n-1,0);return 0;}
    if(scenario==10) {uint8_t ignored=0x13;inject(&ignored,1,0);return -1;}
    inject(response,(size_t)n,0);return 0;
}
static unsigned char mock_init(unsigned char *unused) {(void)unused;mock_mode=1;return scenario!=8;}
static unsigned char mock_deinit(void) {return 1;}
static void mock_register(int(*fn)(unsigned char*,int,void*),void *arg) {assert(fn==callback&&arg==NULL);}
static int mock_ioctl(int fd,unsigned long operation,void *payload,unsigned int n) {
    assert(fd==mock_fd&&n==24);
    if(operation==41) {struct query_params *q=payload;assert(q->mask==2&&!q->kill_op);q->pid=mock_owner;return 0;}
    assert(operation==7);struct logging_params *p=payload;
    assert(p->mask==2&&p->mode_param==1&&p->device==1&&p->peripheral==-22);
    assert(p->mode==1||p->mode==6);
    if(scenario==9&&p->mode==1) return -1;
    mock_owner=p->mode==6?(int)getpid():0;return 0;
}
void *support_dlopen(const char *path,int mode) {
    assert(!strcmp(path,"/usr/lib/libdiag.so.1")&&mode==(RTLD_NOW|RTLD_LOCAL));load_calls++;
    return scenario==6?NULL:&loaded_symbol;
}
void *support_dlsym(void *lib,const char *name) {
    assert(lib==&loaded_symbol);
    if(scenario==7&&!strcmp(name,"diag_callback_send_data")) return NULL;
    if(!strcmp(name,"Diag_LSM_Init")) return (void*)mock_init;
    if(!strcmp(name,"Diag_LSM_DeInit")) return (void*)mock_deinit;
    if(!strcmp(name,"diag_register_callback")) return (void*)mock_register;
    if(!strcmp(name,"diag_callback_send_data")) return (void*)mock_send;
    if(!strcmp(name,"diag_lsm_comm_ioctl")) return (void*)mock_ioctl;
    if(!strcmp(name,"diag_fd")) return &mock_fd;
    if(!strcmp(name,"logging_mode")) return &mock_mode;
    abort();
}
static void fixture(void) {
    memset(records,0,sizeof(records));
    /* Synthetic all-zero IMEI has valid BCD/Luhn. The non-identity tails differ. */
    for(int i=0;i<2;i++) {records[i][0]=8;records[i][1]=10;memcpy(records[i]+9,"PRIVATE_RECORD_MUST_NOT_ESCAPE",29);records[i][127]=(uint8_t)i;}
    mock_mode=1;mock_owner=mock_calls=0;interrupted=0;write_attempts=valid_frames=bad_crc_frames=0;
    memset(support_readable,0,sizeof(support_readable));support_alias=0;
}
int main(void) {
    const int expected[]={0,20,20,20,20,20,4,5,6,40,20};
    for(scenario=0;scenario<11;scenario++) {
        fixture();char *args[]={"zte-support-nv","--inspect-nv550",NULL};
        int result=support_main(2,args);alarm(0);assert(result==expected[scenario]);
        if(scenario<6) assert(mock_calls==3&&mock_owner==0);
        assert(write_attempts==0);
    }
    scenario=0;fixture();records[1][1]=0xff;
    char *inspect[]={"zte-support-nv","--inspect-nv550",NULL};assert(support_main(2,inspect)==23);
    const char *bad[]={"--read-imei","--snapshot","--snapshot-available","--apply-plan","--verify-plan","--restore-plan-original","--check-plan-original"};
    int before=load_calls;
    for(size_t i=0;i<sizeof(bad)/sizeof(bad[0]);i++) {char *args[]={"zte-support-nv",(char*)bad[i],NULL};assert(support_main(2,args)==2);}
    assert(load_calls==before);
    uint8_t mutable[138]={0x4b,0x30,2,0,0x26,2};before=mock_calls;
    assert(!exchange(mutable,sizeof(mutable),8,NULL,"forbidden"));
    mutable[2]=1;mutable[8]=1;assert(!exchange(mutable,sizeof(mutable),8,NULL,"forbidden"));
    assert(mock_calls==before);
    puts("SUPPORT_NV_TESTS_PASS scenarios=20 writes=0");return 0;
}
