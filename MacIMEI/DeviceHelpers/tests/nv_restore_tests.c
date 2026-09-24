/* Offline stateful tests: modem_main_never_called is never invoked.
 * send_fn is replaced before every request; no libdiag/device access.
 */
#define main modem_main_never_called
#include "../src/zte_nv.c"
#undef main
#include <assert.h>
#include "nv_fixture.h"

static uint8_t device_pair[2][128];
static unsigned mock_reads,mock_writes;
static int order[2],fail_write=-1,fail_read=-2,alias_bad,alter_other;

static void inject_reply(const uint8_t *raw,size_t count) {
    uint8_t packet[140],wire[282];size_t size=0;
    assert(count<=138);memcpy(packet,raw,count);
    uint16_t checksum=crc16(packet,count);
    packet[count++]=(uint8_t)checksum;packet[count++]=(uint8_t)(checksum>>8);
    for(size_t i=0;i<count;i++) {
        if(packet[i]==0x7d||packet[i]==0x7e) { wire[size++]=0x7d;wire[size++]=packet[i]^0x20; }
        else wire[size++]=packet[i];
    }
    wire[size++]=0x7e;callback(wire,(int)size,NULL);
}
static int mock_send(int processor,unsigned char *request,int size) {
    assert(processor==0);assert(size==133||size==138);
    uint8_t response[138];memcpy(response,request,(size_t)size);
    int index=size==133?-1:request[6];assert(index>=-1&&index<=1);
    if(size==138&&request[2]==2) {
        assert(request[0]==0x4b&&request[1]==0x30&&request[3]==0&&request[4]==0x26&&request[5]==2&&request[7]==0);
        assert(mock_writes<2);order[mock_writes++]=index;
        assert(!memcmp(request+8,original[index],128));
        assert(!memcmp(device_pair[index],target[index],128));
        if(index==fail_write) response[136]=7;
        else {
            memcpy(device_pair[index],request+8,128);
            if(alter_other) device_pair[1-index][127]^=1;
        }
    } else {
        assert((size==133&&request[0]==0x26)||(size==138&&request[2]==1));
        mock_reads++;
        memcpy(response+(size==133?3:8),device_pair[index<0?0:index],128);
        if(index==fail_read) response[size-2]=5;
        if(index<0&&alias_bad) response[3+127]^=1;
    }
    inject_reply(response,(size_t)size);return 0;
}
static void reset_state(int target0,int target1) {
    memcpy(device_pair[0],target0?target[0]:original[0],128);
    memcpy(device_pair[1],target1?target[1]:original[1],128);
    mock_reads=mock_writes=write_attempts=0;
    order[0]=order[1]=-1;fail_write=-1;fail_read=-2;alias_bad=alter_other=0;
    interrupted=0;send_fn=mock_send;
}
static int run_restore(void) {
    uint8_t baseline[2][128];
    return snapshot(baseline)&&restore_known_pair(baseline);
}
int main(void) {
    nv_fixture();
    reset_state(0,0);assert(run_restore());assert(mock_writes==0&&mock_reads==3);
    reset_state(1,1);assert(run_restore());assert(mock_writes==2&&mock_reads==9);
    assert(order[0]==1&&order[1]==0&&same(device_pair,original));
    reset_state(1,0);assert(run_restore());assert(mock_writes==1&&order[0]==0&&mock_reads==6);
    reset_state(0,1);assert(run_restore());assert(mock_writes==1&&order[0]==1&&mock_reads==6);
    reset_state(0,1);device_pair[0][127]^=1;assert(!run_restore());assert(mock_writes==0);
    reset_state(1,0);device_pair[1][127]^=1;assert(!run_restore());assert(mock_writes==0);
    reset_state(1,1);alias_bad=1;assert(!run_restore());assert(mock_writes==0);
    reset_state(1,1);fail_read=1;assert(!run_restore());assert(mock_writes==0);
    reset_state(1,1);fail_write=1;assert(!run_restore());assert(mock_writes==1&&order[0]==1&&mock_reads==6);
    assert(same(device_pair,target));
    reset_state(1,1);alter_other=1;assert(!run_restore());assert(mock_writes==1&&order[0]==1);
    reset_state(1,1);device_pair[1][127]^=1;assert(!restore_originals());
    assert(mock_writes==1&&order[0]==0&&!memcmp(device_pair[0],original[0],128));
    reset_state(1,1);device_pair[0][127]^=1;assert(!restore_originals());
    assert(mock_writes==1&&order[0]==1&&!memcmp(device_pair[1],original[1],128));
    puts("PAIR_RESTORE_TESTS_PASS original_noop both_reverse mixed_slots unknown_full128 legacy_alias read_error write_status_error collateral_change; no modem APIs called");
    return 0;
}
