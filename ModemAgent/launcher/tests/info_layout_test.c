/* cc -std=c11 -Wall -Wextra -Werror info_layout_test.c -o /tmp/info-layout-test */
#include "../info-layout.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned tests,combinations;
static const char config[]="ZTE_INFO_LAYOUT_V1\ncpu=1\nsignal=1\nnetwork=1\ncarriers=1\ncpu_temp=1\nmodem_temp=1\nmemory=0\nstorage=0\nuptime=0\n";
static const char config2[]="ZTE_INFO_LAYOUT_V2\nstyle=tiles\ncpu=1\nsignal=1\nnetwork=1\ncarriers=1\ncpu_temp=1\nmodem_temp=1\nmemory=0\nstorage=0\nuptime=0\nbattery=0\nrsrq=0\nsinr=0\n";
static void reject(const char *bytes,size_t length){
 struct info_layout layout,defaults;memset(&layout,255,sizeof layout);info_layout_default(&defaults);
 assert(!info_layout_parse(bytes,length,&layout));assert(!memcmp(&layout,&defaults,sizeof layout));tests++;
}
static void reject_string(const char *bytes){reject(bytes,strlen(bytes));}
int main(void){
 struct info_layout layout;assert(info_layout_parse(config,sizeof config-1,&layout));assert(info_layout_valid(&layout));assert(info_layout_selected(&layout)==63&&layout.style==INFO_STYLE_LIST);tests++;
 for(unsigned i=9;i<INFO_ROWS;i++)assert(layout.order[i]==i&&!layout.enabled[i]);tests++;
 struct info_slot slots[INFO_MAX_SELECTED];assert(info_layout_slots(&layout,slots)==6);assert(slots[3].metric==INFO_CARRIERS&&slots[3].height==66);
 assert(slots[5].y+slots[5].height==341&&INFO_VIEWPORT_Y+341==417);tests++;
 const char reversed[]="ZTE_INFO_LAYOUT_V1\nuptime=1\nstorage=1\nmemory=1\nmodem_temp=1\ncpu_temp=1\ncarriers=1\nnetwork=1\nsignal=1\ncpu=1\n";
 assert(info_layout_parse(reversed,sizeof reversed-1,&layout));assert(info_layout_selected(&layout)==511);
 assert(info_layout_slots(&layout,slots)==9&&slots[0].metric==INFO_UPTIME&&slots[8].metric==INFO_CPU);
 assert(slots[8].y+slots[8].height==506);assert(slots[8].y+slots[8].height-INFO_VIEWPORT_HEIGHT==160);tests++;
 assert(info_layout_parse(config2,sizeof config2-1,&layout)&&layout.style==INFO_STYLE_TILES&&info_layout_selected(&layout)==63);
 assert(info_layout_slots(&layout,slots)==6&&slots[0].x==14&&slots[1].x==165&&slots[4].y==232&&slots[5].y+slots[5].height==338);tests++;
 for(unsigned i=0;i<INFO_ROWS;i++)layout.enabled[i]=1;
 assert(info_layout_slots(&layout,slots)==12&&slots[11].y+slots[11].height==686&&686-INFO_VIEWPORT_HEIGHT==340);tests++;
 layout.style=INFO_STYLE_LIST;assert(info_layout_slots(&layout,slots)==12&&slots[11].y+slots[11].height==671&&671-INFO_VIEWPORT_HEIGHT==325);tests++;
 reject(NULL,0);reject(config,0);reject(config,sizeof config);reject(config,sizeof config-2);
 reject(config2,sizeof config2);reject(config2,sizeof config2-2);
 reject_string("ZTE_INFO_LAYOUT_V2\ncpu=1\n");reject_string("ZTE_INFO_LAYOUT_V1\n");
 char changed[600];snprintf(changed,sizeof changed,"%s",config);changed[0]='z';reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config);strcpy(strstr(changed,"cpu=1"),"cpu=2\n");reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config);strcpy(strstr(changed,"uptime=0"),"cpu=0\n");reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config);strcpy(strstr(changed,"uptime=0"),"other=0\n");reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config);for(char *p=changed+18;*p;p++)if(*p=='1')*p='0';reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config);changed[23]=0;reject(changed,sizeof config-1);
 snprintf(changed,sizeof changed,"%sbattery=0\n",config);reject_string(changed); /* V1 has exactly 9 old fields. */
 snprintf(changed,sizeof changed,"%s",config2);strstr(changed,"style=tiles")[6]='x';reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config2);strcpy(strstr(changed,"battery=0"),"sinr=1\nrsrq=0\nsinr=0\n");reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config2);*strstr(changed,"sinr=0")=0;reject_string(changed);
 snprintf(changed,sizeof changed,"%sstyle=list\n",config2);reject_string(changed);
 snprintf(changed,sizeof changed,"%s",config2);for(char *p=changed+18;*p;p++)if(*p=='1')*p='0';reject_string(changed);
 memset(changed,'x',sizeof changed);reject(changed,513);tests++;
 /* Exhaust all nonempty selections in 12 cyclic orders and both native styles.
  * Every slot is in horizontal bounds, selected exactly once, without overlap;
  * the last row/card is reachable by the same vertical-only viewport. */
 for(unsigned style=INFO_STYLE_LIST;style<=INFO_STYLE_TILES;style++)for(unsigned mask=1;mask<(1U<<INFO_ROWS);mask++)for(unsigned rotation=0;rotation<INFO_ROWS;rotation++){
  layout.style=(unsigned char)style;
  for(unsigned i=0;i<INFO_ROWS;i++){layout.order[i]=(unsigned char)((i+rotation)%INFO_ROWS);layout.enabled[i]=!!(mask&(1U<<i));}
  assert(info_layout_valid(&layout));unsigned n=info_layout_slots(&layout,slots),seen=0;int end=0;
  for(unsigned i=0;i<n;i++){
   assert(!(seen&(1U<<slots[i].metric)));seen|=1U<<slots[i].metric;
   assert(slots[i].x>=14&&slots[i].x+slots[i].width<=306);
   if(style==INFO_STYLE_LIST){assert(slots[i].x==14&&slots[i].width==292&&slots[i].y==(i?end+7:0));assert(slots[i].height==(slots[i].metric==INFO_CARRIERS?66:48));}
   else{assert(slots[i].x==14+(int)(i%2)*151&&slots[i].y==(int)(i/2)*116&&slots[i].width==141&&slots[i].height==106);}
   for(unsigned j=0;j<i;j++)assert(slots[i].x>=slots[j].x+slots[j].width||slots[j].x>=slots[i].x+slots[i].width||slots[i].y>=slots[j].y+slots[j].height||slots[j].y>=slots[i].y+slots[i].height);
   end=slots[i].y+slots[i].height;
  }
  assert(seen==mask&&end<=(style==INFO_STYLE_LIST?671:686)&&n>=1&&n<=12);
  int scroll_max=end>INFO_VIEWPORT_HEIGHT?end-INFO_VIEWPORT_HEIGHT:0;
  assert(end-scroll_max<=INFO_VIEWPORT_HEIGHT);combinations++;
  /* Exercise the actual V2 parser too, including newly enabled metrics/order. */
  size_t used=(size_t)snprintf(changed,sizeof changed,"ZTE_INFO_LAYOUT_V2\nstyle=%s\n",style==INFO_STYLE_LIST?"list":"tiles");
  for(unsigned i=0;i<INFO_ROWS;i++){unsigned id=layout.order[i];used+=(size_t)snprintf(changed+used,sizeof changed-used,"%s=%u\n",ids[id],layout.enabled[id]);}
  assert(used<=INFO_LAYOUT_MAX_BYTES);struct info_layout parsed;assert(info_layout_parse(changed,used,&parsed)&&!memcmp(&parsed,&layout,sizeof layout));
 }
 tests++;
 memset(&layout,0,sizeof layout);assert(!info_layout_valid(&layout));assert(info_layout_selected(&layout)==63);assert(info_layout_slots(&layout,slots)==6);tests++;
 info_layout_default(&layout);layout.order[8]=255;assert(!info_layout_valid(&layout));tests++;
 info_layout_default(&layout);layout.enabled[8]=2;assert(!info_layout_valid(&layout));tests++;
 info_layout_default(&layout);layout.style=2;assert(!info_layout_valid(&layout));assert(info_layout_slots(&layout,slots)==6&&slots[0].width==292);tests++;
 /* File metadata accepts no links, non-root ownership, shared permissions,
  * devices or overlong/empty files. V2 has the same private-file policy. */
 struct stat st={0};st.st_mode=S_IFREG|0600;st.st_uid=0;st.st_nlink=1;st.st_size=sizeof config2-1;assert(private_file(&st));tests++;
 st.st_uid=1;assert(!private_file(&st));st.st_uid=0;st.st_mode=S_IFREG|0644;assert(!private_file(&st));
 st.st_mode=S_IFREG|0600;st.st_nlink=2;assert(!private_file(&st));st.st_nlink=1;st.st_size=0;assert(!private_file(&st));
 st.st_size=513;assert(!private_file(&st));st.st_size=100;st.st_mode=S_IFIFO|0600;assert(!private_file(&st));
 st.st_mode=S_IFLNK|0600;assert(!private_file(&st));st.st_mode=S_IFREG|04600;assert(!private_file(&st));tests++;
 printf("info layout: %u test groups passed (%u selection/order/style/parser combinations)\n",tests,combinations);return 0;
}
