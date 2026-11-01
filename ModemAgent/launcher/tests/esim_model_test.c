#include "../esim-backend.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../third_party/lpac/cjson/cJSON.h"
#define TARGET "internal-euicc-slot2"
#define CARD "\"card\":{\"kind\":\"euicc_confirmed\",\"management\":\"available\",\"reason\":\"eid_and_profiles_read\",\"cleanup_confirmed\":true}"
#define ORDINARY "\"card\":{\"kind\":\"ordinary_sim\",\"management\":\"unavailable\",\"reason\":\"isdr_not_found\",\"cleanup_confirmed\":true}"
#define SNAP "\"snapshot\":{\"ok\":true,\"target\":\"" TARGET "\",\"eid\":\"89000000000000000000000000000000\",\"profiles\":[{\"iccid\":\"8999999999999999991\",\"state\":\"enabled\",\"enabled\":true,\"nickname\":null,\"name\":\"Test\\nname\"}]}"
#define FIELDS "\"target\":\"" TARGET "\",\"operations\":[\"list\",\"enable\"],\"network_selected\":true," CARD "," SNAP
#define RESULT "{\"type\":\"result\",\"ok\":true,\"changed\":false,\"notifications_pending\":false," FIELDS "}"
#define ABSENT "{\"target\":\"removable-euicc-slot1\",\"operations\":[],\"network_selected\":false,\"card\":{\"kind\":\"unknown\",\"management\":\"unknown\",\"reason\":\"not_present\",\"cleanup_confirmed\":true}}"
static int parse(cJSON *root,struct esim_snapshot *s,char **canonical,int verified){char *wire=cJSON_PrintUnformatted(root);assert(wire);int ok=esim_parse_result(wire,s,canonical,verified);cJSON_free(wire);return ok;}
static int discovery(cJSON *root,struct esim_snapshot *s){char *wire=cJSON_PrintUnformatted(root);assert(wire);int ok=esim_parse_discovery(wire,s);cJSON_free(wire);return ok;}
int main(void){
 assert(esim_choose_target(2,1,"",0)==1);
 assert(esim_choose_target(3,1,TARGET,0)==-1);
 assert(esim_choose_target(2,0,TARGET,0)==-1);
 assert(esim_choose_target(3,1,TARGET,1)==1);
 assert(esim_choose_target(2,0,TARGET,1)==1);
 assert(esim_choose_target(1,1,TARGET,1)==-1);
 assert(esim_choose_target(0,1,TARGET,1)==-1);

 struct esim_snapshot *s=calloc(1,sizeof *s);assert(s);char *canonical=NULL,b[8192],stage[40];
 assert(esim_parse_result(RESULT,s,&canonical,0));assert(s->count==1&&s->profiles[0].enabled&&!strcmp(s->profiles[0].name,"Test name")&&s->can_enable&&!strcmp(s->target,TARGET));
 assert(strstr(canonical,TARGET));assert(!esim_parse_result(RESULT,s,&canonical,1));
 cJSON *root=cJSON_Parse(RESULT);assert(root);cJSON_AddBoolToObject(root,"modem_verified",1);cJSON_AddBoolToObject(root,"radio_restored",1);assert(parse(root,s,&canonical,1));cJSON_Delete(root);
 const char *required[]={"target","card","snapshot","operations","network_selected"};
 for(unsigned i=0;i<sizeof required/sizeof required[0];i++){root=cJSON_Parse(RESULT);cJSON_DeleteItemFromObjectCaseSensitive(root,required[i]);assert(!parse(root,s,&canonical,0));cJSON_Delete(root);}
 root=cJSON_Parse(RESULT);cJSON_ReplaceItemInObjectCaseSensitive(cJSON_GetObjectItemCaseSensitive(root,"snapshot"),"target",cJSON_CreateString(esim_target_name(0)));assert(!parse(root,s,&canonical,0));cJSON_Delete(root);
 root=cJSON_Parse(RESULT);cJSON_ReplaceItemInObjectCaseSensitive(root,"target",cJSON_CreateString("private-target"));assert(!parse(root,s,&canonical,0));cJSON_Delete(root);
 root=cJSON_Parse(RESULT);cJSON_ReplaceItemInObjectCaseSensitive(root,"network_selected",cJSON_CreateFalse());assert(!parse(root,s,&canonical,0));cJSON_DeleteItemFromObjectCaseSensitive(root,"operations");cJSON_AddItemToObject(root,"operations",cJSON_CreateArray());assert(parse(root,s,&canonical,0)&&!s->can_enable);cJSON_Delete(root);
 root=cJSON_Parse(RESULT);cJSON *profiles=cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(root,"snapshot"),"profiles");cJSON_AddItemToArray(profiles,cJSON_Duplicate(cJSON_GetArrayItem(profiles,0),1));assert(!parse(root,s,&canonical,0));cJSON_Delete(root);
 snprintf(b,sizeof b,"{\"type\":\"result\",\"ok\":true,\"changed\":false,\"notifications_pending\":false,\"target\":\"%s\",\"operations\":[],\"network_selected\":false," ORDINARY "}",TARGET);
 assert(esim_parse_result(b,s,&canonical,0)&&s->ordinary&&!s->valid&&!s->cached&&!canonical);assert(!esim_parse_result(b,s,&canonical,1));
 const char *bad[]={"{}","null","[]","{\"type\":\"result\",\"ok\":false}","{\"type\":\"result\",\"ok\":true,\"snapshot\":{\"ok\":true,\"eid\":\"89000000000000000000000000000000\",\"profiles\":[]}}"};
 for(unsigned i=0;i<sizeof bad/sizeof bad[0];i++)assert(!esim_parse_result(bad[i],s,&canonical,0));
 snprintf(b,sizeof b,"{\"type\":\"result\",\"ok\":true,\"complete\":true,\"changed\":false,\"notifications_pending\":false,\"targets\":[" ABSENT ",{%s}]}",FIELDS);
 assert(esim_parse_discovery(b,s)&&s->discovered&&s->complete&&s->targets==2);
 root=cJSON_Parse(b);cJSON *targets=cJSON_GetObjectItemCaseSensitive(root,"targets"),*entry=cJSON_GetArrayItem(targets,1);cJSON_ReplaceItemInObjectCaseSensitive(entry,"target",cJSON_CreateString(esim_target_name(0)));assert(!discovery(root,s));cJSON_Delete(root);
 root=cJSON_Parse(b);targets=cJSON_GetObjectItemCaseSensitive(root,"targets");cJSON *second=cJSON_Duplicate(cJSON_GetArrayItem(targets,1),1);cJSON_ReplaceItemInObjectCaseSensitive(second,"target",cJSON_CreateString(esim_target_name(0)));cJSON_ReplaceItemInObjectCaseSensitive(cJSON_GetObjectItemCaseSensitive(second,"snapshot"),"target",cJSON_CreateString(esim_target_name(0)));cJSON_ReplaceItemInArray(targets,0,second);assert(discovery(root,s)&&s->targets==3);cJSON_Delete(root);
 root=cJSON_Parse(b);entry=cJSON_GetObjectItemCaseSensitive(cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(root,"targets"),0),"card");cJSON_ReplaceItemInObjectCaseSensitive(entry,"reason",cJSON_CreateString("read_failed"));assert(!discovery(root,s));cJSON_ReplaceItemInObjectCaseSensitive(root,"complete",cJSON_CreateFalse());assert(discovery(root,s)&&!s->complete);cJSON_ReplaceItemInObjectCaseSensitive(entry,"cleanup_confirmed",cJSON_CreateFalse());assert(!discovery(root,s));cJSON_ReplaceItemInObjectCaseSensitive(entry,"cleanup_confirmed",cJSON_CreateTrue());cJSON_ReplaceItemInObjectCaseSensitive(entry,"reason",cJSON_CreateString("cleanup_unknown"));assert(!discovery(root,s));cJSON_Delete(root);
 const char *stages[]={"discovering_cards","checking_card","reading_profiles","enabling","verifying","notifications","cleanup","radio_offline","radio_online","reading_modem"};
 for(unsigned i=0;i<sizeof stages/sizeof stages[0];i++){snprintf(b,sizeof b,"{\"type\":\"progress\",\"stage\":\"%s\"}",stages[i]);assert(esim_parse_progress(b,stage)&&!strcmp(stage,stages[i]));}
 assert(!esim_parse_progress("{\"type\":\"progress\",\"stage\":\"private\"}",stage));
 char error[64],component[64];assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"target_mismatch\"}",error,component)&&!strcmp(error,"target_mismatch"));assert(esim_parse_error("{\"type\":\"result\",\"ok\":false,\"error\":\"secret\",\"component_error\":\"secret\"}",error,component)&&!strcmp(error,"agent_error")&&!component[0]);
 free(canonical);free(s);puts("eSIM v2 parser: target binding, legacy refusal, two-card discovery, partial/cleanup failures and radio permissions passed");
}
