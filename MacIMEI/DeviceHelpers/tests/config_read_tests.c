/* Offline parser/contract checks; does not load libdiag or access any device. */
#define main device_helper_main
#include "../src/zte_config_read.c"
#undef main
#include <assert.h>

static int fault;
static int mock_send(int proc,unsigned char *req,int n) {
    (void)n;assert(proc==0);uint8_t raw[2048]={0},wire[4096];size_t len=0,w=0;
    memcpy(raw,req,4);
    switch(req[2]) {
        case 15: len=32;put32(raw+8,0x8d00);put32(raw+12,15073);put32(raw+16,1);break;
        case 2: len=12;put32(raw+4,7);break;
        case 3: len=8;break;
        case 4:
            len=20+le32(req+8);put32(raw+4,le32(req+4));put32(raw+8,le32(req+12));put32(raw+12,le32(req+8));
            for(size_t i=20;i<len;i++) raw[i]=(uint8_t)i;
            if(fault==1) put32(raw+4,8);
            if(fault==2) put32(raw+8,le32(req+12)+1);
            if(fault==3) put32(raw+12,le32(req+8)-1);
            if(fault==4) put32(raw+16,13);
            if(fault==5) len--;
            break;
        default: assert(0);
    }
    uint16_t crc=crc16(raw,len);if(fault==6) crc^=1;
    raw[len++]=(uint8_t)crc;raw[len++]=(uint8_t)(crc>>8);
    for(size_t i=0;i<len;i++) {
        if(raw[i]==0x7e||raw[i]==0x7d) { wire[w++]=0x7d;wire[w++]=raw[i]^0x20; }
        else wire[w++]=raw[i];
    }
    wire[w++]=0x7e;
    /* Split through escaped packets as the native callback may do. */
    for(size_t i=0;i<w;i++) callback(wire+i,1,NULL);
    return 0;
}
int main(void) {
    assert(crc16((const uint8_t*)"123456789",9)==0x906e);
    assert(file_crc32((const uint8_t*)"123456789",9)==0xcbf43926);
    send_fn=mock_send;
    struct file_stat st;assert(read_stat(&st,"test")&&st.size==15073&&st.mode==0x8d00);
    assert(open_file()==7);
    uint8_t data[1024];assert(read_chunk(7,0,1024,data));
    for(size_t i=0;i<sizeof(data);i++) assert(data[i]==(uint8_t)(i+20));
    for(fault=1;fault<=6;fault++) {
        memset(data,0xa5,sizeof(data));assert(!read_chunk(7,0,1024,data));
        for(size_t i=0;i<sizeof(data);i++) assert(data[i]==0xa5);
    }
    fault=0;assert(close_file(7));
    uint8_t req[20]={0x4b,0x13,2,0};memcpy(req+12,config_path,sizeof(config_path));
    assert(allowed_request(req,sizeof(req)));req[4]=1;assert(!allowed_request(req,sizeof(req)));
    req[4]=0;req[8]=1;assert(!allowed_request(req,sizeof(req)));
    req[8]=0;req[12]='x';assert(!allowed_request(req,sizeof(req)));
    uint8_t rd[16]={0x4b,0x13,4,0};put32(rd+4,7);put32(rd+8,1024);put32(rd+12,MAX_FILE_SIZE-1024);
    assert(allowed_request(rd,sizeof(rd)));put32(rd+12,MAX_FILE_SIZE-1023);assert(!allowed_request(rd,sizeof(rd)));
    assert(bad_crc_frames==1);
    puts("OFFLINE_EFS_CONFIG_CONTRACT_PASS");return 0;
}
