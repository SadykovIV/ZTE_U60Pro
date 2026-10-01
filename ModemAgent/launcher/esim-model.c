#include "esim-backend.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct cJSON cJSON;
extern cJSON *cJSON_ParseWithOpts(const char *,const char **,int);
extern int cJSON_IsObject(const cJSON *),cJSON_IsArray(const cJSON *),cJSON_IsBool(const cJSON *),cJSON_IsTrue(const cJSON *);
extern void cJSON_Delete(cJSON *),cJSON_free(void *);
extern cJSON *cJSON_GetObjectItemCaseSensitive(const cJSON *,const char *),*cJSON_GetArrayItem(const cJSON *,int);
extern int cJSON_GetArraySize(const cJSON *);
extern char *cJSON_GetStringValue(const cJSON *),*cJSON_PrintUnformatted(const cJSON *);
static cJSON *get(cJSON *o,const char *key){return cJSON_GetObjectItemCaseSensitive(o,key);}
static const char *str(cJSON *o,const char *key){return cJSON_GetStringValue(get(o,key));}
static int eq(const char *s,const char *v){return s&&!strcmp(s,v);}
static int decimal(const char *s,size_t lo,size_t hi){if(!s||strlen(s)<lo||strlen(s)>hi)return 0;for(;*s;s++)if(*s<'0'||*s>'9')return 0;return 1;}
static void name_copy(char out[129],const char *s){
 if(!s||!*s)s="eSIM";size_t n=strlen(s);if(n>128){n=125;while(n&&((unsigned char)s[n]&0xc0)==0x80)n--;memcpy(out,s,n);memcpy(out+n,"...",4);}else memcpy(out,s,n+1);
 for(char *p=out;*p;p++)if((unsigned char)*p<32||(unsigned char)*p==127)*p=' ';
}
int esim_parse_result(const char *line,struct esim_snapshot *out,char **canonical,int require_verified){
 cJSON *root=cJSON_ParseWithOpts(line,NULL,1);if(!root)return 0;int ok=0;
 cJSON *snap=get(root,"snapshot"),*profiles=get(snap,"profiles");
 if(!cJSON_IsObject(root)||!eq(str(root,"type"),"result")||!cJSON_IsTrue(get(root,"ok"))||!cJSON_IsObject(snap)||!cJSON_IsTrue(get(snap,"ok"))||!decimal(str(snap,"eid"),32,32)||!cJSON_IsArray(profiles)||(require_verified&&(!cJSON_IsTrue(get(root,"modem_verified"))||!cJSON_IsTrue(get(root,"radio_restored")))))goto end;
 int count=cJSON_GetArraySize(profiles),active=0;if(count<0||count>ESIM_MAX_PROFILES)goto end;
 for(int i=0;i<count;i++){
  cJSON *p=cJSON_GetArrayItem(profiles,i);const char *id=str(p,"iccid"),*state=str(p,"state");int enabled=cJSON_IsTrue(get(p,"enabled"));
  if(!cJSON_IsObject(p)||!decimal(id,18,20)||!cJSON_IsBool(get(p,"enabled"))||!(eq(state,"enabled")||eq(state,"disabled")||eq(state,"unknown"))||enabled!=eq(state,"enabled"))goto end;
  for(int j=0;j<i;j++)if(!strcmp(out->profiles[j].iccid,id))goto end;
  if(enabled&&++active>1)goto end;
  const char *name=str(p,"nickname");if(!name||!*name)name=str(p,"name");if(!name||!*name)name=str(p,"service_provider");
  snprintf(out->profiles[i].iccid,sizeof out->profiles[i].iccid,"%s",id);name_copy(out->profiles[i].name,name);out->profiles[i].enabled=enabled;
 }
 char *json=cJSON_PrintUnformatted(snap);if(!json)goto end;char *copy=strdup(json);cJSON_free(json);if(!copy)goto end;
 free(*canonical);*canonical=copy;out->count=count;out->valid=1;out->cached=1;out->verified=cJSON_IsTrue(get(root,"modem_verified"));ok=1;
end:cJSON_Delete(root);return ok;
}
int esim_parse_progress(const char *line,char stage[40]){
 cJSON *root=cJSON_ParseWithOpts(line,NULL,1);if(!root)return 0;const char *s=str(root,"stage");int ok=0;
 static const char *const allowed[]={"checking_card","reading_profiles","cleanup","opening_channel","listing_profiles","enabling_profile","closing_channel","verifying","processing_notifications","radio_offline","radio_online","reading_modem","complete","checking","opening","enabling","closing","notifications"};
 if(eq(str(root,"type"),"progress")&&s)for(unsigned i=0;i<sizeof allowed/sizeof allowed[0];i++)if(!strcmp(s,allowed[i])){snprintf(stage,40,"%s",s);ok=1;break;}
 cJSON_Delete(root);return ok;
}

/* Error text is a protocol code, never raw subprocess/card output. */
int esim_parse_error(const char *line,char error[64],char component[64]){
 component[0]=0;
 cJSON *root=cJSON_ParseWithOpts(line,NULL,1);if(!root)return 0;
 int ok=eq(str(root,"type"),"result")&&cJSON_IsBool(get(root,"ok"))&&!cJSON_IsTrue(get(root,"ok"));
 if(ok){
  const char *code=str(root,"error");
  static const char *const known[]={"esim_busy","card_busy","card_open_rejected","card_cleanup_unknown","card_not_ready","card_reset_failed","card_power_restore_failed","operation_lock_failed","snapshot_cleanup_failed","unsupported_device","helper_verification_failed","snapshot_failed","snapshot_changed","profile_not_found","enable_failed","radio_not_online","radio_offline_failed","radio_online_failed","radio_restore_failed","modem_iccid_mismatch","modem_slot_mismatch","modem_readback_failed","radio_read_failed","radio_set_failed","card_changed","postcondition_failed","notification_cleanup_failed","modem_profile_mismatch","modem_read_failed","stream_write_failed","invalid_request","request_missing"};
  const char *cause=str(root,"component_error");
  static const char *const components[]={"lock_unavailable","lock_random_failed","lock_owner_failed","lock_metadata_failed","lock_release_failed","lock_ownership_changed","lock_retained","selection_read_failed","selection_mismatch","qmi_connect_error","qmi_open_rejected","qmi_open_unknown","channel_open_outcome_unknown","channel_close_failed","card_cleanup_unknown","card_not_ready","unsupported_channel","qmi_transmit_error","short_apdu_response","snapshot_response_too_large","snapshot_continuation_limit","snapshot_card_status_error","eid_command_error","eid_parse_error","eid_mismatch","profiles_command_error","profiles_parse_error","stdout_error","stdin_error","unterminated_json_line","input_line_too_large","invalid_json_line","invalid_header","invalid_expected_eid","missing_header","invalid_arguments","bridge_operation_failed","already_connected","already_open","session_failed","not_connected","not_open","missing_owned_connection","empty_read_command","invalid_envelope","invalid_function","invalid_aid","aid_not_allowed","invalid_apdu","invalid_hex","unsupported_function"};
  for(unsigned i=0;i<sizeof components/sizeof components[0];i++)if(eq(cause,components[i])){snprintf(component,64,"%s",components[i]);break;}
  snprintf(error,64,"agent_error");
  for(unsigned i=0;i<sizeof known/sizeof known[0];i++)if(eq(code,known[i])){snprintf(error,64,"%s",code);break;}
 }
 cJSON_Delete(root);return ok;
}
