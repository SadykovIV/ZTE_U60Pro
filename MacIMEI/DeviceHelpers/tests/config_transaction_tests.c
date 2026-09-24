/* Local-only DIAG/EFS model. This includes the production source unchanged.
 * No dlopen, device, network, or real filesystem mutation is performed. */
#define main device_main
#include "../src/zte_config.c"
#undef main
#include <assert.h>
#include "config_fixture.h"
#include <stdlib.h>

struct model_file { int exists;uint32_t size,mode;uint8_t data[CONFIG_SIZE]; };
static struct model_file model[3];
static struct model_file backing_store[3];
static int mock_fd=-1,mock_ix=-1,mutations,commits,rollbacks;
static int fault,fault_used,post_commit_reads;
enum { NO_FAULT, SHORT_WRITE, RENAME_DENIED, POST_COMMIT_READ_ERROR,
       COMMIT_ACK_LOST, OPEN_ACK_MALFORMED, POST_COMMIT_WRONG_FD,
       POST_COMMIT_UNKNOWN_DATA, POST_COMMIT_SYNC_ERROR, SIGNAL_AT_COMMIT,
       FINAL_CLEANUP_SYNC_ERROR };
static void respond(const uint8_t *p,size_t n) {
    uint8_t wire[8192];size_t z=0;uint16_t crc=crc16(p,n);
    for(size_t i=0;i<n+2;i++) {
        uint8_t v=i<n?p[i]:(uint8_t)(crc>>(8*(i-n)));
        if(v==0x7e||v==0x7d) { wire[z++]=0x7d;wire[z++]=v^0x20; }
        else wire[z++]=v;
    }
    wire[z++]=0x7e;callback(wire,(int)z,NULL);
}
static int mock_send(int unused,unsigned char *p,int ni) {
    (void)unused;size_t n=(size_t)ni;
    assert(allowed_request(p,n));
    uint8_t r[4096]={0};memcpy(r,p,4);size_t rn=0;
    int ix;uint32_t off,count;
    switch(p[2]) {
        case 15:
            ix=path_index(p,n,4);assert(ix>=0);rn=32;
            if(!model[ix].exists) put32(r+4,2);
            else { put32(r+8,model[ix].mode);put32(r+12,model[ix].size);put32(r+16,1);put32(r+20,123);put32(r+24,100);put32(r+28,100); }
            break;
        case 2:
            ix=path_index(p,n,12);assert(ix>=0);rn=12;
            if(le32(p+4)==0xc1) {
                assert(ix>0);
                if(model[ix].exists) { put32(r+4,UINT32_MAX);put32(r+8,6);break; }
                memset(&model[ix],0,sizeof(model[ix]));model[ix].exists=1;model[ix].mode=0x8d00;mutations++;
            } else assert(model[ix].exists);
            assert(mock_fd<0);mock_fd=71;mock_ix=ix;put32(r+4,71);
            if(fault==OPEN_ACK_MALFORMED&&!fault_used&&ix==2&&le32(p+4)==0xc1) { fault_used=1;rn=8; }
            break;
        case 3:
            assert(le32(p+4)==(uint32_t)mock_fd);mock_fd=-1;mock_ix=-1;rn=8;break;
        case 4:
            assert(le32(p+4)==(uint32_t)mock_fd);off=le32(p+12);count=le32(p+8);
            assert(off+count<=model[mock_ix].size);put32(r+4,71);put32(r+8,off);put32(r+12,count);
            memcpy(r+20,model[mock_ix].data+off,count);rn=20+count;
            if(mock_ix==0&&commits&&!rollbacks) post_commit_reads++;
            if(mock_ix==0&&commits&&!rollbacks&&!fault_used&&fault==POST_COMMIT_READ_ERROR) {
                fault_used=1;put32(r+12,0);put32(r+16,13);rn=20;
            }
            if(mock_ix==0&&commits&&!rollbacks&&!fault_used&&fault==POST_COMMIT_WRONG_FD) {
                fault_used=1;put32(r+4,999);
            }
            break;
        case 5:
            assert(mock_ix>0&&le32(p+4)==(uint32_t)mock_fd);off=le32(p+8);count=(uint32_t)(n-12);
            if(fault==SHORT_WRITE&&!fault_used) { fault_used=1;count--; }
            memcpy(model[mock_ix].data+off,p+12,count);
            if(model[mock_ix].size<off+count) model[mock_ix].size=off+count;
            mutations++;rn=20;put32(r+4,71);put32(r+8,off);put32(r+12,count);break;
        case 8:
            ix=path_index(p,n,4);assert(ix>0&&model[ix].exists);model[ix].exists=0;mutations++;rn=8;break;
        case 14:
            assert(mock_fd<0);ix=!strcmp((char*)p+4,stage_path)?1:2;assert(model[ix].exists);
            rn=8;
            if(fault==RENAME_DENIED&&!fault_used&&ix==1) { fault_used=1;put32(r+4,26);break; }
            model[0]=model[ix];model[ix].exists=0;mutations++;
            if(ix==1) commits++;else rollbacks++;
            if(fault==POST_COMMIT_UNKNOWN_DATA&&ix==1) { model[0].data[700]^=1;fault_used=1; }
            if(fault==SIGNAL_AT_COMMIT&&ix==1) { interrupted=SIGTERM;fault_used=1; }
            if(fault==COMMIT_ACK_LOST&&!fault_used&&ix==1) { fault_used=1;return -1; }
            break;
        case 48:
            rn=14;r[4]=p[4];r[5]=p[5];put32(r+6,80);put32(r+10,306);
            if(fault==POST_COMMIT_SYNC_ERROR&&commits&&!rollbacks&&!fault_used) { fault_used=1;put32(r+10,13); }
            if(fault==FINAL_CLEANUP_SYNC_ERROR&&commits&&!model[1].exists&&!model[2].exists&&!fault_used) { fault_used=1;put32(r+10,13); }
            if(le32(r+10)==306) memcpy(backing_store,model,sizeof(model));
            break;
        case 49: assert(0);break;
        default: assert(0);
    }
    respond(r,rn);return 0;
}
static void reset_model(int candidate_live,int selected_fault,int want_candidate) {
    memset(model,0,sizeof(model));model[0].exists=1;model[0].size=CONFIG_SIZE;model[0].mode=0x8d00;
    memcpy(model[0].data,candidate_live?config_candidate:config_original,CONFIG_SIZE);
    memcpy(backing_store,model,sizeof(model));
    before_bytes=want_candidate?config_original:config_candidate;
    after_bytes=want_candidate?config_candidate:config_original;
    file_fd=-1;file_access=file_index=owned_stage=owned_rollback=0;
    commit_ready=commit_attempted=rollback_ready=rolling_back=0;
    transport_uncertain=target_verified=rollback_verified=retain_files=0;
    interrupted=0;pending=0;answer_len=frame_len=0;frame_escape=frame_bad=0;
    sync_sequence=0;sync_token=0;send_count=valid_frames=bad_crc_frames=0;
    mock_fd=-1;mock_ix=-1;mutations=commits=rollbacks=0;fault=selected_fault;fault_used=post_commit_reads=0;
    send_fn=mock_send;
}
static int live_is(const uint8_t *p) { return model[0].exists&&model[0].size==CONFIG_SIZE&&!memcmp(model[0].data,p,CONFIG_SIZE); }
static void assert_clean(void) { assert(!model[1].exists&&!model[2].exists&&mock_fd<0&&!owned_stage&&!owned_rollback); }
static void simulate_reboot(void) { memcpy(model,backing_store,sizeof(model)); }
static void test_guards(void) {
    reset_model(0,0,1);uint8_t p[128]={0x4b,0x13,5,0};
    file_fd=71;file_access=1;file_index=0;put32(p+4,71);memcpy(p+12,config_candidate,16);
    assert(!allowed_request(p,28)); /* Never direct-write /config. */
    file_index=1;assert(!allowed_request(p,28));owned_stage=1;assert(allowed_request(p,28));
    p[12]^=1;assert(!allowed_request(p,28));p[12]^=1;
    put32(p+8,CONFIG_SIZE-1);assert(!allowed_request(p,28));
    file_fd=-1;memset(p,0,sizeof(p));p[0]=0x4b;p[1]=0x13;p[2]=8;
    memcpy(p+4,config_path,sizeof(config_path));assert(!allowed_request(p,4+sizeof(config_path)));
    p[2]=14;memcpy(p+4,stage_path,sizeof(stage_path));memcpy(p+4+sizeof(stage_path),config_path,sizeof(config_path));
    size_t n=4+sizeof(stage_path)+sizeof(config_path);assert(!allowed_request(p,n));
    commit_ready=1;assert(allowed_request(p,n));transport_uncertain=1;assert(!allowed_request(p,n));
    transport_uncertain=0;p[1]=0x3e;assert(!allowed_request(p,n));
    for(unsigned op=0;op<256;op++) if(op!=2&&op!=3&&op!=4&&op!=5&&op!=8&&op!=14&&op!=15&&op!=48&&op!=49) {
        p[1]=0x13;p[2]=(uint8_t)op;assert(!allowed_request(p,n));
    }
}
int main(void) {
    config_fixture();assert(plan_valid());test_guards();
    reset_model(0,0,1);assert(run_operation(0)==0);assert(live_is(config_candidate)&&target_verified&&commits==1&&!rollbacks);assert_clean();simulate_reboot();assert(live_is(config_candidate));assert_clean();
    reset_model(1,0,0);assert(run_operation(0)==0);assert(live_is(config_original)&&target_verified&&commits==1);assert_clean();simulate_reboot();assert(live_is(config_original));assert_clean();
    reset_model(1,0,1);assert(run_operation(0)==0);assert(!mutations&&target_verified);assert_clean();
    reset_model(0,0,0);assert(run_operation(1)==0);assert(!mutations&&target_verified);assert_clean();
    reset_model(0,0,1);assert(run_operation(1)!=0);assert(!mutations&&!target_verified);assert_clean();
    reset_model(0,0,1);model[0].data[800]^=1;assert(run_operation(0)!=0);assert(!mutations&&!commits);assert_clean();
    reset_model(0,0,1);model[1].exists=1;assert(run_operation(0)!=0);assert(!mutations&&model[1].exists&&!owned_stage);
    reset_model(0,SHORT_WRITE,1);assert(run_operation(0)!=0);assert(live_is(config_original)&&!commits);assert_clean();
    reset_model(0,RENAME_DENIED,1);assert(run_operation(0)!=0);assert(live_is(config_original)&&!commits&&!rollbacks&&rollback_verified);assert_clean();
    reset_model(0,POST_COMMIT_READ_ERROR,1);assert(run_operation(0)!=0);assert(live_is(config_original)&&commits==1&&rollbacks==1&&rollback_verified);assert_clean();
    reset_model(0,POST_COMMIT_SYNC_ERROR,1);assert(run_operation(0)!=0);assert(live_is(config_original)&&rollbacks==1&&rollback_verified);assert_clean();
    reset_model(0,SIGNAL_AT_COMMIT,1);assert(run_operation(0)!=0);assert(live_is(config_original)&&rollbacks==1&&rollback_verified);assert_clean();
    reset_model(0,COMMIT_ACK_LOST,1);assert(run_operation(0)!=0);assert(live_is(config_candidate)&&!rollbacks&&transport_uncertain&&retain_files&&model[2].exists);
    reset_model(0,POST_COMMIT_WRONG_FD,1);assert(run_operation(0)!=0);assert(live_is(config_candidate)&&!rollbacks&&transport_uncertain&&retain_files&&model[2].exists);
    reset_model(0,OPEN_ACK_MALFORMED,1);assert(run_operation(0)!=0);assert(live_is(config_original)&&!commits&&transport_uncertain&&model[2].exists&&!owned_rollback);
    reset_model(0,POST_COMMIT_UNKNOWN_DATA,1);assert(run_operation(0)!=0);assert(!live_is(config_original)&&!live_is(config_candidate)&&!rollbacks&&retain_files&&model[2].exists);
    reset_model(0,FINAL_CLEANUP_SYNC_ERROR,1);assert(run_operation(0)!=0);assert(live_is(config_candidate)&&target_verified&&!rollbacks&&retain_files);simulate_reboot();assert(live_is(config_candidate)&&model[2].exists);
    reset_model(0,0,0);model[0].mode=0x8d20;assert(run_operation(0)==0);assert(live_is(config_original)&&target_verified&&!mutations&&!commits);assert_clean();
    reset_model(0,0,0);model[0].mode=0x8d20;assert(run_operation(1)==0);assert(target_verified&&!mutations);assert_clean();
    reset_model(0,0,0);model[0].mode=0x8d40;assert(run_operation(0)!=0);assert(!target_verified&&!mutations);assert_clean();
    reset_model(0,0,0);model[0].mode=0x4d20;assert(run_operation(0)!=0);assert(!target_verified&&!mutations);assert_clean();
    reset_model(0,0,1);model[1]=model[0];model[1].mode=0x8d20;owned_stage=1;uint8_t scratch[CONFIG_SIZE];assert(!read_file(1,scratch));assert(!mutations&&mock_fd<0);
    puts("CONFIG_UPDATE_HOST_TESTS_PASS scenarios=22 guard_allowlist=PASS cleanup_durability=PASS live_mode8d20=PASS staging_mode_strict=PASS");return 0;
}
