#include "../abi.h"
#include <assert.h>
#include <stdio.h>

static const struct launcher_abi *fixture;
static uintptr_t corrupted;
static uintptr_t pointer_at(uintptr_t address) {
 for(size_t i=0;i<5;i++)if(fixture->hooks[i].slot==address)
  return fixture->hooks[i].target+(address==corrupted?4:0);
 assert(0);return 0;
}
static uint32_t word_at(uintptr_t address) {
 for(size_t i=0;i<9;i++)if(fixture->checks[i].address==address)
  return fixture->checks[i].word^(address==corrupted?1:0);
 assert(0);return 0;
}
int main(void) {
 unsigned count=0;
 assert(!launcher_abi_select(0x400040,0x421dc8));count++;
 assert(!launcher_abi_select(0x500040,0x421dc4));count++;
 assert(!launcher_abi_valid(NULL,pointer_at,word_at));count++;
 for(size_t p=0;p<2;p++) {
  fixture=launcher_abi_select(launcher_abis[p].phdr,launcher_abis[p].entry);
  assert(fixture==&launcher_abis[p]);corrupted=0;
  assert(launcher_abi_valid(fixture,pointer_at,word_at));count++;
  for(size_t i=0;i<5;i++) {
   corrupted=fixture->hooks[i].slot;
   assert(!launcher_abi_valid(fixture,pointer_at,word_at));count++;
  }
  for(size_t i=0;i<9;i++) {
   corrupted=fixture->checks[i].address;
   assert(!launcher_abi_valid(fixture,pointer_at,word_at));count++;
  }
  for(size_t i=0;i<34;i++) {
   assert(launcher_abi_address(fixture,launcher_abis[0].functions[i])==fixture->functions[i]);count++;
  }
  assert(!launcher_abi_address(fixture,0x400000));count++;
 }
 assert(!launcher_abi_address(NULL,0x433134));count++;
 printf("launcher ABI %u PASS\n",count);
}
