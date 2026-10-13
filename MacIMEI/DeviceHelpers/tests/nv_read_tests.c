/* The entire diagnostic CLI runs against a synthetic in-process DIAG library. */
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
    if(scenario==11&&index==1) response[n-2]=4;
    if(scenario==12&&index==1) {response[0]=0x47;memcpy(response+1,request,head);inject(response,head+1,0);return 0;}
    if(scenario==10) {uint8_t ignored=0x13;inject(&ignored,1,0);return -1;}
    if(scenario==14&&n==133) interrupted=SIGTERM;
    inject(response,(size_t)n,0);return 0;
}
static unsigned char mock_init(unsigned char *unused) {(void)unused;mock_mode=1;return scenario!=8;}
static unsigned char mock_deinit(void) {return scenario==13?0:1;}
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
    mock_mode=1;mock_owner=mock_calls=0;interrupted=0;write_attempts=0;last_nv_status=-1;
}
static int run_read(const char *mode,char *captured,size_t capacity) {
    FILE *file=tmpfile();assert(file);fflush(stdout);int saved=dup(STDOUT_FILENO);assert(saved>=0);
    assert(dup2(fileno(file),STDOUT_FILENO)>=0);
    char *args[]={"zte_nv",(char*)mode,NULL};int result=support_main(2,args);alarm(0);
    fflush(stdout);assert(dup2(saved,STDOUT_FILENO)>=0);close(saved);rewind(file);
    size_t length=fread(captured,1,capacity-1,file);assert(!ferror(file)&&feof(file));captured[length]=0;fclose(file);
    return result;
}
int main(void) {
    char output[8192];
    const int expected[]={0,0,20,20,20,20,4,5,6,40,20,20,20,40,41};
    for(scenario=0;scenario<15;scenario++) {
        fixture();assert(run_read("--read-imei",output,sizeof(output))==expected[scenario]);
        assert(!strstr(output,"APP_NV")&&!strstr(output,"PRIVATE_RECORD_MUST_NOT_ESCAPE"));
        if(expected[scenario]==0) {
            const char *first=strstr(output,"APP_IMEI index=0 value=000000000000000\n");assert(first);
            const char *released=strstr(output,"PAIR_RESULT outcome=0 write_attempts=0 released=1 deinit=1");assert(released&&released<first);
            assert(strstr(output,scenario==1?"APP_IMEI index=1 state=not-active nv_status=5\n":"APP_IMEI index=1 value=000000000000000\n"));
        } else assert(!strstr(output,"APP_IMEI"));
        assert(write_attempts==0);
    }
    scenario=1;fixture();assert(run_read("--snapshot",output,sizeof(output))==20);assert(!strstr(output,"APP_NV")&&!strstr(output,"APP_IMEI"));
    scenario=0;fixture();records[0][1]=0xff;assert(run_read("--read-imei",output,sizeof(output))==23);assert(!strstr(output,"APP_IMEI"));
    scenario=0;fixture();records[1][1]=0xff;assert(run_read("--read-imei",output,sizeof(output))==23);assert(!strstr(output,"APP_IMEI"));
    scenario=0;fixture();assert(run_read("--snapshot",output,sizeof(output))==0);assert(strstr(output,"APP_NV index=0")&&strstr(output,"APP_NV index=1")&&!strstr(output,"APP_IMEI"));
    puts("NV_READ_TESTS_PASS scenarios=19 writes=0 strict_pair_preserved=1");return 0;
}
