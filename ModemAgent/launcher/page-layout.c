#define _GNU_SOURCE
#include "page-layout.h"
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>

static const char *const names[PAGE_LAYOUT_MAX_PAGES]={"info","vpn","esim"};
void page_layout_default(struct page_layout *out){
 *out=(struct page_layout){3,{PAGE_INFO,PAGE_VPN,PAGE_ESIM}};
}
int page_layout_valid(const struct page_layout *layout){
 if(!layout||layout->count>PAGE_LAYOUT_MAX_PAGES)return 0;
 unsigned seen=0;
 for(unsigned i=0;i<layout->count;i++){
  unsigned id=layout->ids[i];if(id>=PAGE_LAYOUT_MAX_PAGES||(seen&(1U<<id)))return 0;seen|=1U<<id;
 }
 return 1;
}
int page_layout_parse(const char *bytes,size_t length,struct page_layout *out){
 static const char header[]="ZTE_LAUNCHER_PAGES_V1\n";
 struct page_layout next={0};*out=next;
 size_t offset=sizeof header-1;
 if(!bytes||length<offset||length>PAGE_LAYOUT_MAX_BYTES||memcmp(bytes,header,offset))return PAGE_LAYOUT_INVALID;
 unsigned seen=0;
 while(offset<length){
  unsigned id=PAGE_LAYOUT_MAX_PAGES;
  for(unsigned candidate=0;candidate<PAGE_LAYOUT_MAX_PAGES;candidate++){
   size_t n=strlen(names[candidate]);
   if(length-offset>=n+1&&!memcmp(bytes+offset,names[candidate],n)&&bytes[offset+n]=='\n'){
    id=candidate;offset+=n+1;break;
   }
  }
  if(id==PAGE_LAYOUT_MAX_PAGES||next.count==PAGE_LAYOUT_MAX_PAGES||(seen&(1U<<id)))return PAGE_LAYOUT_INVALID;
  seen|=1U<<id;next.ids[next.count++]=(unsigned char)id;
 }
 *out=next;return PAGE_LAYOUT_CONFIG;
}
static int trusted_directory(int fd,unsigned owner){
 struct stat st;return !fstat(fd,&st)&&S_ISDIR(st.st_mode)&&st.st_uid==owner&&!(st.st_mode&022);
}
static int private_file(const struct stat *st,unsigned owner){
 return S_ISREG(st->st_mode)&&st->st_uid==owner&&(st->st_mode&07777)==0600&&st->st_nlink==1&&st->st_size>0&&st->st_size<=PAGE_LAYOUT_MAX_BYTES;
}
static int read_layout(const char *parent,const char *directory,unsigned owner,struct page_layout *out){
 *out=(struct page_layout){0};int result=PAGE_LAYOUT_INVALID;
 int data=open(parent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(data<0)return result;
 if(!trusted_directory(data,owner)){close(data);return result;}
 int dir=openat(data,directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);close(data);
 if(dir<0)return result;if(!trusted_directory(dir,owner)){close(dir);return result;}
 int fd=openat(dir,"page-layout.conf",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
 if(fd<0){int missing=errno==ENOENT;close(dir);if(missing){page_layout_default(out);return PAGE_LAYOUT_DEFAULT;}return result;}
 close(dir);
 struct stat before,after;char bytes[PAGE_LAYOUT_MAX_BYTES+1];size_t used=0;
 if(fstat(fd,&before)||!private_file(&before,owner))goto done;
 for(;;){
  ssize_t n=read(fd,bytes+used,sizeof bytes-used);
  if(n<0){if(errno==EINTR)continue;goto done;}
  if(!n)break;used+=(size_t)n;if(used>PAGE_LAYOUT_MAX_BYTES)goto done;
 }
 if(fstat(fd,&after)||!private_file(&after,owner)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_size!=after.st_size||before.st_mtime!=after.st_mtime||before.st_ctime!=after.st_ctime||(off_t)used!=after.st_size)goto done;
 result=page_layout_parse(bytes,used,out);
done:close(fd);return result;
}
int page_layout_read(struct page_layout *out){return read_layout("/data","zte-launcher",0,out);}
#ifdef PAGE_LAYOUT_TEST
int page_layout_read_test(const char *parent,const char *directory,unsigned owner,struct page_layout *out){return read_layout(parent,directory,owner,out);}
#endif
