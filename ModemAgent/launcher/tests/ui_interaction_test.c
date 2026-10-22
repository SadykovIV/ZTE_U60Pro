/* Real launcher callbacks with in-memory widgets and synthetic backend data.
 * No stock executable, profile files, modem, service or network is accessed. */
#include <stdint.h>
#include <assert.h>
static uintptr_t test_address(uintptr_t);
#include LAUNCHER_TEST_SOURCE

struct widget {void *object,*parent;int x,y,width,height,font,mode,event,scroll_y,scroll_calls,scroll_dir,scrollbar;unsigned flags;char caption[2048];};
static struct widget widgets[600];static int widget_count,language=2,modal;
static unsigned char palette[256],input_device[64];
static unsigned direction;static void *scroll_object;static int carousel_x;
static struct snapshot fixture;static struct esim_snapshot sim_fixture;
static unsigned actions,refreshes,sim_refreshes,assertions;
static char action_id[37];
#define CHECK(x) do{assertions++;assert(x);}while(0)
static struct widget *widget(void *object){
 for(int i=0;i<widget_count;i++)if(widgets[i].object==object)return &widgets[i];
 assert(widget_count<600);struct widget *w=&widgets[widget_count++];w->object=object;return w;
}
static void construct(void *object,void *parent){P(object,8)=object;widget(object)->parent=parent;}
static void panel_constructor(void *o,void *p,int unused){(void)unused;construct(o,p);}
static void label_constructor(void *o,void *p,void *str,int unused){(void)str;(void)unused;construct(o,p);}
static void switch_constructor(void *o,void *p){construct(o,p);}
static void set_position(void *o,int x,int y){widget(o)->x=x;widget(o)->y=y;}
static void set_size(void *o,int w,int h){widget(o)->width=w;widget(o)->height=h;}
static void add_flags(void *o,unsigned f){widget(o)->flags|=f;}
static void remove_flags(void *o,unsigned f){widget(o)->flags&=~f;}
static void set_color(void *o,int r,int g,int b,int a){(void)o;(void)r;(void)g;(void)b;(void)a;}
static void set_integer(void *o,int value){(void)o;(void)value;}
static void set_unsigned(void *o,unsigned value){(void)o;(void)value;}
static void set_font(void *o,int value){widget(o)->font=value;}
static void set_mode(void *o,int value){widget(o)->mode=value;}
static void set_scroll_dir(void *o,unsigned value){widget(o)->scroll_dir=(int)value;}
static void set_scrollbar(void *o,unsigned value){widget(o)->scrollbar=(int)value;}
static void set_text(void *o,void *raw,int unused){(void)unused;const char *s=*(const char**)raw;assert(strlen(s)<sizeof widgets[0].caption);strcpy(widget(o)->caption,s);}
static void *register_event(void *o,void(*callback)(void*),int code,void *data){assert(callback==clicked&&code==7);widget(o)->event=(int)(intptr_t)data;return NULL;}
static void *event_data(void *event){return event;}
static void switch_callback(void *o,void(*callback)(int,void*),void *data){(void)o;(void)data;assert(callback==wifi_changed);}
static void scroll_y(void *o,int y,int animate){assert(!animate);widget(o)->scroll_y=y;widget(o)->scroll_calls++;}
static void scroll_x(void *o,int x,int animate){(void)o;(void)animate;carousel_x=x;}
static int get_x(void *o){(void)o;return carousel_x;}
static void original(void *o){(void)o;}
static void original_dots(void *o,int page){(void)o;(void)page;}
static void *new_timer(void(*callback)(void*),unsigned interval,void *data){(void)data;assert(callback==tick&&interval==500);return NULL;}
static int visible(void *o){(void)o;return 1;}
static void *indev(void){return input_device;}
static unsigned indev_direction(void *o){assert(o==input_device);return direction;}
static void *indev_scroll(void *o){assert(o==input_device);return scroll_object;}
static uintptr_t test_address(uintptr_t address){
 switch(address){
 case 0x537450:return (uintptr_t)set_position;case 0x5382b4:return (uintptr_t)set_size;
 case 0x42e3c0:return (uintptr_t)add_flags;case 0x42e4f4:return (uintptr_t)remove_flags;
 case 0x42e660:case 0x42e67c:return (uintptr_t)set_unsigned;
 case 0x52f904:case 0x53793c:return (uintptr_t)set_color;
 case 0x52fa80:return (uintptr_t)set_text;case 0x52fcc4:return (uintptr_t)label_constructor;
 case 0x52fa04:return (uintptr_t)set_font;case 0x52f73c:return (uintptr_t)set_mode;
 case 0x533dcc:return (uintptr_t)panel_constructor;case 0x537868:case 0x534c14:return (uintptr_t)set_integer;
 case 0x4291a0:return (uintptr_t)register_event;case 0x429128:return (uintptr_t)event_data;
 case 0x534a94:return (uintptr_t)switch_constructor;case 0x534c08:return (uintptr_t)switch_callback;
 case 0x5380bc:return (uintptr_t)scroll_y;case 0x538080:return (uintptr_t)scroll_x;
 case 0x5384a0:return (uintptr_t)get_x;case 0x538658:return (uintptr_t)visible;
 case 0x433198:return (uintptr_t)set_scroll_dir;case 0x433134:return (uintptr_t)set_scrollbar;
 case 0x4bd900:case 0x4bd9ec:case 0x4b7ffc:case 0x481540:return (uintptr_t)original;
 case 0x4bc1d0:return (uintptr_t)original_dots;case 0x481428:return (uintptr_t)new_timer;
 case 0x42a8c0:return (uintptr_t)indev;case 0x42ace8:return (uintptr_t)indev_direction;case 0x42ad14:return (uintptr_t)indev_scroll;
 default:fprintf(stderr,"Unexpected ABI call: %lx\n",(unsigned long)address);abort();
 }
}
void backend_start(void){}
void backend_refresh(void){refreshes++;}
void backend_snapshot(struct snapshot *out){*out=fixture;}
int backend_action(int enable,const char *id){CHECK(enable==-1&&id);actions++;snprintf(action_id,sizeof action_id,"%s",id);return 1;}
void esim_start(void){}
void esim_refresh(void){sim_refreshes++;}
void esim_snapshot(struct esim_snapshot *out){*out=sim_fixture;}
int esim_enable(const char *iccid,unsigned generation){(void)iccid;(void)generation;assert(0);return 0;}
int page_layout_read(struct page_layout *out){*out=(struct page_layout){3,{PAGE_INFO,PAGE_VPN,PAGE_ESIM}};return PAGE_LAYOUT_DEFAULT;}
static void click(int event){clicked((void*)(intptr_t)event);}
static void poll_render(void){backend_snapshot(&shown);render();}
static void synthetic_catalog(int count){
 memset(&fixture,0,sizeof fixture);fixture.valid=fixture.enabled=fixture.running=fixture.network_ok=1;fixture.count=count;
 strcpy(fixture.ssid,"Fixture [SSID]");info_layout_default(&fixture.layout);
 for(int i=0;i<count;i++){snprintf(fixture.profiles[i].id,37,"%08x-89ab-cdef-0123-456789abcdef",i);snprintf(fixture.profiles[i].name,257,"🇩🇪 Тестовый профиль %d 🚀",i);}
}
int main(void){
 if(0)init(); /* Compile constructor body; do not hook or inspect any process. */
 static struct launcher_abi test_abi;test_abi.language=(uintptr_t)&language;test_abi.modal=(uintptr_t)&modal;test_abi.palette=(uintptr_t)palette;abi=&test_abi;
 void *form=calloc(1,900),*parent=calloc(1,48),*dot0=calloc(1,80),*dot1=calloc(1,80);assert(form&&parent&&dot0&&dot1);
 construct(parent,NULL);construct(dot0,form);construct(dot1,form);P(form,88)=parent;P(form,848)=dot0;P(form,856)=dot1;
 synthetic_catalog(MAX_PROFILES);create(form);
 CHECK(nalloc<160+3*VPN_LIST_ROWS&&widget_count<600);
 CHECK(widget(notice)->parent==pages[1]&&widget(notice)->y==12&&widget(notice)->height==28);
 CHECK(widget(wifi_switch)->parent==pages[1]&&widget(wifi_switch)->y==15);
 CHECK(widget(notice)->x+widget(notice)->width<widget(wifi_switch)->x);
 CHECK(widget(status_hint)->flags&HIDDEN);
 CHECK(widget(confirm)->y>=VPN_VIEWPORT_Y&&widget(confirm)->y+widget(confirm)->height<=422);
 CHECK(widget(profile_scroll)->y==VPN_VIEWPORT_Y&&widget(profile_scroll)->height==VPN_VIEWPORT_HEIGHT);
 CHECK(widget(profile_scroll)->scroll_dir==12&&(widget(profile_scroll)->flags&SCROLLABLE));
 CHECK(!(widget(profile_scroll)->flags&(CHAIN_VER|BUBBLE))&&(widget(profile_scroll)->flags&CHAIN_HOR));
 for(int i=0;i<widget_count;i++)CHECK(widgets[i].event!=32); /* No subscription refresh touch target. */
 unsigned before=actions;
 for(int base=0;base<MAX_PROFILES;base+=VPN_LIST_ROWS){
  CHECK(offset==base);
  for(int row=0;row<VPN_LIST_ROWS&&base+row<MAX_PROFILES;row++){
   CHECK(widget(profile_cards[row])->event==VPN_PROFILE_EVENT_BASE+row);
   CHECK(widget(profile_cards[row])->parent==profile_scroll&&widget(profile_labels[row])->mode==1);
   click(widget(profile_cards[row])->event);
   CHECK(!strcmp(selected_id,fixture.profiles[base+row].id));CHECK(actions==before);
   CHECK(strstr(widget(confirm_name)->caption,"[DE]")&&strstr(widget(confirm_name)->caption,"[fast]"));
   click(30);before++;
   CHECK(actions==before&&!strcmp(action_id,fixture.profiles[base+row].id)&&!selected_id[0]);
  }
  if(base+VPN_LIST_ROWS<MAX_PROFILES)click(21);
 }
 CHECK(widget(profiles_below)->flags&HIDDEN);
 /* Going upward lands at the bottom of the previous block. */
 click(20);CHECK(offset==MAX_PROFILES-2*VPN_LIST_ROWS&&widget(profile_scroll)->scroll_y>0);
 widget(profile_scroll)->scroll_y=333;int calls=widget(profile_scroll)->scroll_calls;
 fixture.generation++;fixture.running=0;fixture.profiles[0].active=1;strcpy(fixture.profiles[0].name,"Renamed fixture");poll_render();
 CHECK(widget(profile_scroll)->scroll_calls==calls&&widget(profile_scroll)->scroll_y==333);
 language=0;render();CHECK(widget(profile_scroll)->scroll_calls==calls&&widget(profile_scroll)->scroll_y==333);
 /* Composition changes reset once, subsequent polling remains stable. */
 fixture.count--;poll_render();CHECK(offset==0&&widget(profile_scroll)->scroll_y==0&&widget(profile_scroll)->scroll_calls==calls+1);
 calls=widget(profile_scroll)->scroll_calls;poll_render();CHECK(widget(profile_scroll)->scroll_calls==calls);
 fixture.profiles[0].ikev2=1;fixture.ikev2_state=IKEV2_WAITING;fixture.enabled=0;poll_render();
 CHECK(!strcmp(widget(notice)->caption,"VPN is off"));CHECK(vpn_can_activate(&shown,0));
 fixture.enabled=1;poll_render();CHECK(strstr(widget(notice)->caption,"Approve push")&&!vpn_can_activate(&shown,0));
 fixture.ikev2_state=IKEV2_CONNECTED;poll_render();CHECK(strstr(widget(notice)->caption,"IKEv2 connected")&&!vpn_can_activate(&shown,0));
 CHECK(!strchr(widget(notice)->caption,'\n')&&(widget(status_hint)->flags&HIDDEN));
 calls=widget(profile_scroll)->scroll_calls;widget(profile_scroll)->scroll_y=123;
 fixture.error=1;strcpy(fixture.error_code,"VPN_SUBSCRIPTION_FILE_REFERENCE");poll_render();
 CHECK(!strcmp(widget(notice)->caption,"VPN error")&&!strcmp(widget(status_hint)->caption,"More details in the agent"));
 CHECK(!(widget(status_hint)->flags&HIDDEN)&&widget(profile_scroll)->y==VPN_VIEWPORT_Y+VPN_STATUS_HINT_HEIGHT);
 CHECK(widget(profile_scroll)->height==VPN_VIEWPORT_HEIGHT-VPN_STATUS_HINT_HEIGHT&&widget(profile_scroll)->y+widget(profile_scroll)->height==422);
 CHECK(widget(profile_scroll)->scroll_calls==calls&&widget(profile_scroll)->scroll_y==123);
 fixture.error=0;poll_render();CHECK(widget(profile_scroll)->y==VPN_VIEWPORT_Y&&widget(profile_scroll)->height==VPN_VIEWPORT_HEIGHT);
 CHECK(widget(profile_scroll)->scroll_calls==calls&&widget(profile_scroll)->scroll_y==123);
 fixture.enabled=0;poll_render();click(VPN_PROFILE_EVENT_BASE);CHECK(selected_id[0]);
 /* Removed selection cannot be confirmed; duplicate fallback display names
  * continue to use original distinct UUIDs. */
 fixture.count=0;poll_render();CHECK(!selected_id[0]&&(widget(confirm)->flags&HIDDEN));before=actions;click(30);CHECK(actions==before);
 synthetic_catalog(2);poll_render();strcpy(fixture.profiles[0].name,"😀");strcpy(fixture.profiles[1].name,"😃");poll_render();
 click(VPN_PROFILE_EVENT_BASE);CHECK(!strcmp(selected_id,fixture.profiles[0].id));click(31);
 click(VPN_PROFILE_EVENT_BASE+1);CHECK(!strcmp(selected_id,fixture.profiles[1].id));click(31);
 before=actions;fixture.busy=1;poll_render();click(VPN_PROFILE_EVENT_BASE);CHECK(actions==before&&!selected_id[0]);fixture.busy=0;poll_render();
 /* A vertical release does not change page/throw; a horizontal one chains. */
 current=4;*((unsigned char*)form+840)=4;carousel_x=3*320;direction=8;scroll_object=P(profile_scroll,8);*(uint32_t*)(input_device+36)=123;
 scroll_release(form);CHECK(current==4&&*(uint32_t*)(input_device+36)==123);
 direction=0;scroll_object=P(profile_scroll,8);scroll_release(form);CHECK(current==4&&*(uint32_t*)(input_device+36)==123);
 scroll_object=P(parent,8);carousel_x=4*320;scroll_release(form);CHECK(current==5&&*(uint32_t*)(input_device+36)==0);
 for(int i=0;i<nalloc;i++)free(allocs[i]);free(parent);free(dot0);free(dot1);free(form);
 printf("Launcher UI callbacks: %u checks PASS; 1024 UUID touch selections, polling, layout, Unicode, disabled states and gestures\n",assertions);
 return 0;
}
