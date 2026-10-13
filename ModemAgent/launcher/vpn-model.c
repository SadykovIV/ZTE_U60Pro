#include "vpn-model.h"
#include "backend.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* These cJSON entry points are already exported by the pinned stock UI. */
typedef struct cJSON cJSON;
extern cJSON *cJSON_ParseWithOpts(const char *, const char **, int);
extern cJSON *cJSON_GetObjectItemCaseSensitive(const cJSON *, const char *);
extern cJSON *cJSON_GetArrayItem(const cJSON *, int);
extern int cJSON_GetArraySize(const cJSON *);
extern int cJSON_IsObject(const cJSON *), cJSON_IsArray(const cJSON *);
extern int cJSON_IsBool(const cJSON *), cJSON_IsTrue(const cJSON *);
extern int cJSON_IsNumber(const cJSON *);
extern char *cJSON_GetStringValue(const cJSON *), *cJSON_PrintUnformatted(const cJSON *);
extern void cJSON_Delete(cJSON *), cJSON_free(void *);

static cJSON *get(cJSON *o, const char *key) { return cJSON_GetObjectItemCaseSensitive(o, key); }
static int equal(const char *a, const char *b) { return a && !strcmp(a, b); }
static int uuid(const char *s) {
    if (!s || strlen(s) != 36) return 0;
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return 0; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    }
    return 1;
}
/* cJSON strings have no length API; reject escaped NUL before it can truncate
 * an identifier/name. A literal escaped backslash followed by u0000 is fine. */
static cJSON *parse(const char *json) {
    if (!json) return NULL;
    for (const char *p = json; *p; p++) {
        if (*p == '\\') {
            if (!strncmp(p + 1, "u0000", 5)) return NULL;
            if (p[1]) p++;
        }
    }
    return cJSON_ParseWithOpts(json, NULL, 1);
}
static int safe_text(const char *s, size_t limit, int allow_empty) {
    if (!s || (!allow_empty && !*s) || strlen(s) > limit) return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (*p < 32 || *p == 127) return 0;
    return 1;
}
static void ssid(char out[33], cJSON *data, const char *key) {
    const char *s = cJSON_GetStringValue(get(data, key));
    if (safe_text(s, 32, 1)) memcpy(out, s, strlen(s) + 1);
}
static int schema_one(cJSON *data) {
    cJSON *value = get(data, "schema_version");
    if (!cJSON_IsNumber(value)) return 0;
    char *number = cJSON_PrintUnformatted(value);
    int ok = equal(number, "1");
    cJSON_free(number);
    return ok;
}
int vpn_parse_status(struct snapshot *out, const char *json) {
    if (!out) return 0;
    cJSON *root = parse(json);
    if (!root) return 0;
    int ok = 0, active = 0;
    struct snapshot *next = calloc(1, sizeof *next);
    if (!next) { cJSON_Delete(root); return 0; }
    cJSON *data = get(root, "data"), *profiles = get(data, "profiles");
    if (!cJSON_IsObject(root) || !cJSON_IsBool(get(root, "ok")) ||
        !cJSON_IsTrue(get(root, "ok")) || !cJSON_IsObject(data) || !schema_one(data) ||
        !cJSON_IsBool(get(data, "enabled")) || !cJSON_IsBool(get(data, "core_running")) ||
        !cJSON_IsBool(get(data, "network_ok")) || !cJSON_IsArray(profiles)) goto done;
    next->count = cJSON_GetArraySize(profiles);
    if (next->count < 0 || next->count > MAX_PROFILES) goto done;
    for (int i = 0; i < next->count; i++) {
        cJSON *profile = cJSON_GetArrayItem(profiles, i);
        const char *id = cJSON_GetStringValue(get(profile, "id"));
        const char *name = cJSON_GetStringValue(get(profile, "name"));
        if (!cJSON_IsObject(profile) || !uuid(id) || !safe_text(name, 256, 0) ||
            !cJSON_IsBool(get(profile, "active"))) goto done;
        for (int j = 0; j < i; j++) if (!strcmp(next->profiles[j].id, id)) goto done;
        next->profiles[i].active = cJSON_IsTrue(get(profile, "active"));
        if (next->profiles[i].active && ++active > 1) goto done;
        cJSON *warnings = get(profile, "warnings");
        /* Older controllers omit warnings (or return null). Only known warning
         * literals affect the display; raw provider text never reaches it. */
        if (cJSON_IsArray(warnings)) for (int j = 0; j < cJSON_GetArraySize(warnings); j++)
            if (equal(cJSON_GetStringValue(cJSON_GetArrayItem(warnings,j)), "VPN_INSECURE_TLS")) next->profiles[i].insecure_tls = 1;
        memcpy(next->profiles[i].id, id, 37);
        memcpy(next->profiles[i].name, name, strlen(name) + 1);
    }
    cJSON *subscriptions = get(data, "subscriptions");
    if (subscriptions) {
        if (!cJSON_IsArray(subscriptions)) goto done;
        next->subscription_count = cJSON_GetArraySize(subscriptions);
        if (next->subscription_count < 0) goto done;
        /* Keep the rest of status usable; the UI explicitly reports overflow
         * and cannot dispatch a partial subscription list. */
        for (int i = 0; next->subscription_count <= MAX_SUBSCRIPTIONS && i < next->subscription_count; i++) {
            cJSON *entry = cJSON_GetArrayItem(subscriptions,i);
            const char *id = cJSON_GetStringValue(get(entry,"id"));
            if (!cJSON_IsObject(entry) || !uuid(id)) goto done;
            for (int j = 0; j < i; j++) if (!strcmp(next->subscriptions[j],id)) goto done;
            memcpy(next->subscriptions[i],id,37);
        }
    }
    next->enabled = cJSON_IsTrue(get(data, "enabled"));
    next->running = cJSON_IsTrue(get(data, "core_running"));
    next->network_ok = cJSON_IsTrue(get(data, "network_ok"));
    ssid(next->ssid, data, "ssid"); ssid(next->ssid_2g, data, "ssid_2g"); ssid(next->ssid_5g, data, "ssid_5g");
    out->enabled = next->enabled; out->running = next->running; out->network_ok = next->network_ok;
    out->count = next->count;
    out->subscription_count = next->subscription_count;
    memcpy(out->subscriptions,next->subscriptions,sizeof out->subscriptions);
    memcpy(out->profiles, next->profiles, sizeof out->profiles);
    memcpy(out->ssid, next->ssid, sizeof out->ssid);
    memcpy(out->ssid_2g, next->ssid_2g, sizeof out->ssid_2g);
    memcpy(out->ssid_5g, next->ssid_5g, sizeof out->ssid_5g);
    out->valid = 1;
    ok = 1;
done:
    cJSON_Delete(root);
    free(next);
    return ok;
}

struct error_text { const char *code, *ru, *en; };
/* Controller error literals only. Fixture environment names and warnings are
 * deliberately absent; no card, process or server text is displayed. */
static const struct error_text errors[] = {
    {"VPN_SUBSCRIPTION_FILE_REFERENCE", "Профиль ссылается на файл устройства. Используйте встроенные ключи.", "Profile references a device file. Use inline keys."},
    {"VPN_REQUEST_TOO_LARGE", "Слишком большой запрос. Разделите импорт.", "Request is too large. Split the import."},
    {"VPN_SUBSCRIPTION_EXISTS", "Такая подписка уже добавлена.", "This subscription is already saved."},
    {"VPN_DHCP_NOT_READY", "Служба адресов и DNS сети VPN не запустилась.", "VPN DHCP and DNS service did not start."},
    {"VPN_PROFILE_NOT_FOUND", "Профиль не найден. Обновите список.", "Profile was not found. Refresh the list."},
    {"VPN_UNSUPPORTED_PROTOCOL", "Протокол профиля не поддерживается.", "This profile protocol is not supported."},
    {"VPN_IPV6_GUEST_DISABLED", "IPv6 для сети VPN сейчас не поддерживается.", "IPv6 is not supported for VPN Wi-Fi yet."},
    {"VPN_SUBSCRIPTION_DOCUMENT", "Содержимое подписки не распознано.", "The subscription document was not recognized."},
    {"VPN_SUBSCRIPTION_EMPTY", "В подписке нет подходящих профилей.", "No supported profiles were found in the subscription."},
    {"VPN_SUBSCRIPTION_ENTRY", "Профиль из подписки отклонён.", "A subscription profile was rejected."},
    {"VPN_SUBSCRIPTION_FETCH", "Не удалось загрузить подписку.", "Could not download the subscription."},
    {"VPN_SUBSCRIPTION_FORMAT", "Формат подписки не поддерживается.", "The subscription format is not supported."},
    {"VPN_SUBSCRIPTION_NOT_FOUND", "Подписка не найдена. Обновите список.", "Subscription was not found. Refresh the list."},
    {"VPN_SUBSCRIPTION_ROUTING", "Маршрутизация подписки не поддерживается.", "Subscription routing is not supported."},
    {"VPN_SUBSCRIPTION_URL", "Проверьте адрес подписки в программе.", "Check the subscription URL in the desktop app."},
    {"VPN_AWG_DUPLICATE_OPTION", "В конфигурации AWG повторяется параметр.", "An AWG configuration option is duplicated."},
    {"VPN_AWG_DUPLICATE_PEER", "В конфигурации AWG повторяется сервер.", "An AWG peer is duplicated."},
    {"VPN_AWG_HEADER_PADDING_REQUIRED", "В AWG не заданы параметры заголовков.", "AWG header padding parameters are required."},
    {"VPN_AWG_INVALID_ADDRESS", "Проверьте адрес интерфейса AWG.", "Check the AWG interface address."},
    {"VPN_AWG_INVALID_BOOLEAN", "Некорректный переключатель в конфигурации AWG.", "An AWG boolean setting is invalid."},
    {"VPN_AWG_INVALID_CONFIG", "Некорректная конфигурация AWG.", "The AWG configuration is invalid."},
    {"VPN_AWG_INVALID_DNS", "Проверьте DNS в конфигурации AWG.", "Check the DNS addresses in the AWG configuration."},
    {"VPN_AWG_INVALID_ENDPOINT", "Проверьте адрес сервера AWG.", "Check the AWG server endpoint."},
    {"VPN_AWG_INVALID_JUNK_SIZE", "Проверьте размеры пакетов маскировки AWG.", "Check the AWG junk packet sizes."},
    {"VPN_AWG_INVALID_KEY", "Проверьте ключи конфигурации AWG.", "Check the keys in the AWG configuration."},
    {"VPN_AWG_INVALID_LIST", "Некорректный список в конфигурации AWG.", "A list in the AWG configuration is invalid."},
    {"VPN_AWG_INVALID_MTU", "Проверьте MTU в конфигурации AWG.", "Check the MTU in the AWG configuration."},
    {"VPN_AWG_INVALID_NUMBER", "Некорректное число в конфигурации AWG.", "A number in the AWG configuration is invalid."},
    {"VPN_AWG_INVALID_RANGE", "Некорректный диапазон в конфигурации AWG.", "A range in the AWG configuration is invalid."},
    {"VPN_AWG_INVALID_SECTION", "Некорректный раздел конфигурации AWG.", "An AWG configuration section is invalid."},
    {"VPN_AWG_INVALID_SIGNATURE", "Проверьте сигнатуры маскировки AWG.", "Check the AWG obfuscation signatures."},
    {"VPN_AWG_IPV4_ADDRESS_REQUIRED", "В AWG требуется адрес IPv4.", "An IPv4 address is required for AWG."},
    {"VPN_AWG_IPV6_ADDRESS_REQUIRED", "В AWG требуется адрес IPv6.", "An IPv6 address is required for AWG."},
    {"VPN_AWG_MISSING_FIELD", "В конфигурации AWG не хватает параметра.", "A required AWG setting is missing."},
    {"VPN_AWG_MULTIPLE_LOCAL_ADDRESSES", "Несколько адресов AWG не поддерживаются.", "Multiple AWG interface addresses are not supported."},
    {"VPN_AWG_OVERLAPPING_HEADERS", "Диапазоны заголовков AWG пересекаются.", "AWG header ranges overlap."},
    {"VPN_AWG_OVERLAPPING_PEERS", "Маршруты серверов AWG пересекаются.", "AWG peer routes overlap."},
    {"VPN_AWG_PEER_KEEPALIVE_DIFFERS", "Периоды keepalive серверов AWG различаются.", "AWG peers use different keepalive intervals."},
    {"VPN_AWG_SIGNATURE_TOO_LARGE", "Сигнатура AWG слишком большая.", "An AWG signature is too large."},
    {"VPN_AWG_UNSUPPORTED_OPTION", "Параметр AWG не поддерживается.", "An AWG setting is not supported."},
    {"VPN_BUSY", "Другая операция выполняется. Повторите позже.", "Another operation is running. Try again later."},
    {"VPN_OTHER_TRANSACTION", "Сначала завершите текущую настройку.", "Finish the pending setup first."},
    {"VPN_DEVICE_CHANGED", "Устройство изменилось. Обновите состояние.", "Device changed. Refresh the status."},
    {"VPN_ROOT_REQUIRED", "Недостаточно прав для операции.", "Root permission is required."},
    {"VPN_NOT_INSTALLED", "Установите компоненты VPN в программе.", "Install VPN components in the desktop app."},
    {"VPN_INTEGRITY", "Компоненты VPN требуют проверки.", "VPN components need verification."},
    {"VPN_CORE_INTEGRITY", "Ядро VPN не прошло проверку.", "VPN core integrity check failed."},
    {"VPN_UNSAFE_FILE", "Файлы VPN требуют проверки.", "VPN file safety check failed."},
    {"VPN_FILE_UNAVAILABLE", "Файл VPN недоступен.", "A VPN file is unavailable."},
    {"VPN_UNSUPPORTED_FIRMWARE", "Эта прошивка не поддерживается.", "This firmware is not supported."},
    {"VPN_OPERATION_FAILED", "Операция VPN не подтверждена.", "VPN operation was not confirmed."},
    {"VPN_OPERATION_TIMEOUT", "Операция не подтверждена. Обновите состояние.", "Operation timed out. Refresh the status."},
    {"VPN_WRITE_FAILED", "Запись не подтверждена. Обновите состояние.", "Write failed. Refresh the status."},
    {"VPN_AUDIT_FAILED", "Не удалось сохранить журнал операции.", "Could not save the operation journal."},
    {"VPN_INVALID_STATE", "Состояние VPN требует проверки.", "VPN state needs verification."},
    {"VPN_INVALID_REQUEST", "Команда VPN отклонена.", "VPN request was rejected."},
    {"VPN_INVALID_PATH", "Путь VPN отклонён.", "VPN path was rejected."},
    {"VPN_PENDING_CHANGES", "Сначала завершите изменения VPN.", "Finish pending VPN changes first."},
    {"VPN_CONFIGURATION_PENDING", "Настройка VPN ещё не завершена.", "VPN configuration is still pending."},
    {"VPN_NETWORK_INIT_CHANGED", "Настройки запуска сети изменились.", "Network startup configuration changed."},
    {"VPN_CORE_NOT_READY", "Ядро VPN ещё не готово.", "VPN core is not ready."},
    {"VPN_BRIDGE_NOT_READY", "Сетевой мост ещё не готов.", "Network bridge is not ready."},
    {"VPN_NO_ACTIVE_PROFILE", "Сначала выберите профиль VPN.", "Select a VPN profile first."},
    {"VPN_INVALID_PROFILE_ID", "Профиль не найден. Обновите список.", "Profile was not found. Refresh the list."},
    {"VPN_ACTIVE_PROFILE_DELETE", "Сначала переключите активный профиль.", "Switch the active profile before deleting it."},
    {"VPN_PROFILE_EXISTS", "Такой профиль уже существует.", "This profile already exists."},
    {"VPN_PROFILE_LIMIT", "Достигнут предел числа профилей.", "The profile limit has been reached."},
    {"VPN_PROFILE_TOO_LARGE", "Профиль превышает допустимый размер.", "The profile is too large."},
    {"VPN_VALIDATION_FAILED", "Ядро VPN отклонило профиль.", "VPN core rejected the profile."},
    {"VPN_GUEST_IN_USE", "Гостевая сеть уже используется.", "The guest network is already in use."},
    {"VPN_MESH_CONFLICT", "Сначала выключите Mesh.", "Turn off Mesh first."},
    {"VPN_IPA_ENABLED", "Обновите компоненты VPN: требуется подготовка IPA.", "Update VPN components to prepare IPA automatically."},
    {"VPN_IPA_UNSUPPORTED", "Компоненты ускорения IPA не распознаны.", "IPA acceleration components are not recognized."},
    {"VPN_IPA_NOT_RUNNING", "Служба ускорения IPA не запущена.", "The IPA acceleration service is not running."},
    {"VPN_IPA_PREPARE_FAILED", "Не удалось отключить ускорение IPA для VPN.", "Could not disable IPA acceleration for VPN."},
    {"VPN_IPA_RESTORE_FAILED", "Не удалось восстановить настройки IPA. Сохраните журнал.", "Could not restore IPA settings. Save the log."},
    {"VPN_IPA_STATE_INVALID", "Настройки или резервная копия IPA требуют проверки.", "IPA settings or their backup need verification."},
    {"VPN_OTHER_PROXY", "Другое ядро прокси уже работает.", "Another proxy core is running."},
    {"VPN_SUBNET_CONFLICT", "Подсеть VPN уже занята.", "The VPN subnet is already in use."},
    {"VPN_ROUTE_CONFLICT", "Маршрут VPN конфликтует с текущим.", "The VPN route conflicts with an existing route."},
    {"VPN_WIFI_NOT_CONFIGURED", "Сначала настройте Wi-Fi с VPN.", "Configure VPN Wi-Fi first."},
    {"VPN_WIFI_NOT_READY", "Wi-Fi с VPN не запустился.", "VPN Wi-Fi did not start."},
    {"VPN_WIFI_CONFIGURATION_CHANGED", "Настройки Wi-Fi изменились. Обновите состояние.", "Wi-Fi settings changed. Refresh the status."},
    {"VPN_WIFI_SETTINGS_PENDING", "Завершите сохранение настроек Wi-Fi.", "Finish saving the Wi-Fi settings."},
    {"VPN_WIFI_SETTINGS_ENABLED", "Сначала выключите Wi-Fi с VPN.", "Turn off VPN Wi-Fi first."},
    {"VPN_INVALID_WIFI_SSID", "Проверьте название Wi-Fi в программе.", "Check the Wi-Fi name in the desktop app."},
    {"VPN_INVALID_WIFI_PASSWORD", "Проверьте пароль Wi-Fi в программе.", "Check the Wi-Fi password in the desktop app."},
    {"VPN_INVALID_WIFI_SETTINGS", "Проверьте настройки Wi-Fi в программе.", "Check Wi-Fi settings in the desktop app."},
    {"VPN_LAUNCHER_NOT_INSTALLED", "Установите страницы экрана в программе.", "Install modem pages in the desktop app."},
    {"VPN_LAUNCHER_NOT_READY", "Экран модема ещё не готов.", "The modem screen is not ready."},
    {"VPN_LAUNCHER_PAGE_CONFIG_INVALID", "Проверьте порядок страниц в программе.", "Check the page layout in the desktop app."},
    {"VPN_LAUNCHER_PAGE_NOT_INSTALLED", "Эта страница не включена.", "This page is not enabled."},
    {"VPN_VLESS_ONLY", "Требуется ссылка VLESS или Hysteria2.", "A VLESS or Hysteria2 link is required."},
    {"VPN_INVALID_URI", "Проверьте ссылку профиля в программе.", "Check the profile link in the desktop app."},
    {"VPN_INVALID_UUID", "Проверьте идентификатор профиля.", "Check the profile identifier."},
    {"VPN_INVALID_NAME", "Проверьте имя профиля.", "Check the profile name."},
    {"VPN_INVALID_SERVER", "Проверьте адрес сервера профиля.", "Check the profile server address."},
    {"VPN_INVALID_PORT", "Проверьте порт сервера профиля.", "Check the profile server port."},
    {"VPN_INVALID_KEY", "Проверьте параметры шифрования профиля.", "Check the profile encryption settings."},
    {"VPN_INVALID_EXTRA", "Проверьте дополнительные параметры профиля.", "Check the additional profile settings."},
    {"VPN_CONFLICTING_OPTION", "Параметры профиля несовместимы.", "Profile settings conflict."},
    {"VPN_DUPLICATE_OPTION", "В профиле повторяется параметр.", "A profile setting is duplicated."},
    {"VPN_UNSUPPORTED_OPTION", "Параметр профиля не поддерживается.", "A profile setting is not supported."},
    {"VPN_UNSUPPORTED_ENCRYPTION", "Шифрование профиля не поддерживается.", "Profile encryption is not supported."},
    {"VPN_UNSUPPORTED_SECURITY", "Защита профиля не поддерживается.", "Profile security is not supported."},
    {"VPN_UNSUPPORTED_TRANSPORT", "Транспорт профиля не поддерживается.", "Profile transport is not supported."}
};
static const struct error_text *known_error(const char *code) {
    for (unsigned i = 0; i < sizeof errors / sizeof errors[0]; i++)
        if (equal(code, errors[i].code)) return &errors[i];
    return NULL;
}
const char *vpn_error_code(const char *json) {
    cJSON *root = parse(json);
    if (!root) return NULL;
    const char *result = NULL;
    if (cJSON_IsObject(root) && cJSON_IsBool(get(root, "ok")) && !cJSON_IsTrue(get(root, "ok"))) {
        const struct error_text *entry = known_error(cJSON_GetStringValue(get(root, "code")));
        result = entry ? entry->code : "VPN_OPERATION_FAILED";
    }
    cJSON_Delete(root);
    return result;
}
const char *vpn_error_text(const char *code, int ru) {
    if (equal(code, "VPN_RESULT_UNKNOWN"))
        return ru ? "Результат не подтверждён. Обновите состояние." : "Result is unknown. Refresh the status.";
    if (equal(code, "VPN_INVALID_STATUS"))
        return ru ? "Не удалось проверить ответ VPN. Обновите состояние." : "Could not verify VPN status. Refresh the status.";
    const struct error_text *entry = known_error(code);
    if (!entry) entry = known_error("VPN_OPERATION_FAILED");
    return ru ? entry->ru : entry->en;
}

const char *vpn_warning_text(const char *code,int ru) {
    if (equal(code,"VPN_INSECURE_TLS")) return ru ? "TLS: проверка выключена" : "TLS verification is off";
    if (equal(code,"VPN_SPX_PRESERVED")) return ru ? "Параметр spx сохранён" : "The spx option was preserved";
    return NULL;
}
int vpn_can_update_subscriptions(const struct snapshot *s) {
    return s && s->valid && !s->busy && s->subscription_count > 0 && s->subscription_count <= MAX_SUBSCRIPTIONS;
}
static const char *fixed_code(const char *code) {
    if (equal(code,"VPN_RESULT_UNKNOWN") || equal(code,"VPN_INVALID_STATUS")) return code;
    const struct error_text *entry=known_error(code);
    return entry ? entry->code : "VPN_OPERATION_FAILED";
}
int vpn_update_subscriptions(struct snapshot *s,vpn_request_fn request,vpn_progress_fn progress,void *context) {
    if (!s || !request || !s->valid || s->subscription_count <= 0 || s->subscription_count > MAX_SUBSCRIPTIONS) return 0;
    int total=s->subscription_count;
    char (*ids)[37]=malloc((size_t)total*sizeof *ids);
    if (!ids) return 0;
    memcpy(ids,s->subscriptions,(size_t)total*sizeof *ids);
    memset(&s->subscription_update,0,sizeof s->subscription_update);
    s->subscription_update.total=total;s->subscription_update.running=1;
    for (int i=0;i<total;i++) {
        if (progress) progress(context,s);
        char input[100];snprintf(input,sizeof input,"{\"action\":\"subscription_update\",\"id\":\"%s\"}",ids[i]);
        const char *code=NULL;
        if (request(context,s,input,&code)) s->subscription_update.succeeded++;
        else if (!s->subscription_update.first_error[0]) snprintf(s->subscription_update.first_error,sizeof s->subscription_update.first_error,"%s",fixed_code(code));
        s->subscription_update.done++;
    }
    free(ids);
    if (progress) progress(context,s);
    const char *code=NULL;int ok=request(context,s,"{\"action\":\"status\"}",&code);
    snprintf(s->error_code,sizeof s->error_code,"%s",ok?"":fixed_code(code));
    s->operation_error[0]=0;
    if (!ok) s->valid=0;
    s->subscription_update.running=0;s->subscription_update.complete=1;
    return 1;
}
void vpn_subscription_text(const struct snapshot *s,int ru,char *out,size_t size) {
    const struct subscription_update *u=&s->subscription_update;
    if (u->running) {
        if (u->done < u->total) snprintf(out,size,ru?"Обновление подписок %d/%d…":"Updating subscriptions %d/%d…",u->done+1,u->total);
        else snprintf(out,size,"%s",ru?"Проверка результата…":"Checking the result…");
    } else if (u->complete) {
        int failures=u->total-u->succeeded;
        const char *code=s->error_code[0]?s->error_code:failures?u->first_error:NULL;
        snprintf(out,size,ru?"Обновлено %d/%d · ошибок %d%s%s":"Updated %d/%d · errors %d%s%s",u->succeeded,u->total,failures,
            code?"\n":"",code?fixed_code(code):"");
    } else if (size) out[0]=0;
}
