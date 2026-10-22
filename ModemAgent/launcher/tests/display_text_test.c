#include "../display-text.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned tests;
static void expect(const char *source, const char *expected) {
    char actual[1024];
    display_text_name(source, actual, sizeof actual);
    if (strcmp(actual, expected)) fprintf(stderr,"expected <%s>, got <%s>\n",expected,actual);
    assert(!strcmp(actual, expected));
    ++tests;
}
/* Independent strict validator, including overlongs, surrogates and truncation. */
static int valid_utf8(const unsigned char *p) {
    while (*p) {
        if (*p < 0x80) { ++p; continue; }
        if (*p >= 0xc2 && *p <= 0xdf) {
            if (p[1] < 0x80 || p[1] > 0xbf) return 0;
            p += 2; continue;
        }
        if (*p >= 0xe0 && *p <= 0xef) {
            unsigned char lo = *p == 0xe0 ? 0xa0 : 0x80, hi = *p == 0xed ? 0x9f : 0xbf;
            if (p[1] < lo || p[1] > hi || p[2] < 0x80 || p[2] > 0xbf) return 0;
            p += 3; continue;
        }
        if (*p >= 0xf0 && *p <= 0xf4) {
            unsigned char lo = *p == 0xf0 ? 0x90 : 0x80, hi = *p == 0xf4 ? 0x8f : 0xbf;
            if (p[1] < lo || p[1] > hi || p[2] < 0x80 || p[2] > 0xbf || p[3] < 0x80 || p[3] > 0xbf) return 0;
            p += 4; continue;
        }
        return 0;
    }
    return 1;
}
int main(void) {
    expect("UserGate", "UserGate");
    expect("Москва · Резерв — 25 Мбит/с", "Москва · Резерв — 25 Мбит/с");
    expect("München São Paulo 東京", "München São Paulo 東京");
    expect("🇩🇪 Frankfurt 🇺🇸 New York 🇷🇺 Москва 🇯🇵 東京", "[DE] Frankfurt [US] New York [RU] Москва [JP] 東京");
    expect("🇳🇱🇸🇬🇬🇧🇭🇰🇰🇷", "[NL][SG][GB][HK][KR]");
    expect("🇦 end 🇿", "[*] end [*]");
    expect("🚀 Fast ⚡ Turbo 🔒 Private 💎 VIP ✅ Ready", "[fast] Fast [fast] Turbo [lock] Private [VIP] VIP [OK] Ready");
    expect("🛡️ Safe ❤️ Favorite ℹ️ Info", "[shield] Safe [heart] Favorite [i] Info");
    expect("↔️ ↩️ ↪️ ⤴️ ⤵️ 〰️ 〽️ ㊗️ ㊙️", "<-> <- -> [up] [down] ~ [mark] [congrats] [secret]");
    expect("👨‍👩‍👧‍👦 Family 🧑🏽‍💻 Work 🏳️‍🌈 Rainbow", "[*] Family [*] Work [*] Rainbow");
    expect("👍🏻👍🏿 🦄", "[*][*] [*]");
    expect("🏴\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f Name", "[*] Name");
    expect("1️⃣ #️⃣ *️⃣ 9 1\ufe0f", "[1] [#] [*] 9 1");
    expect("𝗚𝗲𝗿𝗺𝗮𝗻𝘆 𝟭 𝙁𝙖𝙨𝙩 𝔸𝔹ℂ ＵＳＡ Ⓐⓑ", "Germany 1 Fast ABℂ USA Ab");
    expect("VPN\u202e123\u202c\u200b\u2066A\u2069", "VPN123A");
    expect("A\tB\rC\u00a0D\u2009E\u202fF\u3000G", "A B C D E F G");
    expect("2.4G: 🇩🇪 Home\n5G: VPN", "2.4G: [DE] Home\n5G: VPN");
    expect("A\u2028B\u2029C", "A\nB\nC");
    expect("A\1\177B", "AB");
    expect("bad \xc0\xaf \xed\xa0\x80 \xf4\x90\x80\x80 \xf0\x9f", "bad [?][?] [?][?][?] [?][?][?][?] [?][?]");
    expect("\ue123 \U00010000", "[*] [*]");
    expect("🚀‍Berlin", "[fast]Berlin");
    expect(NULL, "");

    char tiny[8];
    display_text_name("abc",tiny,4); assert(!strcmp(tiny,"abc"));
    display_text_name("abcdef",tiny,5); assert(!strcmp(tiny,"a..."));
    display_text_name("🇩🇪abc",tiny,6); assert(!strcmp(tiny,"..."));
    display_text_name("яяяя",tiny,8); assert(!strcmp(tiny,"яя..."));
    display_text_name("🚀more",tiny,8); assert(!strcmp(tiny,"..."));
    display_text_name("a",tiny,1); assert(!tiny[0]);
    tiny[0]='X';display_text_name("a",tiny,0);assert(tiny[0]=='X');
    display_text_name("a",NULL,20);
    tests += 8;

    /* Every byte boundary of a long mixed name is safe and deterministic.
     * No profile ID/name is changed: source is checked byte for byte. */
    char original[] = "🇩🇪 Berlin 👨‍👩‍👧‍👦 Москва 🔥 𝗙𝗮𝘀𝘁 日本";
    char before[sizeof original];memcpy(before,original,sizeof original);
    for (size_t cap=0;cap<160;++cap) {
        unsigned char storage[192];memset(storage,0xa5,sizeof storage);
        display_text_name(original,(char*)storage+8,cap);
        for(size_t n=0;n<8;++n)assert(storage[n]==0xa5);
        for(size_t n=8+cap;n<sizeof storage;++n)assert(storage[n]==0xa5);
        if(cap) { assert(memchr(storage+8,0,cap));assert(valid_utf8(storage+8)); }
        assert(!memcmp(original,before,sizeof original));
        ++tests;
    }
    /* Synthetic hostile input, including all lead/continuation byte values. */
    uint32_t random=0x12345678;
    for(unsigned n=0;n<30000;++n) {
        char source[65];unsigned char destination[160];
        size_t length=n%64,cap=n%128;
        for(size_t i=0;i<length;++i) { random=random*1664525u+1013904223u;source[i]=(char)(random>>24); }
        source[length]=0;
        memset(destination,0xa5,sizeof destination);
        display_text_name(source,(char*)destination+8,cap);
        if(cap) {assert(memchr(destination+8,0,cap));assert(valid_utf8(destination+8));}
        for(size_t i=0;i<8;++i)assert(destination[i]==0xa5);
        for(size_t i=8+cap;i<sizeof destination;++i)assert(destination[i]==0xa5);
        ++tests;
    }
    printf("display text: %u synthetic checks passed\n",tests);
    return 0;
}
