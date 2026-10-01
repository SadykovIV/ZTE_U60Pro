#define _GNU_SOURCE
#include "../page-layout.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char header[]="ZTE_LAUNCHER_PAGES_V1\n";
static const char *const names[]={"info\n","vpn\n","esim\n"};
static void reject(const char *s,size_t n){struct page_layout p={3,{2,1,0}};assert(page_layout_parse(s,n,&p)==PAGE_LAYOUT_INVALID);assert(p.count==0);}
static void formats(void){
 unsigned valid=0;
 /* Exhaust every ordered subset, including empty, without relying on the parser. */
 for(unsigned count=0;count<=3;count++)for(unsigned a=0;a<3;a++)for(unsigned b=0;b<3;b++)for(unsigned c=0;c<3;c++){
  if((count==0&&(a||b||c))||(count==1&&(b||c))||(count==2&&c))continue;
  if((count>1&&a==b)||(count>2&&(a==c||b==c)))continue;
  unsigned ids[]={a,b,c};char text[128];strcpy(text,header);
  for(unsigned i=0;i<count;i++)strcat(text,names[ids[i]]);
  struct page_layout p;assert(page_layout_parse(text,strlen(text),&p)==PAGE_LAYOUT_CONFIG);assert(p.count==count&&page_layout_valid(&p));
  for(unsigned i=0;i<count;i++)assert(p.ids[i]==ids[i]);valid++;
 }
 assert(valid==16);
 const char *bad[]={"","ZTE_LAUNCHER_PAGES_V2\n","ZTE_LAUNCHER_PAGES_V1","ZTE_LAUNCHER_PAGES_V1\r\n","ZTE_LAUNCHER_PAGES_V1\ninfo","ZTE_LAUNCHER_PAGES_V1\ninfo\ninfo\n","ZTE_LAUNCHER_PAGES_V1\ninfo\nvpn\nesim\ninfo\n","ZTE_LAUNCHER_PAGES_V1\n\n","ZTE_LAUNCHER_PAGES_V1\n info\n","ZTE_LAUNCHER_PAGES_V1\nINFO\n","ZTE_LAUNCHER_PAGES_V1\nunknown\n","ZTE_LAUNCHER_PAGES_V1\ninfo\r\n"};
 for(unsigned i=0;i<sizeof bad/sizeof *bad;i++)reject(bad[i],strlen(bad[i]));
 reject(NULL,0);char oversized[129];memset(oversized,'x',sizeof oversized);reject(oversized,sizeof oversized);
 char nul[sizeof header+1];memcpy(nul,header,sizeof header);nul[sizeof header]='\n';reject(nul,sizeof nul);
 struct page_layout bad_struct={4,{0,1,2}};assert(!page_layout_valid(&bad_struct));bad_struct=(struct page_layout){2,{1,1}};assert(!page_layout_valid(&bad_struct));bad_struct=(struct page_layout){1,{3}};assert(!page_layout_valid(&bad_struct));assert(!page_layout_valid(NULL));
}
static void write_config(const char *path,const char *value){int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600);assert(fd>=0);size_t n=strlen(value);assert(write(fd,value,n)==(ssize_t)n);assert(close(fd)==0);assert(chmod(path,0600)==0);}
static void files(void){
 char parent[]="/tmp/page-layout-test-XXXXXX";assert(mkdtemp(parent));
 char dir[512],file[512],other[512];snprintf(dir,sizeof dir,"%s/launcher",parent);snprintf(file,sizeof file,"%s/launcher/page-layout.conf",parent);snprintf(other,sizeof other,"%s/other",parent);assert(mkdir(dir,0700)==0);
 struct page_layout p;unsigned uid=(unsigned)geteuid();
 assert(page_layout_read_test(parent,"launcher",uid,&p)==PAGE_LAYOUT_DEFAULT);assert(p.count==3&&p.ids[0]==PAGE_INFO&&p.ids[1]==PAGE_VPN&&p.ids[2]==PAGE_ESIM);
 write_config(file,"ZTE_LAUNCHER_PAGES_V1\nesim\ninfo\n");assert(page_layout_read_test(parent,"launcher",uid,&p)==PAGE_LAYOUT_CONFIG);assert(p.count==2&&p.ids[0]==PAGE_ESIM&&p.ids[1]==PAGE_INFO);
 assert(page_layout_read_test(parent,"launcher",uid+1,&p)==PAGE_LAYOUT_INVALID&&p.count==0);
 assert(chmod(file,0644)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(chmod(file,0600)==0);
 assert(link(file,other)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(unlink(other)==0);
 assert(unlink(file)==0);assert(symlink("missing",file)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(unlink(file)==0);
 assert(mkfifo(file,0600)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(unlink(file)==0);
 write_config(file,"ZTE_LAUNCHER_PAGES_V1\n");assert(page_layout_read_test(parent,"launcher",uid,&p)==PAGE_LAYOUT_CONFIG&&p.count==0);
 write_config(file,"bad");assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);
 assert(unlink(file)==0);assert(chmod(dir,0777)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(chmod(dir,0700)==0);
 assert(chmod(parent,0777)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(chmod(parent,0700)==0);
 assert(rmdir(dir)==0);assert(symlink(".",dir)==0);assert(!page_layout_read_test(parent,"launcher",uid,&p)&&p.count==0);assert(unlink(dir)==0);assert(rmdir(parent)==0);
}
int main(void){formats();files();puts("page layout: all16 ordered subsets, malformed input and filesystem safety PASS");return 0;}
