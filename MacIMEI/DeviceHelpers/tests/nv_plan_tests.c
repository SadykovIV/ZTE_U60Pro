#define main device_main_never_called
#include "../src/zte_nv.c"
#undef main
#include <assert.h>
#include <stdlib.h>
#include "nv_fixture.h"
int main(void) {
    nv_fixture();
    target[0][127]^=1;assert(!plan_valid());nv_fixture();
    target[0][1]^=0x10;assert(!plan_valid());nv_fixture();
    target[0][1]=0x0b;assert(!plan_valid());nv_fixture();
    target[0][2]=0xff;assert(!plan_valid());nv_fixture();
    original[0][0]=9;assert(!plan_valid());nv_fixture();
    memcpy(target[1],target[0],9);assert(!plan_valid());nv_fixture();
    char path[]="/tmp/zte-nv-plan-XXXXXX";
    int fd=mkstemp(path);assert(fd>=0);
    uint8_t bytes[512];memcpy(bytes,original,256);memcpy(bytes+256,target,256);
    assert(write(fd,bytes,sizeof(bytes))==(ssize_t)sizeof(bytes));assert(close(fd)==0);
    assert(load_plan(path));assert(!load_plan("relative-plan"));
    char linkpath[100];snprintf(linkpath,sizeof(linkpath),"%s-link",path);
    assert(symlink(path,linkpath)==0);assert(!load_plan(linkpath));assert(unlink(linkpath)==0);
    assert(link(path,linkpath)==0);assert(!load_plan(path));assert(unlink(linkpath)==0);
    fd=open(path,O_WRONLY|O_APPEND);assert(fd>=0);assert(write(fd,bytes,1)==1);assert(close(fd)==0);
    assert(!load_plan(path));assert(truncate(path,511)==0);assert(!load_plan(path));
    assert(unlink(path)==0);assert(!load_plan(path));
    puts("NV_PLAN_TESTS_PASS valid luhn bcd tail distinct exact_size absolute_path symlink hardlink missing");
    return 0;
}
