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
static int active_count=1,write_count,fail_ack,activate_after_write,secondary_status=5;
#include "nv_fixture.h"
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
    assert(n==138||n==133);
    size_t head=n==138?8:3;unsigned index=n==138?request[6]:0;
    assert(index<2);
    uint8_t response[160]={0};memcpy(response,request,(size_t)n);
    if(n==138&&request[2]==2) {
        assert(index<(unsigned)active_count);write_count++;
        memcpy(records[index],request+8,128);
        if(fail_ack&&write_count==1) response[n-2]=7;
        if(activate_after_write) active_count=2;
    } else {
        assert(n==133||request[2]==1);
        for(int i=(int)head;i<n;i++) assert(!request[i]);
        memcpy(response+head,records[index],128);
        if(index==1&&active_count==1) response[n-2]=(uint8_t)secondary_status;
    }
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
static int run_plan(const char *mode,const char *path) {
    char *args[]={"zte_nv",(char*)mode,(char*)path,NULL};int result=support_main(3,args);alarm(0);return result;
}
static void setup(int count) {
    fixture();plan_count=2;nv_fixture();memcpy(records,original,sizeof(records));
    active_count=count;write_count=fail_ack=activate_after_write=0;secondary_status=5;
}
static void write_plan_file(const char *path,int count) {
    FILE *file=fopen(path,"wb");assert(file);
    assert(fwrite(original,128,(size_t)count,file)==(size_t)count);
    assert(fwrite(target,128,(size_t)count,file)==(size_t)count);assert(!fclose(file));
}
int main(void) {
    char dir[]="/tmp/zte-nv-topology-XXXXXX";assert(mkdtemp(dir));char path[256];snprintf(path,sizeof(path),"%s/plan",dir);
    char output[8192];
    for(int count=1;count<=2;count++) {
        setup(count);assert(run_read("--snapshot-available",output,sizeof(output))==0);
        assert(strstr(output,count==1?"APP_NV_TOPOLOGY count=1 secondary=not-active-status5":"APP_NV_TOPOLOGY count=2 secondary=active"));
        assert((strstr(output,"APP_NV index=1")!=NULL)==(count==2));assert(!write_count);
        write_plan_file(path,count);assert(run_plan("--check-plan-original",path)==0);assert(!write_count);
        assert(run_plan("--apply-plan",path)==0);assert(write_count==count);assert(!memcmp(records,target,(size_t)count*128));
        assert(run_plan("--verify-plan",path)==0);assert(write_count==count);
        assert(run_plan("--restore-plan-original",path)==0);assert(write_count==2*count);assert(!memcmp(records,original,(size_t)count*128));
        setup(count);write_plan_file(path,count);fail_ack=1;
        assert(run_plan("--apply-plan",path)==30);assert(write_count==2);assert(!memcmp(records,original,(size_t)count*128));
    }
    setup(1);write_plan_file(path,2);assert(run_plan("--apply-plan",path)==20);assert(!write_count);
    setup(2);write_plan_file(path,1);assert(run_plan("--apply-plan",path)==20);assert(!write_count);
    setup(1);write_plan_file(path,1);secondary_status=4;assert(run_plan("--apply-plan",path)==20);assert(!write_count);
    setup(1);uint8_t saved_secondary[128];memcpy(saved_secondary,records[1],128);write_plan_file(path,1);activate_after_write=1;assert(run_plan("--apply-plan",path)==31);assert(write_count==1);
    assert(!memcmp(records[1],saved_secondary,128));
    setup(1);write_plan_file(path,1);records[0][127]^=1;assert(run_plan("--restore-plan-original",path)==32);assert(!write_count);
    assert(!unlink(path));assert(!rmdir(dir));
    puts("NV_TOPOLOGY_TESTS_PASS single_pair_snapshot_backup_plan_apply_verify_restore_lost_ack_topology_drift_status4_unknown_tail; synthetic only");return 0;
}
