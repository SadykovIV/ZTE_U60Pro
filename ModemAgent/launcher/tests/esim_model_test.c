#include "../esim-backend.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *profile="{\"iccid\":\"8999999999999999991\",\"state\":\"enabled\",\"enabled\":true,\"nickname\":null,\"name\":\"Test\\nname\"}";
int main(void){
 struct esim_snapshot *s=calloc(1,sizeof *s);char *canonical=NULL;char b[4096],stage[40];
 snprintf(b,sizeof b,"{\"type\":\"result\",\"ok\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":[%s]}}",profile);
 assert(esim_parse_result(b,s,&canonical,0));assert(s->count==1&&s->profiles[0].enabled&&!strcmp(s->profiles[0].name,"Test name"));
 assert(!esim_parse_result(b,s,&canonical,1));
 snprintf(b,sizeof b,"{\"type\":\"result\",\"ok\":true,\"modem_verified\":true,\"radio_restored\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":[%s]}}",profile);
 assert(esim_parse_result(b,s,&canonical,1));assert(s->verified&&s->cached&&s->valid);
 snprintf(b,sizeof b,"{\"type\":\"result\",\"ok\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":[%s,%s]}}",profile,profile);assert(!esim_parse_result(b,s,&canonical,0));
 const char *bad[]={"{}","null","[]","{\"type\":\"result\",\"ok\":false}","{\"type\":\"result\",\"ok\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":{}}}","{\"type\":\"result\",\"ok\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":[{\"iccid\":\"8999999999999999991\",\"state\":\"enabled\",\"enabled\":false}]}}"};
 for(unsigned i=0;i<sizeof bad/sizeof bad[0];i++)assert(!esim_parse_result(bad[i],s,&canonical,0));
 const char *stages[]={"checking_card","reading_profiles","enabling","verifying","notifications","cleanup","radio_offline","radio_online","reading_modem"};
 for(unsigned i=0;i<sizeof stages/sizeof stages[0];i++){snprintf(b,sizeof b,"{\"type\":\"progress\",\"stage\":\"%s\",\"detail\":{\"event\":\"waiting\"}}",stages[i]);assert(esim_parse_progress(b,stage));assert(!strcmp(stage,stages[i]));}
 assert(!esim_parse_progress("{\"type\":\"http\",\"stage\":\"checking_card\"}",stage));assert(!esim_parse_progress("{\"type\":\"progress\",\"stage\":\"unknown\"}",stage));
 char error[64],component[64];
 assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"esim_busy\"}",error,component)&&!strcmp(error,"esim_busy"));
 assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"secret-from-card-123\"}",error,component)&&!strcmp(error,"agent_error"));
 assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"card_cleanup_unknown\",\"component_error\":\"qmi_open_unknown\"}",error,component)&&!strcmp(error,"card_cleanup_unknown")&&!strcmp(component,"qmi_open_unknown"));
 assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"card_busy\",\"component_error\":\"secret-123\"}",error,component)&&!strcmp(error,"card_busy")&&!component[0]);
 assert(!esim_parse_error("{\"type\":\"result\",\"ok\":true}",error,component));
 assert(!esim_parse_error("{\"type\":\"result\",\"ok\":null}",error,component));
 const char *ordinary="{\"type\":\"result\",\"ok\":true,\"changed\":false,\"notifications_pending\":false,\"card\":{\"kind\":\"ordinary_sim\",\"management\":\"unavailable\",\"reason\":\"isdr_not_found\",\"cleanup_confirmed\":true}}";
 assert(esim_parse_result(ordinary,s,&canonical,0));assert(s->ordinary&&!s->valid&&!s->cached&&!s->count&&!canonical);
 assert(!esim_parse_result(ordinary,s,&canonical,1));
 const char *fields[]={"\"error\":null,","\"error\":\"card_cleanup_unknown\",","\"snapshot\":null,","\"modem_verified\":false,","\"radio_restored\":true,","\"component_error\":null,"};
 for(unsigned i=0;i<sizeof fields/sizeof fields[0];i++){snprintf(b,sizeof b,"{%s%s",fields[i],ordinary+1);assert(!esim_parse_result(b,s,&canonical,0));}
 snprintf(b,sizeof b,"{\"type\":\"result\",\"ok\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":[]}}");
 assert(esim_parse_result(b,s,&canonical,0));assert(!s->ordinary&&s->valid&&s->cached&&!s->count&&canonical);
 assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"card_not_euicc\"}",error,component)&&!strcmp(error,"card_not_euicc"));
 free(canonical);free(s);puts("eSIM parser: valid, malformed, duplicate, fresh modem proof and stage contract passed");
}
