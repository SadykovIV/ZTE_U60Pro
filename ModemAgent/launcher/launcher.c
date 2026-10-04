/* Exact-B31 extension of TUFormMain. Widgets, navigation and timer callbacks
 * run on the stock LVGL thread; the worker only exchanges plain snapshots. */
#define _GNU_SOURCE
#include "backend.h"
#include "vpn-model.h"
#include "esim-backend.h"
#include "page-layout.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef LAUNCHER_FORMAT_TEST
#include <unistd.h>
#include <sys/mman.h>
#include <sys/auxv.h>
#include <fcntl.h>
#include <time.h>
#endif

struct info_text { char values[INFO_ROWS][192],carrier_title[64];const char *status; };
static int format_wifi_ssid(const struct snapshot *s,int ru,char *out,size_t size){
 if(!s->valid){snprintf(out,size,"%s",ru?"Имя сети недоступно":"SSID unavailable");return 0;}
 if(s->ssid_2g[0]&&s->ssid_5g[0]&&strcmp(s->ssid_2g,s->ssid_5g)){
  snprintf(out,size,"2.4G: %s\n5G: %s",s->ssid_2g,s->ssid_5g);return 1;
 }
 const char *name=s->ssid[0]?s->ssid:s->ssid_5g[0]?s->ssid_5g:s->ssid_2g;
 snprintf(out,size,"%s",name[0]?name:(ru?"Имя сети недоступно":"SSID unavailable"));return 0;
}
/* Pure formatting is shared with the host tests; stock widget calls stay on the
 * LVGL thread. A valid zero is distinct from an unavailable measurement. */
static void temperature_text(char *out,size_t size,int tenths,int ru){
 unsigned magnitude=(unsigned)(tenths<0?-(int64_t)tenths:tenths);
 snprintf(out,size,"%s%u%s%u °C",tenths<0?"−":"",magnitude/10,ru?",":".",magnitude%10);
}
static void carrier_lines(char *out,size_t size,const char *bands,unsigned columns,unsigned rows){
 /* Bounded lines fit the selected card width. Truncation remains visible, while
  * the heading always retains the number of active component carriers. */
 size_t used=0,line_start=0;int line=0;
 const char *p=bands;
 while(*p&&used+5<size){
  const char *end=strstr(p," + ");size_t n=end?(size_t)(end-p):strlen(p);
  if(n>12)break; /* The backend accepts only band labels, never arbitrary text. */
  size_t separator=used>line_start?3:0;
  if(used-line_start+separator+n>columns){
   if((unsigned)line+1>=rows){if(used-line_start>columns-3)used=line_start+columns-3;if(used+4<size){memcpy(out+used,"...",3);used+=3;}break;}
   out[used++]='\n';line_start=used;line++;separator=0;
  }
  if(used+separator+n+1>=size)break;
  if(separator){memcpy(out+used," + ",3);used+=3;}
  memcpy(out+used,p,n);used+=n;
  if(!end)break;p=end+3;
 }
 out[used]=0;
}
static void capacity_text(char *out,size_t size,uint64_t used,uint64_t total,int ru,int tiles){
 const double mib=1048576.0,gib=1073741824.0;
 if(total<1073741824ULL)snprintf(out,size,"%.0f / %.0f%s%s",used/mib,total/mib,tiles?"\n":" ",ru?"МиБ":"MiB");
 else snprintf(out,size,"%.1f / %.1f%s%s",used/gib,total/gib,tiles?"\n":" ",ru?"ГиБ":"GiB");
 if(ru)for(char *p=out;*p;p++)if(*p=='.')*p=',';
}
static void quality_text(char *out,size_t size,int tenths,int nr,int ru,int tiles){
 unsigned magnitude=(unsigned)(tenths<0?-(int64_t)tenths:tenths);
 snprintf(out,size,"%s%u%s%u dB%s%s",tenths<0?"−":"",magnitude/10,ru?",":".",magnitude%10,tiles?"\n":" · ",nr?"NR":"LTE");
}
static const char *battery_status_text(int status,int ru){
 static const char *const russian[]={"Статус —","Заряжается","Разряжается","Не заряжается","Заряжена"};
 static const char *const english[]={"Status —","Charging","Discharging","Not charging","Full"};
 if(status<BATTERY_UNKNOWN||status>BATTERY_FULL)status=BATTERY_UNKNOWN;
 return ru?russian[status]:english[status];
}
static const char *info_title(unsigned id,int ru,int tiles,const struct info_text *text){
 static const char *const russian[INFO_ROWS]={"Загрузка процессора","Уровень сигнала","Тип соединения","Несущие","Температура процессора","Температура модема","Оперативная память","Хранилище /data","Время работы","Батарея","Качество сигнала · RSRQ","Сигнал / шум · SINR"};
 static const char *const english[INFO_ROWS]={"CPU usage","Signal strength","Connection type","Carriers","CPU temperature","Modem temperature","Memory usage","Storage /data","Uptime","Battery","Signal quality · RSRQ","Signal / noise · SINR"};
 static const char *const compact_ru[INFO_ROWS]={"CPU","Сигнал","Соединение","Несущие","Темп. CPU","Темп. модема","Память","Хранилище","Время работы","Батарея","RSRQ","SINR"};
 static const char *const compact_en[INFO_ROWS]={"CPU","Signal","Connection","Carriers","CPU temp.","Modem temp.","Memory","Storage","Uptime","Battery","RSRQ","SINR"};
 return id==INFO_CARRIERS?text->carrier_title:tiles?(ru?compact_ru[id]:compact_en[id]):ru?russian[id]:english[id];
}
static void format_info(const struct snapshot *s,int ru,struct info_text *out){
 static const unsigned bits[INFO_ROWS]={TELEMETRY_CPU,TELEMETRY_SIGNAL,TELEMETRY_RAT,TELEMETRY_CARRIERS,TELEMETRY_CPU_TEMP,TELEMETRY_MODEM_TEMP,TELEMETRY_MEMORY,TELEMETRY_STORAGE,TELEMETRY_UPTIME,TELEMETRY_BATTERY,TELEMETRY_RSRQ,TELEMETRY_SINR};
 int tiles=info_layout_valid(&s->layout)&&s->layout.style==INFO_STYLE_TILES;
 unsigned valid=s->telemetry.valid,stale=s->telemetry.stale&valid;
 memset(out,0,sizeof *out);
 for(int i=0;i<INFO_ROWS;i++)snprintf(out->values[i],sizeof out->values[i],"—");
 snprintf(out->carrier_title,sizeof out->carrier_title,"%s",ru?"Несущие":"Carriers");
 if(valid&TELEMETRY_CPU)snprintf(out->values[INFO_CPU],sizeof out->values[INFO_CPU],"%d%%",s->telemetry.cpu_percent);
 if(valid&TELEMETRY_SIGNAL){
  if(!strcmp(s->telemetry.signal_metric,"BARS"))snprintf(out->values[INFO_SIGNAL],sizeof out->values[INFO_SIGNAL],"%d/5",s->telemetry.signal_bars);
  else snprintf(out->values[INFO_SIGNAL],sizeof out->values[INFO_SIGNAL],tiles?"%d dBm\n%s":"%d dBm (%s)",s->telemetry.signal_dbm,s->telemetry.signal_metric);
 }
 if(valid&TELEMETRY_RAT)snprintf(out->values[INFO_NETWORK],sizeof out->values[INFO_NETWORK],"%s",s->telemetry.network_type);
 if(valid&TELEMETRY_CARRIERS){
  snprintf(out->carrier_title,sizeof out->carrier_title,"%s: %s%u%s",ru?"Несущие":"Carriers",s->telemetry.carriers_complete?"":"≥",s->telemetry.carrier_count,stale&TELEMETRY_CARRIERS?" *":"");
  carrier_lines(out->values[INFO_CARRIERS],sizeof out->values[INFO_CARRIERS],s->telemetry.carrier_bands,tiles?14:27,tiles?4:2);
  if(!out->values[INFO_CARRIERS][0])snprintf(out->values[INFO_CARRIERS],sizeof out->values[INFO_CARRIERS],"%s",s->telemetry.carrier_count?(ru?"Диапазоны недоступны":"Bands unavailable"):(ru?"Нет активных":"None active"));
 }
 if(valid&TELEMETRY_CPU_TEMP)temperature_text(out->values[INFO_CPU_TEMP],sizeof out->values[INFO_CPU_TEMP],s->telemetry.cpu_temp_tenths,ru);
 if(valid&TELEMETRY_MODEM_TEMP)temperature_text(out->values[INFO_MODEM_TEMP],sizeof out->values[INFO_MODEM_TEMP],s->telemetry.modem_temp_tenths,ru);
 if(valid&TELEMETRY_MEMORY)capacity_text(out->values[INFO_MEMORY],sizeof out->values[INFO_MEMORY],s->telemetry.memory_used,s->telemetry.memory_total,ru,tiles);
 if(valid&TELEMETRY_STORAGE)capacity_text(out->values[INFO_STORAGE],sizeof out->values[INFO_STORAGE],s->telemetry.storage_used,s->telemetry.storage_total,ru,tiles);
 if(valid&TELEMETRY_UPTIME){
  uint64_t seconds=s->telemetry.uptime;unsigned hours=(unsigned)(seconds/3600%24),minutes=(unsigned)(seconds/60%60),remainder=(unsigned)(seconds%60);
  if(seconds>=86400)snprintf(out->values[INFO_UPTIME],sizeof out->values[INFO_UPTIME],"%llu %s%s%02u:%02u:%02u",(unsigned long long)(seconds/86400),ru?"д":"d",tiles?"\n":" ",hours,minutes,remainder);
  else snprintf(out->values[INFO_UPTIME],sizeof out->values[INFO_UPTIME],"%02u:%02u:%02u",hours,minutes,remainder);
 }
 if(valid&TELEMETRY_BATTERY)snprintf(out->values[INFO_BATTERY],sizeof out->values[INFO_BATTERY],"%d%%%s%s",s->telemetry.battery_percent,tiles?"\n":" · ",battery_status_text(s->telemetry.battery_status,ru));
 if(valid&TELEMETRY_RSRQ)quality_text(out->values[INFO_RSRQ],sizeof out->values[INFO_RSRQ],s->telemetry.rsrq_tenths,s->telemetry.rsrq_is_nr,ru,tiles);
 if(valid&TELEMETRY_SINR)quality_text(out->values[INFO_SINR],sizeof out->values[INFO_SINR],s->telemetry.sinr_tenths,s->telemetry.sinr_is_nr,ru,tiles);
 for(int i=0;i<INFO_ROWS;i++)if(i!=INFO_CARRIERS&&(stale&bits[i]))strncat(out->values[i]," *",sizeof out->values[i]-strlen(out->values[i])-1);
 unsigned all=info_layout_selected(&s->layout);valid&=all;stale&=all;
 out->status=stale?(valid==all?(ru?"* данные устарели":"* stale data"):(ru?"— нет данных; * устарели":"— unavailable; * stale")):(valid==all?(ru?"Текущие показатели":"Current measurements"):(ru?"— нет данных":"— unavailable"));
}

#ifndef LAUNCHER_FORMAT_TEST
#define F(a,r,...) ((r(*)(__VA_ARGS__))(uintptr_t)(a))
#define P(o,n) (*(void **)((char *)(o)+(n)))
#define HIDDEN 1
#define CLICKABLE 2
#define SCROLLABLE 16
#define CHAIN_HOR 256
#define CHAIN_VER 512
#define BUBBLE 16384
static struct page_layout page_order={3,{PAGE_INFO,PAGE_VPN,PAGE_ESIM}};
static int page_count=5;
static int page_kind(int page){return page>=3&&page<=page_count?page_order.ids[page-3]:-1;}
static void *mainform,*pages[3],*dots[5],*titles[3];
static void *info_cards[INFO_MAX_SELECTED],*info_titles[INFO_MAX_SELECTED],*info_values[INFO_MAX_SELECTED],*info_status,*info_scroll;
static struct info_layout rendered_layout;static int has_rendered_layout;
static void *wifi_card,*wifi_title,*wifi_ssid,*wifi_switch,*profile_heading,*profile_cards[3],*profile_labels[3],*profile_marks[3];
static void *previous,*next,*previous_label,*next_label,*notice,*confirm,*confirm_title,*confirm_name,*confirm_hint,*confirm_yes,*confirm_no;
static void *esim_scope,*esim_cards[3],*esim_labels[3],*esim_marks[3],*esim_prev,*esim_next,*esim_prev_label,*esim_next_label,*esim_notice,*esim_refresh_label;
static void *esim_confirm,*esim_confirm_title,*esim_confirm_name,*esim_confirm_hint,*esim_yes,*esim_no;
static struct esim_snapshot esim_shown;static unsigned esim_generation=(unsigned)-1,esim_selected_generation;
static int esim_offset;static char esim_selected_id[21],esim_selected_name[129];
static void *allocs[160],*timer;static int nalloc,current=1,offset,last_language=-1;
static struct snapshot shown;static unsigned last_generation=(unsigned)-1;
static int pending_wifi=-1;
static char selected_id[37],selected_name[257];
static int tr_ru(void){return *(int*)0x2288088==2;}
static const char *tr(const char *ru,const char *en){return tr_ru()?ru:en;}
static void pos(void *o,int x,int y){F(0x537450,void,void*,int,int)(o,x,y);}
static void size(void *o,int w,int h){F(0x5382b4,void,void*,int,int)(o,w,h);}
static void flag(void *o,unsigned f,int on){F(on?0x42e3c0:0x42e4f4,void,void*,unsigned)(P(o,8),f);}
static void color(void *o,int offset,int text){unsigned char *p=(void*)(uintptr_t)(0xe80214+offset);F(text?0x52f904:0x53793c,void,void*,int,int,int,int)(o,p[0],p[1],p[2],255);}
static void *objmem(size_t n){void *p=calloc(1,n);if(!p||nalloc>=160)_exit(70);allocs[nalloc++]=p;return p;}
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
 if(form!=mainform||!dots[4]){F(0x4bc1d0,void,void*,int)(form,page);return;}
 current=page;
 for(int i=0;i<5;i++){int active=i==page-1;flag(dots[i],HIDDEN,i>=page_count);pos(dots[i],156-8*(page_count-1)+16*i,active?439:440);size(dots[i],active?8:6,active?8:6);F(0x537868,void,void*,int)(dots[i],active?4:3);color(dots[i],active?168:172,0);}
}
static void goto_page(int page,int anim){
 if(!mainform)return;if(page<1)page=1;if(page>page_count)page=page_count;
 *((unsigned char*)mainform+840)=page;update_dots(mainform,page);F(0x538080,void,void*,int,int)(P(mainform,88),(page-1)*320,anim);
 if(page_kind(page)==PAGE_INFO||page_kind(page)==PAGE_VPN)backend_refresh();if(page_kind(page)==PAGE_ESIM)esim_refresh();
}
static void apply_pages(void){
 struct page_layout next;page_layout_read(&next);
 if(!memcmp(&next,&page_order,sizeof next))return;
 int kind=page_kind(current),target=current<=2?current:1;
 page_order=next;page_count=2+page_order.count;
 for(int id=0;id<3;id++)flag(pages[id],HIDDEN,1);
 for(int i=0;i<page_order.count;i++){int id=page_order.ids[i];pos(pages[id],(i+2)*320,0);flag(pages[id],HIDDEN,0);if(id==kind)target=i+3;}
 if(page_kind(target)!=PAGE_ESIM)esim_selected_id[0]=0;
 goto_page(target,0);
}
static void scroll_release(void *form){
 if(form!=mainform){F(0x4bd9ec,void,void*)(form);return;}
 void *indev=F(0x42a8c0,void*,void)();if(!indev)return;
 /* A vertical gesture belongs to the info viewport. Do not cancel its throw
  * vector or let the stock horizontal release callback change the page. */
 if((F(0x42ace8,unsigned,void*)(indev)&12)||(info_scroll&&F(0x42ad14,void*,void*)(indev)==P(info_scroll,8)))return;
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
 if(id>=60){
  if(esim_shown.busy)return;
  if(id>=60&&id<63){int i=esim_offset+id-60;if(esim_shown.valid&&i<esim_shown.count){snprintf(esim_selected_id,sizeof esim_selected_id,"%s",esim_shown.profiles[i].iccid);snprintf(esim_selected_name,sizeof esim_selected_name,"%s",esim_shown.profiles[i].name);esim_selected_generation=esim_shown.generation;}}
  else if(id==70){esim_offset-=3;if(esim_offset<0)esim_offset=0;}
  else if(id==71&&esim_offset+3<esim_shown.count)esim_offset+=3;
  else if(id==80&&esim_selected_id[0]){if(!esim_enable(esim_selected_id,esim_selected_generation))esim_refresh();esim_selected_id[0]=0;}
  else if(id==81)esim_selected_id[0]=0;
  else if(id==82){esim_selected_id[0]=0;esim_refresh();}
  esim_snapshot(&esim_shown);render();return;
 }
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
static const char *esim_stage(void){
 const char *s=esim_shown.stage;
 if(!strcmp(s,"radio_offline"))return tr("Автономный режим...","Entering flight mode...");
 if(!strcmp(s,"radio_online"))return tr("Включение радио...","Restoring radio...");
 if(!strcmp(s,"reading_modem"))return tr("Проверка SIM модемом...","Checking modem SIM...");
 if(!strcmp(s,"enabling_profile")||!strcmp(s,"enabling"))return tr("Переключение профиля...","Switching profile...");
 return tr("Чтение карты / проверка...","Reading card / checking...");
}
static const char *sim_card_status(const struct esim_snapshot *s,int ru){
 if(s->busy)return ru?"Проверка SIM-карты...":"Checking SIM card...";
 if(s->valid)return ru?"Физическая eUICC подтверждена":"Physical eUICC confirmed";
 if(s->error)return ru?"Тип SIM-карты не определён":"SIM card type unknown";
 return ru?"Проверьте SIM-карту":"Check the SIM card";
}
static void render_esim(void){
 text(titles[2],"eSIM");text(esim_scope,sim_card_status(&esim_shown,tr_ru()));
 if(esim_offset>=esim_shown.count)esim_offset=0;
 for(int i=0;i<3;i++){
  int idx=esim_offset+i;flag(esim_cards[i],HIDDEN,!esim_shown.cached||idx>=esim_shown.count);
  flag(esim_cards[i],CLICKABLE,esim_shown.valid&&!esim_shown.busy);
  if(idx<esim_shown.count){char caption[192];struct esim_profile *p=&esim_shown.profiles[idx];const char *tail=p->iccid+strlen(p->iccid)-4;
   snprintf(caption,sizeof caption,"%s\n%s · ...%s",p->name,!esim_shown.valid?tr("Сохранённый список","Saved list"):p->enabled?tr("Активен","Active"):tr("Выбрать","Select"),tail);text(esim_labels[i],caption);flag(esim_marks[i],HIDDEN,!p->enabled||!esim_shown.valid);
  }
 }
 flag(esim_prev,HIDDEN,esim_shown.count<=3||!esim_shown.cached);flag(esim_next,HIDDEN,esim_shown.count<=3||!esim_shown.cached);
 text(esim_prev_label,tr("Назад","Previous"));text(esim_next_label,tr("Далее","Next"));
 text(esim_refresh_label,tr("Обновить","Refresh"));
 const char *error_text=!strcmp(esim_shown.error_code,"radio_restore_failed")?tr("Радио не включилось.\nПроверьте связь в приложении","Radio did not resume.\nCheck the modem in the app"):!strcmp(esim_shown.error_code,"card_power_restore_failed")?tr("Включение SIM не подтверждено.\nПерезагрузите модем","SIM power was not confirmed.\nRestart the modem"):!strcmp(esim_shown.error_code,"card_reset_failed")?tr("Перезапуск SIM не подтверждён.\nОбновите и проверьте профиль","SIM restart was not confirmed.\nRefresh and check the profile"):!strcmp(esim_shown.error_code,"card_cleanup_unknown")?tr("Состояние SIM неизвестно.\nПерезагрузите модем","SIM channel state unknown.\nRestart the modem"):!strcmp(esim_shown.error_code,"card_busy")?tr("Доступ к SIM заблокирован.\nНет операций — перезапустите","SIM access is locked.\nIf idle, restart the modem"):!strcmp(esim_shown.error_code,"card_not_ready")?tr("SIM ещё не готова.\nПодождите и обновите список","SIM is not ready yet.\nWait and refresh the list"):!strcmp(esim_shown.error_code,"card_open_rejected")?tr("SIM отклонила чтение.\nПодождите и обновите список","SIM rejected the read.\nWait and refresh the list"):esim_shown.mutation_failed?tr("Переключение не подтверждено.\nОбновите и проверьте профиль","Switch was not confirmed.\nRefresh and check the profile"):!strcmp(esim_shown.error_code,"esim_busy")?tr("Карта занята другим запросом.\nОбновите после его завершения","Card busy with another request.\nRefresh after it finishes"):!strcmp(esim_shown.error_code,"snapshot_cleanup_failed")?tr("Чтение карты не завершено.\nНажмите «Обновить»","Card read did not finish.\nTap Refresh"):tr("Не удалось обновить список.\nНажмите «Обновить»","Could not refresh the list.\nTap Refresh");
 text(esim_notice,esim_shown.busy?esim_stage():esim_shown.error?error_text:!esim_shown.valid?tr("Ожидание агента eSIM","Waiting for eSIM agent"):!esim_shown.count?tr("На карте нет профилей","No profiles on card"):esim_shown.verified?tr("SIM перечитана модемом","Modem SIM verified"):tr("Нажмите профиль для выбора","Tap a profile to select"));
 int active=0;for(int i=0;i<esim_shown.count;i++)if(!strcmp(esim_shown.profiles[i].iccid,esim_selected_id))active=esim_shown.profiles[i].enabled;
 flag(esim_confirm,HIDDEN,!esim_selected_id[0]);text(esim_confirm_title,active?tr("Перечитать SIM?","Reread this SIM?"):tr("Выбрать профиль?","Select this profile?"));
 text(esim_confirm_name,esim_selected_name);text(esim_confirm_hint,tr("Связь прервётся: автономный\nрежим, затем радио включится","Mobile data will pause: flight\nmode, then radio resumes"));
 text(esim_yes,active?tr("Перечитать","Reread"):tr("Выбрать","Select"));text(esim_no,tr("Отмена","Cancel"));esim_generation=esim_shown.generation;
}
static void render(void){
 render_esim();
 struct info_text info;format_info(&shown,tr_ru(),&info);
 text(titles[0],tr("О модеме","About modem"));text(info_status,info.status);
 struct info_layout layout=shown.layout;if(!info_layout_valid(&layout))info_layout_default(&layout);
 int changed=!has_rendered_layout||memcmp(&layout,&rendered_layout,sizeof layout);
 struct info_slot slots[INFO_MAX_SELECTED];unsigned count=info_layout_slots(&layout,slots);
 if(changed)F(0x5380bc,void,void*,int,int)(info_scroll,0,0);
 for(unsigned i=0;i<INFO_MAX_SELECTED;i++){
  flag(info_cards[i],HIDDEN,i>=count);if(i>=count)continue;
  unsigned id=slots[i].metric;int carrier=id==INFO_CARRIERS;
  int tiles=layout.style==INFO_STYLE_TILES;
  if(changed){
   pos(info_cards[i],slots[i].x,slots[i].y);size(info_cards[i],slots[i].width,slots[i].height);
   pos(info_titles[i],tiles?10:12,tiles?8:3);size(info_titles[i],tiles?121:268,19);
   pos(info_values[i],tiles?10:12,tiles?30:23);size(info_values[i],tiles?121:268,tiles?70:carrier?40:24);
   F(0x52fa04,void,void*,int)(info_values[i],tiles?(carrier?16:17):(carrier?17:19));
  }
  text(info_titles[i],info_title(id,tr_ru(),tiles,&info));text(info_values[i],info.values[id]);
 }
 if(changed){F(0x5380bc,void,void*,int,int)(info_scroll,0,0);rendered_layout=layout;has_rendered_layout=1;}
 char ssid_text[96];int split_ssid=format_wifi_ssid(&shown,tr_ru(),ssid_text,sizeof ssid_text);
 text(wifi_ssid,ssid_text);pos(wifi_ssid,16,split_ssid?47:52);size(wifi_ssid,288,split_ssid?36:26);F(0x52fa04,void,void*,int)(wifi_ssid,split_ssid?14:18);
 text(wifi_title,tr("WiFi с VPN","WiFi with VPN"));if(!shown.busy)pending_wifi=-1;
 F(0x534c14,void,void*,int)(wifi_switch,shown.busy&&pending_wifi>=0?pending_wifi:shown.enabled);
 flag(wifi_switch,CLICKABLE,shown.valid&&!shown.busy);
 F(shown.busy||!shown.valid?0x42e660:0x42e67c,void,void*,unsigned)(P(wifi_switch,8),128);
 text(profile_heading,tr("Профиль VPN","VPN profile"));
 if(offset>=shown.count)offset=0;
 for(int i=0;i<3;i++){int idx=offset+i;flag(profile_cards[i],HIDDEN,idx>=shown.count);if(idx<shown.count){text(profile_labels[i],shown.profiles[idx].name);flag(profile_marks[i],HIDDEN,!shown.profiles[idx].active);}}
 flag(previous,HIDDEN,shown.count<=3);flag(next,HIDDEN,shown.count<=3);text(previous_label,tr("Назад","Previous"));text(next_label,tr("Далее","Next"));
 text(notice,shown.busy?tr("Применение...","Applying..."):shown.error?vpn_error_text(shown.error_code[0]?shown.error_code:shown.operation_error,tr_ru()):!shown.valid?tr("Получение данных...","Loading..."):!shown.count?tr("Добавьте профиль в агенте","Import a profile in the agent"):shown.enabled?(shown.network_ok&&shown.running?tr("VPN работает","VPN is running"):tr("Проверьте VPN в агенте","Check VPN in the agent")):tr("WiFi с VPN выключен","WiFi with VPN is off"));
 flag(confirm,HIDDEN,!selected_id[0]);text(confirm_title,tr("Подключить профиль?","Connect this profile?"));text(confirm_name,selected_name);text(confirm_hint,tr("VPN переподключится","VPN will reconnect"));text(confirm_yes,tr("Подключить","Connect"));text(confirm_no,tr("Отмена","Cancel"));
 last_generation=shown.generation;last_language=tr_ru();
}
static void tick(void *unused){
 (void)unused;if(!mainform||*(unsigned char*)0x2287598)return;
 apply_pages();
 int fd=open("/tmp/zte-launcher/page",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd>=0){
  char name[16]={0};ssize_t n=read(fd,name,sizeof name-1);close(fd);unlink("/tmp/zte-launcher/page");
  if(n==1&&name[0]>='1'&&name[0]<='0'+page_count)goto_page(name[0]-'0',0);
  else if(n>0){
   if(!strcmp(name,"home"))goto_page(1,0);
   const char *const names[]={"info","vpn","esim"};
   for(int i=0;i<page_order.count;i++)if(!strcmp(name,names[page_order.ids[i]])){goto_page(i+3,0);break;}
  }
 }
 unsigned old_stale=shown.telemetry.stale,old_valid=shown.telemetry.valid;
 esim_snapshot(&esim_shown);backend_snapshot(&shown);if(esim_shown.generation!=esim_generation||shown.generation!=last_generation||shown.telemetry.stale!=old_stale||shown.telemetry.valid!=old_valid||tr_ru()!=last_language)render();
 /* Periodic updates read telemetry/VPN only. Card reads are explicit:
  * eSIM entry, a refresh button, or the existing post-mutation verification. */
 static unsigned ticks;if(++ticks%10==0&&current>=3&&page_kind(current)!=PAGE_ESIM&& !*(unsigned char*)0x2287598&&F(0x538658,int,void*)(mainform))backend_refresh();
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
 mainform=form;current=1;offset=0;esim_offset=0;esim_selected_id[0]=0;selected_id[0]=0;has_rendered_layout=0;
 void *parent=P(form,88);
 pages[0]=panel(parent,640,0,320,432,0);pages[1]=panel(parent,960,0,320,432,0);pages[2]=panel(parent,1280,0,320,432,0);
 titles[0]=label(pages[0],16,12,288,34,24,"");info_status=label(pages[0],16,50,288,20,14,"");
 info_scroll=panel(pages[0],0,INFO_VIEWPORT_Y,320,INFO_VIEWPORT_HEIGHT,0);
 flag(info_scroll,CLICKABLE|SCROLLABLE|CHAIN_HOR,1);flag(info_scroll,CHAIN_VER|BUBBLE,0);
 /* Verified B31 LVGL functions: vertical-only content, horizontal chaining. */
 F(0x433198,void,void*,unsigned)(P(info_scroll,8),12);F(0x433134,void,void*,unsigned)(P(info_scroll,8),3);
 for(int i=0;i<INFO_MAX_SELECTED;i++){
  info_cards[i]=panel(info_scroll,14,0,292,48,1);flag(info_cards[i],CLICKABLE,0);
  info_titles[i]=label(info_cards[i],12,3,268,19,14,"");info_values[i]=label(info_cards[i],12,23,268,24,19,"");
 }
 titles[1]=label(pages[1],16,12,288,34,24,"VPN");wifi_ssid=label(pages[1],16,52,288,26,18,"");
 wifi_card=panel(pages[1],14,88,292,62,1);flag(wifi_card,CLICKABLE,0);
 wifi_title=label(wifi_card,12,20,196,30,19,"");
 wifi_switch=objmem(56);F(0x534a94,void,void*,void*)(wifi_switch,wifi_card);
 size(wifi_switch,45,24);pos(wifi_switch,231,19);flag(wifi_switch,SCROLLABLE,0);flag(wifi_switch,CHAIN_HOR|BUBBLE,1);
 F(0x534c08,void,void*,void(*)(int,void*),void*)(wifi_switch,wifi_changed,NULL);
 profile_heading=label(pages[1],16,163,288,24,16,"");
 for(int i=0;i<3;i++){profile_cards[i]=button(pages[1],14,194+54*i,292,48,10+i,&profile_labels[i]);pos(profile_labels[i],18,7);size(profile_labels[i],262,39);F(0x52fa04,void,void*,int)(profile_labels[i],17);F(0x52f73c,void,void*,int)(profile_labels[i],1);profile_marks[i]=panel(profile_cards[i],0,8,5,32,0);color(profile_marks[i],100,0);}
 previous=button(pages[1],14,355,140,34,20,&previous_label);next=button(pages[1],166,355,140,34,21,&next_label);
 notice=label(pages[1],16,394,288,36,14,"");
 confirm=panel(pages[1],8,156,304,247,0);confirm_title=label(confirm,8,14,288,32,22,"");confirm_name=label(confirm,8,57,288,70,20,"");confirm_hint=label(confirm,8,132,288,28,17,"");
 button(confirm,6,186,146,48,30,&confirm_yes);button(confirm,158,186,140,48,31,&confirm_no);
 titles[2]=label(pages[2],16,12,144,34,24,"eSIM");button(pages[2],178,8,128,38,82,&esim_refresh_label);esim_scope=label(pages[2],16,52,288,40,16,"");
 for(int i=0;i<3;i++){esim_cards[i]=button(pages[2],14,104+70*i,292,62,60+i,&esim_labels[i]);pos(esim_labels[i],16,5);size(esim_labels[i],264,54);F(0x52fa04,void,void*,int)(esim_labels[i],16);F(0x52f73c,void,void*,int)(esim_labels[i],1);esim_marks[i]=panel(esim_cards[i],0,8,5,46,0);color(esim_marks[i],100,0);}
 esim_prev=button(pages[2],14,320,140,40,70,&esim_prev_label);esim_next=button(pages[2],166,320,140,40,71,&esim_next_label);esim_notice=label(pages[2],16,371,288,58,16,"");
 esim_confirm=panel(pages[2],8,99,304,260,0);esim_confirm_title=label(esim_confirm,8,14,288,32,22,"");esim_confirm_name=label(esim_confirm,8,56,288,60,20,"");esim_confirm_hint=label(esim_confirm,8,125,288,55,16,"");
 button(esim_confirm,6,198,146,48,80,&esim_yes);button(esim_confirm,158,198,140,48,81,&esim_no);
 dots[0]=P(form,848);dots[1]=P(form,856);dots[2]=label(form,0,0,8,8,12,"");dots[3]=label(form,0,0,8,8,12,"");dots[4]=label(form,0,0,8,8,12,"");update_dots(form,1);
 page_order=(struct page_layout){255,{0}};page_count=2;apply_pages();
 backend_start();esim_start();esim_snapshot(&esim_shown);backend_snapshot(&shown);render();
 timer=F(0x481428,void*,void(*)(void*),unsigned,void*)(tick,500,NULL);
 int fd=open("/tmp/zte-launcher/ready",O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);if(fd>=0){dprintf(fd,"%ld\n",(long)getpid());close(fd);}
 fprintf(stderr,"launcher: configured native pages created\n");
}
static int hook(uintptr_t addr,uintptr_t before,void *after){
 if(*(uintptr_t*)addr!=before)return -1;uintptr_t page=addr&~(uintptr_t)4095;
 if(mprotect((void*)page,4096,PROT_READ|PROT_WRITE))return -1;*(void**)addr=after;return mprotect((void*)page,4096,PROT_READ);
}
__attribute__((constructor)) static void init(void){
 if(!getenv("ZTE_LAUNCHER"))return;unsetenv("LD_PRELOAD");unsetenv("ZTE_LAUNCHER");
 if(getauxval(AT_PHDR)!=0x400040 || getauxval(AT_ENTRY)!=0x421dc4)return;
 /* Setter/getter signatures are also checked as complete code ranges at build
  * time against both supported UI binaries. Fail closed before adding hooks. */
 if(*(uint32_t*)0x433198!=0xa9be7bfd||*(uint32_t*)0x4331d0!=0x33180e81||*(uint32_t*)0x433134!=0xa9be7bfd||*(uint32_t*)0x433174!=0x33000681||*(uint32_t*)0x5380bc!=0xa9be7bfd||*(uint32_t*)0x5380f0!=0xf9469e10||*(uint32_t*)0x42ace8!=0xb4000120||*(uint32_t*)0x42ad04!=0xd3608c00||*(uint32_t*)0x42ad2c!=0xf9402000)return;
 if(*(uintptr_t*)0xe72aa0!=0x4bd900||*(uintptr_t*)0xe7d968!=0x4bd9ec||*(uintptr_t*)0xe7b448!=0x4bc1d0||*(uintptr_t*)0xe72a08!=0x4b7ffc||*(uintptr_t*)0xe79c30!=0x4b7ffc)return;
 if(hook(0xe72aa0,0x4bd900,create)||hook(0xe7d968,0x4bd9ec,scroll_release)||hook(0xe7b448,0x4bc1d0,update_dots)||hook(0xe72a08,0x4b7ffc,destroy)||hook(0xe79c30,0x4b7ffc,destroy))_exit(71);
 fprintf(stderr,"launcher: B31 hooks installed\n");
}
#endif /* LAUNCHER_FORMAT_TEST */
