#define main modem_main_never_called
#include "../src/zte_nv.c"
#undef main
#include <assert.h>
#include "nv_fixture.h"
static uint8_t mock_payload[128], last_request[138];
static size_t last_length;
static int mock_error=0,mock_crc_bad=0,mock_wrong_index=0;
static void inject(const uint8_t *raw,size_t n) {
 uint8_t wire[9000],unescaped[4096]; size_t k=0;
 memcpy(unescaped,raw,n);uint16_t c=crc16(raw,n);unescaped[n++]=(uint8_t)c;unescaped[n++]=(uint8_t)(c>>8);
 if(mock_crc_bad)unescaped[n-1]^=1;
 wire[k++]=0x7e;
 for(size_t i=0;i<n;i++) { if(unescaped[i]==0x7e||unescaped[i]==0x7d){wire[k++]=0x7d;wire[k++]=unescaped[i]^0x20;}else wire[k++]=unescaped[i]; }
 wire[k++]=0x7e;
 for(size_t i=0;i<k;i++) callback(wire+i,1,NULL);
}
static int mock_send(int proc,unsigned char *request,int n) {
 assert(proc==0);assert(n==133||n==138);memcpy(last_request,request,n);last_length=(size_t)n;
 uint8_t a[200]={0};
 if(mock_error) { a[0]=0x47;memcpy(a+1,request,8);inject(a,9);return 0; }
 memcpy(a,request,n);size_t h=n==133?3:8;
 memcpy(a+h,mock_payload,128);
 if(mock_wrong_index&&n==138)a[6]^=1;
 inject(a,(size_t)n);return 0;
}
int main(void) {
    nv_fixture();
 send_fn=mock_send;for(int i=0;i<128;i++)mock_payload[i]=(uint8_t)i;
 uint8_t out[128];assert(read_item(0,out));assert(!memcmp(out,mock_payload,128));assert(last_length==138&&last_request[2]==1&&last_request[6]==0);
 assert(read_item(1,out));assert(last_request[6]==1);assert(read_item(-1,out));assert(last_length==133&&last_request[0]==0x26);
 assert(write_item(0,target[0],0));assert(last_request[2]==2&&last_request[6]==0&&!memcmp(last_request+8,target[0],128));
 assert(write_item(1,original[1],1));assert(last_request[2]==2&&last_request[6]==1&&!memcmp(last_request+8,original[1],128));
 mock_error=1;assert(!read_item(1,out));mock_error=0;
 pthread_mutex_lock(&mutex);wanted[0]=0x4b;wanted[1]=0x30;wanted[2]=1;wanted[3]=0;wanted[4]=0x26;wanted[5]=2;wanted[6]=1;wanted[7]=0;want_len=8;answer_len=0;pthread_mutex_unlock(&mutex);
 uint8_t raw[138]={0x4b,0x30,1,0,0x26,2,1,0};mock_crc_bad=1;inject(raw,138);assert(answer_len==0);mock_crc_bad=0;
 raw[6]=0;inject(raw,138);assert(answer_len==0);raw[6]=1;inject(raw,138);assert(answer_len==138);
 puts("PAIR_REVIEW_TESTS_PASS no modem APIs called");return 0;
}
