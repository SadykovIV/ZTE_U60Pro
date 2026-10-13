#include "../backend.h"
#include "../vpn-model.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while (0)
static const char *id = "01234567-89ab-cdef-0123-456789abcdef";
static char *reply(const char *schema, const char *enabled, const char *running,
                   const char *network, const char *profiles, const char *extras) {
    static char b[512 * 1024];
    int n = snprintf(b, sizeof b,
        "{\"ok\":true,\"data\":{\"schema_version\":%s,\"enabled\":%s,"
        "\"core_running\":%s,\"network_ok\":%s,\"profiles\":%s%s}}",
        schema, enabled, running, network, profiles, extras);
    assert(n > 0 && (size_t)n < sizeof b);
    return b;
}
static char *profile(const char *uuid, const char *name, const char *active) {
    static char b[2048];
    snprintf(b, sizeof b, "[{\"id\":\"%s\",\"name\":\"%s\",\"active\":%s}]", uuid, name, active);
    return b;
}
static void reject(const char *json) {
    struct snapshot out, before;
    memset(&out, 0x5a, sizeof out); before = out;
    CHECK(!vpn_parse_status(&out, json));
    CHECK(!memcmp(&out, &before, sizeof out));
}

struct fixture {int calls,progress,fail_at,final_fail;const char *error;char inputs[5][128];};
static int request(void *context,struct snapshot *s,const char *input,const char **code){
    struct fixture *f=context;int i=f->calls++;assert(i<5);snprintf(f->inputs[i],sizeof f->inputs[i],"%s",input);
    if(i==f->fail_at || (i<3&&f->fail_at==4) || (i==3&&f->final_fail)){*code=f->error;return 0;}
    /* Changing the returned catalog cannot change this batch's original IDs. */
    CHECK(vpn_parse_status(s,reply("1","true","true","true",profile(id,"Active","true"),",\"subscriptions\":[]")));
    return 1;
}
static void progress(void *context,const struct snapshot *s){
    struct fixture *f=context;CHECK(s->subscription_update.running);CHECK(s->subscription_update.done==f->progress++);
    char text[256];vpn_subscription_text(s,1,text,sizeof text);CHECK(*text);
}
static void batch_tests(void){
    for(int fail=-1;fail<3;fail++)for(int statusfail=0;statusfail<2;statusfail++){
        struct snapshot s={.valid=1,.busy=1,.subscription_count=3};
        for(int i=0;i<3;i++)snprintf(s.subscriptions[i],sizeof s.subscriptions[i],"%08x-89ab-cdef-0123-456789abcdef",i);
        struct fixture f={.fail_at=fail,.final_fail=statusfail,.error="VPN_SUBSCRIPTION_FETCH"};
        CHECK(vpn_update_subscriptions(&s,request,progress,&f));CHECK(f.calls==4&&f.progress==4);
        for(int i=0;i<3;i++){char input[128];snprintf(input,sizeof input,"{\"action\":\"subscription_update\",\"id\":\"%08x-89ab-cdef-0123-456789abcdef\"}",i);CHECK(!strcmp(input,f.inputs[i]));}
        CHECK(!strcmp(f.inputs[3],"{\"action\":\"status\"}"));
        CHECK(s.subscription_update.total==3&&s.subscription_update.done==3&&s.subscription_update.succeeded==(fail<0?3:2));
        CHECK(!s.subscription_update.running&&s.subscription_update.complete);
        CHECK(s.valid==!statusfail);CHECK(s.profiles[0].active&&!strcmp(s.profiles[0].id,id));
        CHECK(!strcmp(s.subscription_update.first_error,fail<0?"":"VPN_SUBSCRIPTION_FETCH"));
        char text[256];vpn_subscription_text(&s,0,text,sizeof text);CHECK(strstr(text,fail<0?"Updated 3/3 · errors 0":"Updated 2/3 · errors 1"));
        vpn_subscription_text(&s,1,text,sizeof text);CHECK(strstr(text,"Обновлено"));
        CHECK(vpn_parse_status(&s,reply("1","true","true","true","[]","")));CHECK(s.subscription_update.complete&&s.subscription_update.done==3);
    }
    struct snapshot s={.valid=1};struct fixture f={.fail_at=0,.error="PRIVATE_CANARY"};
    CHECK(!vpn_update_subscriptions(&s,request,progress,&f)&&!f.calls);
    s.subscription_count=MAX_SUBSCRIPTIONS+1;CHECK(!vpn_update_subscriptions(&s,request,progress,&f)&&!f.calls);
    s.subscription_count=3;for(int i=0;i<3;i++)snprintf(s.subscriptions[i],37,"%08x-89ab-cdef-0123-456789abcdef",i);
    CHECK(vpn_update_subscriptions(&s,request,NULL,&f));CHECK(!strcmp(s.subscription_update.first_error,"VPN_OPERATION_FAILED"));
    char text[256];vpn_subscription_text(&s,1,text,sizeof text);CHECK(!strstr(text,"PRIVATE_CANARY"));
    s.valid=1;s.subscription_count=3;for(int i=0;i<3;i++)snprintf(s.subscriptions[i],37,"%08x-89ab-cdef-0123-456789abcdef",i);
    f=(struct fixture){.fail_at=4,.error="VPN_RESULT_UNKNOWN"};
    CHECK(vpn_update_subscriptions(&s,request,progress,&f));CHECK(f.calls==4&&s.subscription_update.done==3&&!s.subscription_update.succeeded&&s.valid);
    CHECK(!strcmp(s.subscription_update.first_error,"VPN_RESULT_UNKNOWN"));
    vpn_subscription_text(&s,0,text,sizeof text);CHECK(strstr(text,"Updated 0/3 · errors 3"));
}

int main(void) {
    struct snapshot out, expected;
    memset(&out, 0x5a, sizeof out); expected = out;
    const char *json = reply("1", "true", "false", "true", profile(id, "Тест", "true"),
                             ",\"ssid\":\"Test WiFi\",\"ssid_2g\":\"2G\",\"ssid_5g\":\"5G\"");
    CHECK(vpn_parse_status(&out, json));
    expected.valid = 1; expected.enabled = 1; expected.running = 0; expected.network_ok = 1; expected.count = 1; expected.subscription_count = 0; memset(expected.subscriptions,0,sizeof expected.subscriptions);
    memset(expected.profiles, 0, sizeof expected.profiles);
    strcpy(expected.profiles[0].id, id); strcpy(expected.profiles[0].name, "Тест"); expected.profiles[0].active = 1;
    memset(expected.ssid, 0, sizeof expected.ssid); strcpy(expected.ssid, "Test WiFi");
    memset(expected.ssid_2g, 0, sizeof expected.ssid_2g); strcpy(expected.ssid_2g, "2G");
    memset(expected.ssid_5g, 0, sizeof expected.ssid_5g); strcpy(expected.ssid_5g, "5G");
    CHECK(!memcmp(&out, &expected, sizeof out)); /* Including errors, telemetry, generation and layout. */
    CHECK(vpn_parse_status(&out, reply("1.0", "false", "false", "false", "[]", "")));
    CHECK(out.count == 0 && !out.enabled && !out.running && !out.network_ok && !out.ssid[0]);

    CHECK(!vpn_can_update_subscriptions(&out));
    CHECK(vpn_parse_status(&out,reply("1","true","false","true","[]",",\"subscriptions\":[{\"id\":\"01234567-89ab-cdef-0123-456789abcdef\",\"url\":\"PRIVATE_CANARY\"}]")));
    out.busy=0;CHECK(vpn_can_update_subscriptions(&out));out.busy=1;CHECK(!vpn_can_update_subscriptions(&out));out.busy=0;
    CHECK(out.subscription_count==1&&!strcmp(out.subscriptions[0],id));
    CHECK(!strcmp(out.subscriptions[0],id)&&!out.subscriptions[1][0]);
    const char *badsubs[]={",\"subscriptions\":null",",\"subscriptions\":{}",",\"subscriptions\":[{}]",",\"subscriptions\":[{\"id\":\"bad\"}]",",\"subscriptions\":[{\"id\":\"01234567-89ab-cdef-0123-456789abcdef\"},{\"id\":\"01234567-89ab-cdef-0123-456789abcdef\"}]"};
    for(unsigned i=0;i<sizeof badsubs/sizeof badsubs[0];i++)reject(reply("1","true","false","true","[]",badsubs[i]));
    CHECK(vpn_parse_status(&out,reply("1","true","false","true","[{\"id\":\"01234567-89ab-cdef-0123-456789abcdef\",\"name\":\"Warning\",\"active\":false,\"warnings\":[\"VPN_INSECURE_TLS\",\"PRIVATE_CANARY\"]}]","")));
    CHECK(out.profiles[0].insecure_tls&&!out.subscription_count);
    for(int ru=0;ru<2;ru++){CHECK(vpn_warning_text("VPN_INSECURE_TLS",ru));CHECK(vpn_warning_text("VPN_SPX_PRESERVED",ru));CHECK(!vpn_warning_text("PRIVATE_CANARY",ru));}

    const char *malformed[] = {NULL, "", "null", "[]", "{}", "{\"ok\":true}",
        "{\"ok\":false,\"data\":{}}", "{\"ok\":1,\"data\":{}}", "{\"ok\":\"true\",\"data\":{}}",
        "{\"ok\":true,\"data\":[]}", "{\"ok\":true,\"data\":null}"};
    for (unsigned i = 0; i < sizeof malformed / sizeof malformed[0]; i++) reject(malformed[i]);
    const char *schemas[] = {"null", "true", "\"1\"", "0", "2", "1.5", "{}", "[]"};
    for (unsigned i = 0; i < sizeof schemas / sizeof schemas[0]; i++) reject(reply(schemas[i], "true", "false", "true", "[]", ""));
    const char *badbool[] = {"null", "0", "1", "\"true\"", "{}", "[]"};
    for (unsigned i = 0; i < sizeof badbool / sizeof badbool[0]; i++) {
        reject(reply("1", badbool[i], "false", "true", "[]", ""));
        reject(reply("1", "true", badbool[i], "true", "[]", ""));
        reject(reply("1", "true", "false", badbool[i], "[]", ""));
        reject(reply("1", "true", "false", "true", profile(id, "Test", badbool[i]), ""));
    }
    const char *badarrays[] = {"{}", "null", "true", "[null]", "[{}]", "[1]", "[\"profile\"]"};
    for (unsigned i = 0; i < sizeof badarrays / sizeof badarrays[0]; i++) reject(reply("1", "true", "false", "true", badarrays[i], ""));
    const char *badids[] = {"", "01234567-89ab-cdef-0123-456789abcde", "01234567-89ab-cdef-0123-456789abcdef0",
        "01234567-89ab-CDEF-0123-456789abcdef", "01234567889ab-cdef-0123-456789abcdef", "01234567-89ab-cdef-0123-456789abcdeg",
        "01234567-89ab-cdef-0123-456789abcdef\\u0000private"};
    for (unsigned i = 0; i < sizeof badids / sizeof badids[0]; i++) reject(reply("1", "true", "false", "true", profile(badids[i], "Test", "false"), ""));
    const char *badnames[] = {"", "line\\nname", "tab\\tname", "name\\u0000private", "name\\u007f", "name\\u001b"};
    for (unsigned i = 0; i < sizeof badnames / sizeof badnames[0]; i++) reject(reply("1", "true", "false", "true", profile(id, badnames[i], "false"), ""));
    char name[258]; memset(name, 'x', sizeof name); name[256] = 0;
    CHECK(vpn_parse_status(&out, reply("1", "true", "false", "true", profile(id, name, "false"), "")));
    name[256] = 'x'; name[257] = 0; reject(reply("1", "true", "false", "true", profile(id, name, "false"), ""));
    CHECK(vpn_parse_status(&out, reply("1", "true", "false", "true", profile(id, "literal\\\\u0000", "false"), "")));

    static char many[512 * 1024]; size_t used = 0;
    many[used++] = '['; many[used] = 0;
    for (int i = 0; i < MAX_PROFILES + 1; i++) {
        used += (size_t)snprintf(many + used, sizeof many - used,
            "%s{\"id\":\"%08x-89ab-cdef-0123-456789abcdef\",\"name\":\"Profile\",\"active\":false}", i ? "," : "", i);
        if (i == MAX_PROFILES - 1) {
            many[used] = ']'; many[used + 1] = 0;
            CHECK(vpn_parse_status(&out, reply("1", "true", "false", "true", many, ""))); CHECK(out.count == MAX_PROFILES);
        }
    }
    many[used++] = ']'; many[used] = 0; reject(reply("1", "true", "false", "true", many, ""));
    /* An oversized subscription list is explicit, never silently truncated or
     * dispatched in part. Other status remains usable. */
    static char subs[128*1024];size_t subused=(size_t)snprintf(subs,sizeof subs,",\"subscriptions\":[");
    for(int i=0;i<MAX_SUBSCRIPTIONS+1;i++)subused+=(size_t)snprintf(subs+subused,sizeof subs-subused,"%s{\"id\":\"%08x-89ab-cdef-0123-456789abcdef\"}",i?",":"",i);
    snprintf(subs+subused,sizeof subs-subused,"]");
    CHECK(vpn_parse_status(&out,reply("1","true","false","true","[]",subs)));
    CHECK(out.subscription_count==MAX_SUBSCRIPTIONS+1&&!vpn_can_update_subscriptions(&out)&&!out.subscriptions[0][0]);
    snprintf(many, sizeof many, "[{\"id\":\"%s\",\"name\":\"One\",\"active\":false},{\"id\":\"%s\",\"name\":\"Two\",\"active\":false}]", id, id);
    reject(reply("1", "true", "false", "true", many, ""));
    snprintf(many, sizeof many, "[{\"id\":\"%s\",\"name\":\"One\",\"active\":true},{\"id\":\"11234567-89ab-cdef-0123-456789abcdef\",\"name\":\"Two\",\"active\":true}]", id);
    reject(reply("1", "true", "false", "true", many, ""));

    CHECK(vpn_parse_status(&out, reply("1", "true", "false", "true", "[]", ",\"ssid\":123,\"ssid_2g\":\"bad\\nname\",\"ssid_5g\":\"01234567890123456789012345678901234\"")));
    CHECK(!out.ssid[0] && !out.ssid_2g[0] && !out.ssid_5g[0]);
    CHECK(vpn_parse_status(&out, reply("1", "true", "false", "true", "[]", ",\"ssid\":\"01234567890123456789012345678901\"")));
    CHECK(strlen(out.ssid) == 32);
    snprintf(many, sizeof many, "%s {}", reply("1", "true", "false", "true", "[]", "")); reject(many);
    snprintf(many, sizeof many, "%sPRIVATE", reply("1", "true", "false", "true", "[]", "")); reject(many);
    CHECK(!vpn_parse_status(NULL, "{}"));

    CHECK(!strcmp(vpn_error_code("{\"ok\":false,\"code\":\"VPN_BUSY\"}"), "VPN_BUSY"));
    CHECK(!strcmp(vpn_error_code("{\"ok\":false,\"code\":\"VPN_WIFI_SETTINGS_PENDING\"}"), "VPN_WIFI_SETTINGS_PENDING"));
    const char *ipa_errors[] = {"VPN_IPA_ENABLED", "VPN_IPA_UNSUPPORTED", "VPN_IPA_NOT_RUNNING", "VPN_IPA_PREPARE_FAILED", "VPN_IPA_RESTORE_FAILED", "VPN_IPA_STATE_INVALID"};
    for (unsigned i = 0; i < sizeof ipa_errors / sizeof ipa_errors[0]; i++) {
        snprintf(many, sizeof many, "{\"ok\":false,\"code\":\"%s\"}", ipa_errors[i]);
        CHECK(!strcmp(vpn_error_code(many), ipa_errors[i]));
        for (int ru = 0; ru < 2; ru++) {
            CHECK(strcmp(vpn_error_text(ipa_errors[i], ru), vpn_error_text("VPN_OPERATION_FAILED", ru)) != 0);
            CHECK(strcmp(vpn_error_text(ipa_errors[i], ru), vpn_error_text("VPN_RESULT_UNKNOWN", ru)) != 0);
        }
    }
    const char *unknown[] = {"{\"ok\":false}", "{\"ok\":false,\"code\":null}", "{\"ok\":false,\"code\":123}",
        "{\"ok\":false,\"code\":\"VPN_PRIVATE_CANARY\"}", "{\"ok\":false,\"code\":\"PRIVATE\\nsecond line\"}",
        "{\"ok\":false,\"code\":\"VPN_RESULT_UNKNOWN\"}", "{\"ok\":false,\"code\":\"VPN_SPX_PRESERVED\"}"};
    for (unsigned i = 0; i < sizeof unknown / sizeof unknown[0]; i++) CHECK(!strcmp(vpn_error_code(unknown[i]), "VPN_OPERATION_FAILED"));
    const char *not_error[] = {NULL, "", "not JSON", "[]", "{}", "{\"ok\":true}", "{\"ok\":0}",
        "{\"ok\":null}", "{\"ok\":\"false\"}", "{\"ok\":false} {}", "{\"ok\":false} garbage",
        "{\"ok\":false,\"code\":\"VPN_BUSY\\u0000private\"}"};
    for (unsigned i = 0; i < sizeof not_error / sizeof not_error[0]; i++) CHECK(vpn_error_code(not_error[i]) == NULL);
    for (int ru = 0; ru < 2; ru++) {
        CHECK(!strcmp(vpn_error_text("VPN_PRIVATE_CANARY", ru), vpn_error_text("VPN_OPERATION_FAILED", ru)));
        CHECK(!strcmp(vpn_error_text(NULL, ru), vpn_error_text("VPN_OPERATION_FAILED", ru)));
        CHECK(!strstr(vpn_error_text("PRIVATE\nsecond line", ru), "PRIVATE"));
        CHECK(strcmp(vpn_error_text("VPN_RESULT_UNKNOWN", ru), vpn_error_text("VPN_INVALID_STATUS", ru)) != 0);
        CHECK(*vpn_error_text("VPN_BUSY", ru));
    }
    batch_tests();
    printf("VPN model: %u checks passed; strict status, atomic snapshots and fixed RU/EN errors\n", checks);
    return 0;
}
