#define _GNU_SOURCE
#include "info-layout.h"
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>

static const char *const ids[INFO_ROWS]={"cpu","signal","network","carriers","cpu_temp","modem_temp","memory","storage","uptime","battery","rsrq","sinr"};
void info_layout_default(struct info_layout *out){
 out->style=INFO_STYLE_LIST;
 for(unsigned i=0;i<INFO_ROWS;i++){out->order[i]=(unsigned char)i;out->enabled[i]=i<INFO_DEFAULT_SELECTED;}
}
int info_layout_valid(const struct info_layout *layout){
 if(layout->style!=INFO_STYLE_LIST&&layout->style!=INFO_STYLE_TILES)return 0;
 unsigned seen=0,enabled=0;
 for(unsigned i=0;i<INFO_ROWS;i++){
  unsigned id=layout->order[i];if(id>=INFO_ROWS||(seen&(1U<<id))||layout->enabled[id]>1)return 0;
  seen|=1U<<id;enabled+=layout->enabled[id];
 }
 return enabled>=1&&enabled<=INFO_MAX_SELECTED;
}
int info_layout_parse(const char *bytes,size_t length,struct info_layout *out){
 static const char header1[]="ZTE_INFO_LAYOUT_V1\n",header2[]="ZTE_INFO_LAYOUT_V2\n";
 struct info_layout next={0};info_layout_default(out);
 if(!bytes||length<sizeof header1-1||length>INFO_LAYOUT_MAX_BYTES)return 0;
 unsigned rows;size_t offset=sizeof header1-1;unsigned seen=0;
 if(!memcmp(bytes,header1,offset))rows=9;
 else if(!memcmp(bytes,header2,offset)){
  rows=INFO_ROWS;
  if(length-offset>=11&&!memcmp(bytes+offset,"style=list\n",11)){next.style=INFO_STYLE_LIST;offset+=11;}
  else if(length-offset>=12&&!memcmp(bytes+offset,"style=tiles\n",12)){next.style=INFO_STYLE_TILES;offset+=12;}
  else return 0;
 }else return 0;
 for(unsigned i=0;i<rows;i++){
  unsigned id=INFO_ROWS;
  for(unsigned candidate=0;candidate<rows;candidate++){
   size_t n=strlen(ids[candidate]);
   if(length-offset>=n+3&&!memcmp(bytes+offset,ids[candidate],n)&&bytes[offset+n]=='='){
    char value=bytes[offset+n+1];if((value!='0'&&value!='1')||bytes[offset+n+2]!='\n')return 0;
    id=candidate;next.enabled[id]=(unsigned char)(value-'0');offset+=n+3;break;
   }
  }
  if(id==INFO_ROWS||(seen&(1U<<id)))return 0;seen|=1U<<id;next.order[i]=(unsigned char)id;
 }
 /* V1 preserves all nine positions and appends new metrics disabled. */
 for(unsigned i=rows;i<INFO_ROWS;i++)next.order[i]=(unsigned char)i;
 if(offset!=length||!info_layout_valid(&next))return 0;
 *out=next;return 1;
}
static int trusted_directory(int fd){
 struct stat st;return !fstat(fd,&st)&&S_ISDIR(st.st_mode)&&st.st_uid==0&&!(st.st_mode&022);
}
static int private_file(const struct stat *st){
 return S_ISREG(st->st_mode)&&st->st_uid==0&&(st->st_mode&07777)==0600&&st->st_nlink==1&&st->st_size>0&&st->st_size<=INFO_LAYOUT_MAX_BYTES;
}
int info_layout_read(struct info_layout *out){
 info_layout_default(out);int result=0;
 int data=open("/data",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(data<0)return 0;
 if(!trusted_directory(data)){close(data);return 0;}
 int dir=openat(data,"zte-launcher",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);close(data);
 if(dir<0)return 0;if(!trusted_directory(dir)){close(dir);return 0;}
 int fd=openat(dir,"info-layout.conf",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);close(dir);if(fd<0)return 0;
 struct stat before,after;char bytes[INFO_LAYOUT_MAX_BYTES+1];size_t used=0;
 if(fstat(fd,&before)||!private_file(&before))goto done;
 for(;;){
  ssize_t n=read(fd,bytes+used,sizeof bytes-used);
  if(n<0){if(errno==EINTR)continue;goto done;}
  if(!n)break;used+=(size_t)n;if(used>INFO_LAYOUT_MAX_BYTES)goto done;
 }
 if(fstat(fd,&after)||!private_file(&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_size!=after.st_size||before.st_mtime!=after.st_mtime||before.st_ctime!=after.st_ctime||(off_t)used!=after.st_size)goto done;
 result=info_layout_parse(bytes,used,out);
done:close(fd);return result;
}
unsigned info_layout_selected(const struct info_layout *layout){
 struct info_layout defaults;if(!info_layout_valid(layout)){info_layout_default(&defaults);layout=&defaults;}
 unsigned selected=0;for(unsigned i=0;i<INFO_ROWS;i++)if(layout->enabled[i])selected|=1U<<i;return selected;
}
unsigned info_layout_slots(const struct info_layout *layout,struct info_slot out[INFO_MAX_SELECTED]){
 struct info_layout defaults;if(!info_layout_valid(layout)){info_layout_default(&defaults);layout=&defaults;}
 unsigned count=0;int y=0;
 for(unsigned i=0;i<INFO_ROWS;i++)if(layout->enabled[layout->order[i]]){
  unsigned id=layout->order[i];int height=id==INFO_CARRIERS?66:48;
  if(layout->style==INFO_STYLE_TILES){out[count]=(struct info_slot){id,14+(int)(count%2)*151,(int)(count/2)*116,141,106};count++;}
  else{out[count++]=(struct info_slot){id,14,y,292,height};y+=height+7;}
 }
 return count;
}
