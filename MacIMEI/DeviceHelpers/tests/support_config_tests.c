#define ZTE_SUPPORT_READONLY 1
#define dlopen support_dlopen
#define dlsym support_dlsym
#define main support_main
#include "../src/zte_config_read.c"
#undef main
#undef dlopen
#undef dlsym
#include <assert.h>
#include <stdlib.h>
static uint8_t config[15073];
static int scenario,mock_mode,mock_fd=7,mock_owner,load_calls,send_calls,stat_calls;
static int loaded_symbol;
static void fixture(void) {
    memset(config,0,sizeof(config));put32(config,0x78563412u);put32(config+4,249);put32(config+8,sizeof(config));
    size_t offset=16;
    for(unsigned i=0;i<249;i++) {
        unsigned length=i<4?93:i==4?95:i==5?17:i==248?291:59;
        uint8_t *p=config+offset;put32(p,i==5?102:1000+i);put32(p+4,length);put32(p+8,0x18080820u);
        for(unsigned j=16;j<length;j++) p[j]=(uint8_t)(i+7*j);
        offset+=length;
    }
    assert(offset==sizeof(config)-4);config[499]=0;put32(config+sizeof(config)-4,0x21436587u);
    put32(config+12,support_config_crc(config,sizeof(config)));
    mock_mode=1;mock_owner=send_calls=stat_calls=0;interrupted=0;valid_frames=bad_crc_frames=0;
}
static int mock_send(int proc,unsigned char *req,int n) {
    assert(proc==0&&allowed_request(req,(size_t)n));send_calls++;
    uint8_t raw[2048]={0},wire[4096];size_t len=0,w=0;memcpy(raw,req,4);
    switch(req[2]) {
        case 15:
            len=32;put32(raw+8,0x8d00);put32(raw+12,sizeof(config));put32(raw+16,1);stat_calls++;
            if(scenario==1) put32(raw+4,2);
            if(scenario==2&&stat_calls==2) put32(raw+24,1);
            break;
        case 2: len=12;put32(raw+4,7);if(scenario==3) put32(raw+8,13);break;
        case 3: len=8;if(scenario==5) put32(raw+4,5);break;
        case 4:
            len=20+le32(req+8);put32(raw+4,le32(req+4));put32(raw+8,le32(req+12));put32(raw+12,le32(req+8));
            assert(le32(req+12)+le32(req+8)<=sizeof(config));memcpy(raw+20,config+le32(req+12),le32(req+8));
            if(scenario==4) put32(raw+16,5);
            break;
        default: abort();
    }
    uint16_t crc=crc16(raw,len);raw[len++]=(uint8_t)crc;raw[len++]=(uint8_t)(crc>>8);
    for(size_t i=0;i<len;i++) {if(raw[i]==0x7e||raw[i]==0x7d) {wire[w++]=0x7d;wire[w++]=raw[i]^0x20;}else wire[w++]=raw[i];}
    wire[w++]=0x7e;for(size_t i=0;i<w;i++) callback(wire+i,1,NULL);return 0;
}
static unsigned char mock_init(unsigned char *unused) {(void)unused;mock_mode=1;return 1;}
static unsigned char mock_deinit(void) {return 1;}
static void mock_register(int(*fn)(unsigned char*,int,void*),void *arg) {assert(fn==callback&&arg==NULL);}
static int mock_ioctl(int fd,unsigned long operation,void *payload,unsigned int n) {
    assert(fd==mock_fd&&n==24);
    if(operation==41) {struct query_params *q=payload;assert(q->mask==2&&!q->kill_op);q->pid=mock_owner;return 0;}
    assert(operation==7);struct logging_params *p=payload;assert(p->mask==2&&(p->mode==1||p->mode==6));
    if(scenario==6&&p->mode==1) return -1;
    mock_owner=p->mode==6?(int)getpid():0;return 0;
}
void *support_dlopen(const char *path,int mode) {assert(!strcmp(path,"/usr/lib/libdiag.so.1")&&mode==(RTLD_NOW|RTLD_LOCAL));load_calls++;return &loaded_symbol;}
void *support_dlsym(void *lib,const char *name) {
    assert(lib==&loaded_symbol);
    if(!strcmp(name,"Diag_LSM_Init")) return (void*)mock_init;
    if(!strcmp(name,"Diag_LSM_DeInit")) return (void*)mock_deinit;
    if(!strcmp(name,"diag_register_callback")) return (void*)mock_register;
    if(!strcmp(name,"diag_callback_send_data")) return (void*)mock_send;
    if(!strcmp(name,"diag_lsm_comm_ioctl")) return (void*)mock_ioctl;
    if(!strcmp(name,"diag_fd")) return &mock_fd;
    if(!strcmp(name,"logging_mode")) return &mock_mode;
    abort();
}
int main(void) {
    const int expected[]={0,20,23,21,22,24,30};
    for(scenario=0;scenario<7;scenario++) {
        fixture();char *args[]={"zte-support-config","--inspect-config",NULL};
        assert(support_main(2,args)==expected[scenario]);alarm(0);
        if(scenario<6) assert(mock_owner==0);
    }
    const char *bad[]={"--read-config","--enable-flag","--restore-original-config","--inspect-nv550"};
    int before=load_calls;
    for(size_t i=0;i<sizeof(bad)/sizeof(bad[0]);i++) {char *args[]={"zte-support-config",(char*)bad[i],NULL};assert(support_main(2,args)==2);}
    assert(load_calls==before);
    /* Format variations and malformed records are summarized without payload. */
    fixture();puts("CASE invalid_crc");config[600]^=1;support_config_summary(config,sizeof(config));
    fixture();puts("CASE duplicate_id");put32(config+109,1000);support_config_summary(config,sizeof(config));
    fixture();puts("CASE invalid_record");put32(config+20,0xffffffff);support_config_summary(config,sizeof(config));
    fixture();puts("CASE unknown_header");config[0]=0;support_config_summary(config,sizeof(config));
    fixture();puts("CASE invalid_header");put32(config+4,0xffffffff);support_config_summary(config,sizeof(config));
    fixture();puts("CASE flag_unknown");config[499]=0xab;support_config_summary(config,sizeof(config));
    puts("CASE short");for(size_t n=0;n<20;n++) support_config_summary(config,n);
    uint8_t req[20]={0x4b,0x13,2,0};memcpy(req+12,config_path,sizeof(config_path));req[4]=1;
    assert(!allowed_request(req,sizeof(req)));req[4]=0;req[2]=5;assert(!allowed_request(req,sizeof(req)));
    puts("SUPPORT_CONFIG_TESTS_PASS scenarios=38 writes=0");return 0;
}
