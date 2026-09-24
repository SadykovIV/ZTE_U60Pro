/* Exact-B31 extension of TUFormMain. Widgets, navigation and timer callbacks
 * run on the stock LVGL thread; the worker only exchanges plain snapshots. */
#define _GNU_SOURCE
#include "backend.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/auxv.h>
#include <fcntl.h>
#include <time.h>
#define F(a,r,...) ((r(*)(__VA_ARGS__))(uintptr_t)(a))
#define P(o,n) (*(void **)((char *)(o)+(n)))
#define HIDDEN 1
#define CLICKABLE 2
#define SCROLLABLE 16
#define CHAIN_HOR 256
#define BUBBLE 16384
static void *mainform,*pages[2],*dots[4],*titles[2];
static void *sys_title,*sys_value,*ram_title,*ram_value,*disk_title,*disk_value,*uptime_label;
static void *wifi_card,*wifi_title,*wifi_switch,*profile_heading,*profile_cards[3],*profile_labels[3],*profile_marks[3];
static void *previous,*next,*previous_label,*next_label,*notice,*confirm,*confirm_title,*confirm_name,*confirm_hint,*confirm_yes,*confirm_no;
static void *allocs[128],*timer;static int nalloc,current=1,offset,last_language=-1;
static struct snapshot shown;static unsigned last_generation=(unsigned)-1;
static int pending_wifi=-1;
static char selected_id[37],selected_name[257];
static int tr_ru(void){return *(int*)0x2288088==2;}
static const char *tr(const char *ru,const char *en){return tr_ru()?ru:en;}
static void pos(void *o,int x,int y){F(0x537450,void,void*,int,int)(o,x,y);}
static void size(void *o,int w,int h){F(0x5382b4,void,void*,int,int)(o,w,h);}
static void flag(void *o,unsigned f,int on){F(on?0x42e3c0:0x42e4f4,void,void*,unsigned)(P(o,8),f);}
static void color(void *o,int offset,int text){unsigned char *p=(void*)(uintptr_t)(0xe80214+offset);F(text?0x52f904:0x53793c,void,void*,int,int,int,int)(o,p[0],p[1],p[2],255);}
static void *objmem(size_t n){void *p=calloc(1,n);if(!p||nalloc>=128)_exit(70);allocs[nalloc++]=p;return p;}
static void text(void *o,const char *s){struct{const char *p;size_t n;size_t cap;size_t pad;}str={s,strlen(s),strlen(s),0};F(0x52fa80,void,void*,void*,int)(o,&str,0);}
static void *label(void *p,int x,int y,int w,int h,int font,const char *s){
 void *o=objmem(80);struct{const char *p;size_t n;size_t cap;size_t pad;}str={"",0,0,0};
 F(0x52fcc4,void,void*,void*,void*,int)(o,p,&str,0);pos(o,x,y);size(o,w,h);
 F(0x52fa04,void,void*,int)(o,font);F(0x52f73c,void,void*,int)(o,0);color(o,24,1);text(o,s);flag(o,CLICKABLE|SCROLLABLE,0);return o;
}
static void *panel(void *p,int x,int y,int w,int h,int card){
 void *o=objmem(48);F(0x533dcc,void,void*,void*,int)(o,p,-1);pos(o,x,y);size(o,w,h);flag(o,SCROLLABLE,0);flag(o,CHAIN_HOR|BUBBLE,1);
 if(card){color(o,12,0);F(0x537868,void,void*,int)(o,12);}return o;
}
static void update_dots(void *form,int page){
 if(form!=mainform||!dots[3]){F(0x4bc1d0,void,void*,int)(form,page);return;}
 current=page;
 for(int i=0;i<4;i++){int active=i==page-1;pos(dots[i],134+16*i,active?439:440);size(dots[i],active?8:6,active?8:6);F(0x537868,void,void*,int)(dots[i],active?4:3);color(dots[i],active?168:172,0);}
}
static void goto_page(int page,int anim){
 if(!mainform)return;if(page<1)page=1;if(page>4)page=4;
 *((unsigned char*)mainform+840)=page;update_dots(mainform,page);F(0x538080,void,void*,int,int)(P(mainform,88),(page-1)*320,anim);
 if(page>=3)backend_refresh();
}
static void scroll_release(void *form){
 if(form!=mainform){F(0x4bd9ec,void,void*)(form);return;}
 void *indev=F(0x42a8c0,void*,void)();if(!indev)return;
 *(uint32_t*)((char*)indev+36)=0;
 int x=(int16_t)F(0x5384a0,int,void*)(P(form,88));int old=*((unsigned char*)form+840);int delta=x-(old-1)*320;
 int target=old+(delta>24)-(delta< -24);goto_page(target,1);
}
static void render(void);
/* The same SwitchButton used by TUSettingSwitchButton in the Wi-Fi menu. */
static void wifi_changed(int enabled,void *unused){
 (void)unused;
 if(shown.valid&&!shown.busy&&backend_action(enabled,NULL))pending_wifi=!!enabled;
 backend_snapshot(&shown);render();
}
static void clicked(void *event){
 int id=(int)(intptr_t)F(0x429128,void*,void*)(event);
 if(shown.busy)return;
 if(id>=10&&id<13){int i=offset+id-10;if(i<shown.count&&!shown.profiles[i].active){snprintf(selected_id,sizeof selected_id,"%s",shown.profiles[i].id);snprintf(selected_name,sizeof selected_name,"%s",shown.profiles[i].name);}}
 else if(id==20){offset-=3;if(offset<0)offset=0;}
 else if(id==21&&offset+3<shown.count)offset+=3;
 else if(id==30&&selected_id[0]){if(backend_action(-1,selected_id))selected_id[0]=0;}
 else if(id==31)selected_id[0]=0;
 backend_snapshot(&shown);render();
}
static void *button(void *parent,int x,int y,int w,int h,int id,void **caption){
 void *o=panel(parent,x,y,w,h,1);flag(o,CLICKABLE,1);
 F(0x4291a0,void*,void*,void(*)(void*),int,void*)(P(o,8),clicked,7,(void*)(intptr_t)id);
 *caption=label(o,12,10,w-24,h-14,19,"");return o;
}
static void gib(char *out,size_t n,uint64_t b){unsigned long long tenth=(b*10+(1ULL<<29))>>30;snprintf(out,n,tr("%llu,%llu ГБ","%llu.%llu GB"),tenth/10,tenth%10);}
static void render(void){
 char line[160],a[40],b[40];
 text(titles[0],tr("О модеме","About modem"));text(sys_title,tr("Система","System"));text(sys_value,"OpenWrt 23.05.4 / B31");
 text(ram_title,tr("Оперативная память","Memory"));text(disk_title,tr("Память приложений","Application storage"));
 if(shown.ram_total){snprintf(line,sizeof line,tr("Свободно %llu из %llu МБ","%llu of %llu MB available"),(unsigned long long)(shown.ram_free>>20),(unsigned long long)(shown.ram_total>>20));text(ram_value,line);}
 if(shown.disk_total){gib(a,sizeof a,shown.disk_free);gib(b,sizeof b,shown.disk_total);snprintf(line,sizeof line,tr("Свободно %s из %s","%s of %s available"),a,b);text(disk_value,line);}
 snprintf(line,sizeof line,tr("Время работы: %llu д %llu ч","Uptime: %llu d %llu h"),(unsigned long long)(shown.uptime/86400),(unsigned long long)(shown.uptime/3600%24));text(uptime_label,line);
 text(wifi_title,tr("WiFi с VPN","WiFi with VPN"));if(!shown.busy)pending_wifi=-1;
 F(0x534c14,void,void*,int)(wifi_switch,shown.busy&&pending_wifi>=0?pending_wifi:shown.enabled);
 flag(wifi_switch,CLICKABLE,shown.valid&&!shown.busy);
 F(shown.busy||!shown.valid?0x42e660:0x42e67c,void,void*,unsigned)(P(wifi_switch,8),128);
 text(profile_heading,tr("Профиль VPN","VPN profile"));
 if(offset>=shown.count)offset=0;
 for(int i=0;i<3;i++){int idx=offset+i;flag(profile_cards[i],HIDDEN,idx>=shown.count);if(idx<shown.count){text(profile_labels[i],shown.profiles[idx].name);flag(profile_marks[i],HIDDEN,!shown.profiles[idx].active);}}
 flag(previous,HIDDEN,shown.count<=3);flag(next,HIDDEN,shown.count<=3);text(previous_label,tr("Назад","Previous"));text(next_label,tr("Далее","Next"));
 text(notice,shown.busy?tr("Применение...","Applying..."):shown.error?tr("Ошибка. Откройте агент","Error. Open the agent"):!shown.valid?tr("Получение данных...","Loading..."):!shown.count?tr("Добавьте профиль в агенте","Import a profile in the agent"):shown.enabled?(shown.network_ok&&shown.running?tr("VPN работает","VPN is running"):tr("Проверьте VPN в агенте","Check VPN in the agent")):tr("WiFi с VPN выключен","WiFi with VPN is off"));
 flag(confirm,HIDDEN,!selected_id[0]);text(confirm_title,tr("Подключить профиль?","Connect this profile?"));text(confirm_name,selected_name);text(confirm_hint,tr("VPN переподключится","VPN will reconnect"));text(confirm_yes,tr("Подключить","Connect"));text(confirm_no,tr("Отмена","Cancel"));
 last_generation=shown.generation;last_language=tr_ru();
}
static void tick(void *unused){
 (void)unused;if(!mainform||*(unsigned char*)0x2287598)return;
 int fd=open("/tmp/zte-launcher/page",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd>=0){char p=0;ssize_t n=read(fd,&p,1);close(fd);unlink("/tmp/zte-launcher/page");if(n==1&&p>='1'&&p<='4')goto_page(p-'0',0);}
 backend_snapshot(&shown);if(shown.generation!=last_generation||tr_ru()!=last_language)render();
 static unsigned ticks;if(++ticks%10==0&&current>=3&& !*(unsigned char*)0x2287598&&F(0x538658,int,void*)(mainform))backend_refresh();
}
static void destroy(void *form){
 if(form==mainform){
  if(timer){F(0x481540,void,void*)(timer);timer=NULL;}
  mainform=NULL;memset(dots,0,sizeof dots);
  for(int i=nalloc-1;i>=0;i--){void *o=allocs[i];F((uintptr_t)P(P(o,0),0),void,void*)(o);free(o);}nalloc=0;
 }
 F(0x4b7ffc,void,void*)(form);
}
static void create(void *form){
 F(0x4bd900,void,void*)(form);if(mainform==form)return;
 mainform=form;current=1;offset=0;selected_id[0]=0;
 void *parent=P(form,88),*card;
 pages[0]=panel(parent,640,0,320,432,0);pages[1]=panel(parent,960,0,320,432,0);
 titles[0]=label(pages[0],16,12,288,34,24,"");label(pages[0],16,52,288,26,18,"ZTE U60 Pro / MU5250");
 card=panel(pages[0],14,88,292,72,1);sys_title=label(card,12,8,268,22,16,"");sys_value=label(card,12,35,268,28,20,"");
 card=panel(pages[0],14,172,292,72,1);ram_title=label(card,12,8,268,22,16,"");ram_value=label(card,12,35,268,28,18,"");
 card=panel(pages[0],14,256,292,72,1);disk_title=label(card,12,8,268,22,16,"");disk_value=label(card,12,35,268,28,18,"");
 uptime_label=label(pages[0],16,350,288,28,18,"");label(pages[0],16,390,288,26,16,"192.168.0.1:8080");
 titles[1]=label(pages[1],16,12,288,34,24,"VPN");label(pages[1],16,52,288,26,18,"ZTE-VPN");
 wifi_card=panel(pages[1],14,88,292,62,1);flag(wifi_card,CLICKABLE,0);
 wifi_title=label(wifi_card,12,20,196,30,19,"");
 wifi_switch=objmem(56);F(0x534a94,void,void*,void*)(wifi_switch,wifi_card);
 size(wifi_switch,45,24);pos(wifi_switch,231,19);flag(wifi_switch,SCROLLABLE,0);flag(wifi_switch,CHAIN_HOR|BUBBLE,1);
 F(0x534c08,void,void*,void(*)(int,void*),void*)(wifi_switch,wifi_changed,NULL);
 profile_heading=label(pages[1],16,163,288,24,16,"");
 for(int i=0;i<3;i++){profile_cards[i]=button(pages[1],14,194+54*i,292,48,10+i,&profile_labels[i]);pos(profile_labels[i],18,7);size(profile_labels[i],262,39);F(0x52fa04,void,void*,int)(profile_labels[i],17);F(0x52f73c,void,void*,int)(profile_labels[i],1);profile_marks[i]=panel(profile_cards[i],0,8,5,32,0);color(profile_marks[i],100,0);}
 previous=button(pages[1],14,360,140,40,20,&previous_label);next=button(pages[1],166,360,140,40,21,&next_label);
 notice=label(pages[1],16,405,288,25,16,"");
 confirm=panel(pages[1],8,156,304,247,0);confirm_title=label(confirm,8,14,288,32,22,"");confirm_name=label(confirm,8,57,288,70,20,"");confirm_hint=label(confirm,8,132,288,28,17,"");
 button(confirm,6,186,146,48,30,&confirm_yes);button(confirm,158,186,140,48,31,&confirm_no);
 dots[0]=P(form,848);dots[1]=P(form,856);dots[2]=label(form,0,0,8,8,12,"");dots[3]=label(form,0,0,8,8,12,"");update_dots(form,1);
 backend_start();backend_snapshot(&shown);render();
 timer=F(0x481428,void*,void(*)(void*),unsigned,void*)(tick,500,NULL);
 int fd=open("/tmp/zte-launcher/ready",O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);if(fd>=0){dprintf(fd,"%ld\n",(long)getpid());close(fd);}
 fprintf(stderr,"launcher: four native pages created\n");
}
static int hook(uintptr_t addr,uintptr_t before,void *after){
 if(*(uintptr_t*)addr!=before)return -1;uintptr_t page=addr&~(uintptr_t)4095;
 if(mprotect((void*)page,4096,PROT_READ|PROT_WRITE))return -1;*(void**)addr=after;return mprotect((void*)page,4096,PROT_READ);
}
__attribute__((constructor)) static void init(void){
 if(!getenv("ZTE_LAUNCHER"))return;unsetenv("LD_PRELOAD");unsetenv("ZTE_LAUNCHER");
 if(getauxval(AT_PHDR)!=0x400040 || getauxval(AT_ENTRY)!=0x421dc4)return;
 if(*(uintptr_t*)0xe72aa0!=0x4bd900||*(uintptr_t*)0xe7d968!=0x4bd9ec||*(uintptr_t*)0xe7b448!=0x4bc1d0||*(uintptr_t*)0xe72a08!=0x4b7ffc||*(uintptr_t*)0xe79c30!=0x4b7ffc)return;
 if(hook(0xe72aa0,0x4bd900,create)||hook(0xe7d968,0x4bd9ec,scroll_release)||hook(0xe7b448,0x4bc1d0,update_dots)||hook(0xe72a08,0x4b7ffc,destroy)||hook(0xe79c30,0x4b7ffc,destroy))_exit(71);
 fprintf(stderr,"launcher: B31 hooks installed\n");
}
