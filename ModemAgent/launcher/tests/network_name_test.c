#include "../network-name.h"
#include "../network-name-abi.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static const char *full_text="Tele2",*short_text="T2";
static int full_error,short_error,unterminated;
static unsigned full_calls,short_calls;
static int full(char *out,int size){++full_calls;if(unterminated)memset(out,'X',(size_t)size);else snprintf(out,(size_t)size,"%s",full_text);return full_error;}
static int short_name(char *out,int size){++short_calls;snprintf(out,(size_t)size,"%s",short_text);return short_error;}
static void expect_ascii(const char *expected){
 struct {uint32_t a,out[128],b;} guarded;
 memset(&guarded,0xa5,sizeof guarded);
 network_name_read(guarded.out,128,full,short_name);
 assert(guarded.a==0xa5a5a5a5&&guarded.b==0xa5a5a5a5);
 for(size_t i=0;i<=strlen(expected);++i)assert(guarded.out[i]==(unsigned char)expected[i]);
}
static uintptr_t bad_pointer,bad_word;
static uintptr_t pointer(uintptr_t address){
 if(address==bad_pointer)return 0;
 for(size_t i=0;i<2;++i)if(address==network_name_hooks[i].slot)return network_name_hooks[i].target;
 assert(address==NETWORK_NAME_FULL_GETTER_SLOT||address==NETWORK_NAME_SHORT_GETTER_SLOT);return 0x1234;
}
static uint32_t word(uintptr_t address){
 for(size_t i=0;i<2;++i)if(address>=network_name_hooks[i].target&&address<network_name_hooks[i].target+32)
  return network_name_hooks[i].prolog[(address-network_name_hooks[i].target)/4]^(address==bad_word);
 assert(0);return 0;
}
int main(void){
 expect_ascii("Tele2");assert(full_calls==1&&short_calls==0);
 full_text="Vodafone";expect_ascii("Vodafone"); /* Active network changes, no cached override. */
 full_text="  Tele2  ";expect_ascii("Tele2");
 full_text="";expect_ascii("T2");
 full_error=1;full_text="old name";expect_ascii("T2");full_error=0;
 const char *invalid[]={"\xc0\xaf","\xe0\x80\xaf","\xed\xa0\x80","\xf4\x90\x80\x80","\xf0\x9f",("\xe2\x80\xae" "fake"),"bad\nname","bad\x7f"};
 for(size_t i=0;i<sizeof invalid/sizeof invalid[0];++i){full_text=invalid[i];expect_ascii("T2");}
 unterminated=1;expect_ascii("T2");unterminated=0;
 uint32_t out[128];full_text="中国联通";network_name_read(out,128,full,short_name);
 assert(out[0]==0x4e2d&&out[1]==0x56fd&&out[2]==0x8054&&out[3]==0x901a&&out[4]==0);
 full_text="МегаФон";network_name_read(out,128,full,short_name);assert(out[0]==0x41c&&out[6]==0x43d&&out[7]==0);
 full_text="A😀B";network_name_read(out,128,full,short_name);assert(out[0]=='A'&&out[1]==0x1f600&&out[2]=='B'&&out[3]==0);
 char long_name[256];memset(long_name,'A',255);long_name[255]=0;full_text=long_name;
 network_name_read(out,128,full,short_name);for(size_t i=0;i<57;++i)assert(out[i]=='A');assert(out[57]=='.'&&out[59]=='.'&&out[60]==0);
 long_name[254]='\n';expect_ascii("T2"); /* Invalid suffix must not escape validation. */
 for(size_t cap=0;cap<=128;++cap){
  uint32_t tiny[130];for(size_t i=0;i<130;++i)tiny[i]=0xfeedbeef;
  full_text="Tele2";network_name_read(tiny+1,cap,full,short_name);
  assert(tiny[0]==0xfeedbeef&&tiny[cap+1]==0xfeedbeef);
  if(cap){int nul=0;for(size_t i=0;i<cap;++i)if(!tiny[i+1])nul=1;assert(nul);}
 }
 full_text="";short_error=1;network_name_read(out,128,full,short_name);assert(out[0]==0x2014&&out[1]==0);
 network_name_read(out,128,NULL,NULL);assert(out[0]==0x2014&&out[1]==0);
 network_name_read(NULL,128,full,short_name);
 assert(network_name_abi_valid(pointer,word));
 for(size_t i=0;i<2;++i){
  bad_pointer=network_name_hooks[i].slot;assert(!network_name_abi_valid(pointer,word));bad_pointer=0;
  for(size_t n=0;n<8;++n){bad_word=network_name_hooks[i].target+n*4;assert(!network_name_abi_valid(pointer,word));}bad_word=0;
 }
 bad_pointer=NETWORK_NAME_FULL_GETTER_SLOT;assert(!network_name_abi_valid(pointer,word));
 bad_pointer=NETWORK_NAME_SHORT_GETTER_SLOT;assert(!network_name_abi_valid(pointer,word));
 puts("network-name: dynamic provider, UTF-8, byte budget, canaries, ABI mutations PASS");
 return 0;
}
