#define main device_main_never_called
#include "../src/zte_config.c"
#undef main
#include <assert.h>
#include <stdlib.h>
#include "config_fixture.h"
static void update_crc(void) {
    put32(config_original+12,config_crc(config_original));
    put32(config_candidate+12,config_crc(config_candidate));
}
int main(void) {
    config_fixture();
    config_candidate[600]^=1;update_crc();assert(!plan_valid());config_fixture();
    config_original[0]^=1;update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+4,248);update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+8,CONFIG_SIZE-1);update_crc();assert(!plan_valid());config_fixture();
    config_original[CONFIG_SIZE-1]^=1;update_crc();assert(!plan_valid());config_fixture();
    config_original[12]^=1;assert(!plan_valid());config_fixture();
    put32(config_original+20,CONFIG_SIZE);update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+20,15);update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+24,0);update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+109,1000);update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+483,105);update_crc();assert(!plan_valid());config_fixture();
    put32(config_original+495,1);update_crc();assert(!plan_valid());config_fixture();
    config_candidate[499]=2;update_crc();assert(!plan_valid());config_fixture();
    char path[]="/tmp/zte-config-plan-XXXXXX";int fd=mkstemp(path);assert(fd>=0);
    assert(write(fd,config_original,CONFIG_SIZE)==CONFIG_SIZE);
    assert(write(fd,config_candidate,CONFIG_SIZE)==CONFIG_SIZE);assert(close(fd)==0);
    assert(load_plan(path));assert(truncate(path,2*CONFIG_SIZE-1)==0);assert(!load_plan(path));
    assert(unlink(path)==0);
    puts("CONFIG_PLAN_TESTS_PASS valid sole_diff magic count length trailer crc bounds duplicate id102 flag exact_size");
    return 0;
}
