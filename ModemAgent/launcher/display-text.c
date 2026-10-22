#include "display-text.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* The launcher deliberately uses only its already audited stock font API.
 * These substitutions therefore work on all three supported UI ABIs without
 * assuming an LVGL font structure or installing/replacing a vendor font. */
static uint32_t next(const char **input) {
    const unsigned char *p = (const unsigned char *)*input;
    uint32_t value;
    unsigned count;
    if (*p < 0x80) { if (*p) ++*input; return *p; }
    if (*p >= 0xc2 && *p <= 0xdf) { value = *p & 0x1f; count = 2; }
    else if (*p >= 0xe0 && *p <= 0xef) { value = *p & 0x0f; count = 3; }
    else if (*p >= 0xf0 && *p <= 0xf4) { value = *p & 7; count = 4; }
    else { ++*input; return 0xfffd; }
    for (unsigned i = 1; i < count; ++i) {
        if ((p[i] & 0xc0) != 0x80) { ++*input; return 0xfffd; }
        value = (value << 6) | (p[i] & 0x3f);
    }
    if ((count == 3 && value < 0x800) || (count == 4 && value < 0x10000) ||
        (value >= 0xd800 && value <= 0xdfff) || value > 0x10ffff) {
        ++*input; return 0xfffd;
    }
    *input += count;
    return value;
}
static uint32_t peek(const char *input) { return next(&input); }
static int regional(uint32_t c) { return c >= 0x1f1e6 && c <= 0x1f1ff; }
static int extension(uint32_t c) {
    return c == 0xfe0e || c == 0xfe0f || (c >= 0x1f3fb && c <= 0x1f3ff) ||
           (c >= 0xe0020 && c <= 0xe007f) || (c >= 0xe0100 && c <= 0xe01ef);
}
static int pictograph(uint32_t c) {
    return (c >= 0x1f000 && c <= 0x1faff) || (c >= 0x2300 && c <= 0x23ff) ||
           (c >= 0x2600 && c <= 0x27ff) || (c >= 0x2b00 && c <= 0x2bff) ||
           (c >= 0x2190 && c <= 0x2199) || c == 0x21a9 || c == 0x21aa ||
           c == 0x2934 || c == 0x2935 || c == 0x3030 || c == 0x303d ||
           c == 0x3297 || c == 0x3299 || c == 0xa9 || c == 0xae ||
           c == 0x203c || c == 0x2049 || c == 0x2122 || c == 0x2139;
}
static const char *pictograph_text(uint32_t c) {
    switch (c) {
    case 0x1f680: case 0x26a1: return "[fast]";
    case 0x1f525: return "[hot]";
    case 0x2b50: case 0x1f31f: case 0x2728: return "[star]";
    case 0x2705: case 0x2713: case 0x2714: return "[OK]";
    case 0x274c: case 0x274e: case 0x2716: return "[X]";
    case 0x1f512: case 0x1f510: case 0x1f50f: return "[lock]";
    case 0x1f513: return "[open]";
    case 0x1f310: return "[web]";
    case 0x1f30d: case 0x1f30e: case 0x1f30f: return "[world]";
    case 0x1f4f6: case 0x1f4e1: return "[net]";
    case 0x1f48e: case 0x1f451: return "[VIP]";
    case 0x1f511: case 0x1f5dd: return "[key]";
    case 0x1f3e0: return "[home]";
    case 0x1f3e2: return "[office]";
    case 0x1f4bc: return "[work]";
    case 0x1f6e1: return "[shield]";
    case 0x1f3ae: return "[game]";
    case 0x1f4fa: return "[TV]";
    case 0x1f3ac: return "[video]";
    case 0x1f4bb: return "[PC]";
    case 0x1f4f1: return "[mobile]";
    case 0x231b: case 0x23f3: return "[wait]";
    case 0x26a0: return "[!]";
    case 0x2139: return "[i]";
    case 0x2190: case 0x21a9: return "<-";
    case 0x2192: case 0x21aa: return "->";
    case 0x2191: case 0x2934: return "[up]";
    case 0x2193: case 0x2935: return "[down]";
    case 0x2194: return "<->";
    case 0x2195: return "[up/down]";
    case 0x2196: return "[NW]";
    case 0x2197: return "[NE]";
    case 0x2198: return "[SE]";
    case 0x2199: return "[SW]";
    case 0x3030: return "~";
    case 0x303d: return "[mark]";
    case 0x3297: return "[congrats]";
    case 0x3299: return "[secret]";
    case 0x1f4af: return "[100]";
    case 0x1f193: return "[free]";
    case 0x1f195: return "[new]";
    case 0x1f7e2: return "[on]";
    case 0x1f534: return "[off]";
    case 0x267e: return "[inf]";
    case 0x1f517: return "[link]";
    case 0x1f501: case 0x1f504: return "[auto]";
    case 0x2764: case 0x1f499: case 0x1f49a: case 0x1f49b: case 0x1f49c: return "[heart]";
    case 0xa9: return "(c)";
    case 0xae: return "(R)";
    case 0x2122: return "TM";
    default: return "[*]";
    }
}
/* Contiguous ASCII NFKD equivalents from Unicode Mathematical Alphanumeric
 * Symbols. Holes in italic/script/fraktur alphabets are intentionally absent. */
static char plain_letter(uint32_t c) {
    static const struct { uint32_t start; unsigned char count, ascii; } ranges[] = {
        {0x1d400,26,'A'},{0x1d41a,26,'a'},{0x1d434,26,'A'},{0x1d44e,7,'a'},
        {0x1d456,18,'i'},{0x1d468,26,'A'},{0x1d482,26,'a'},{0x1d49c,1,'A'},
        {0x1d49e,2,'C'},{0x1d4a2,1,'G'},{0x1d4a5,2,'J'},{0x1d4a9,4,'N'},
        {0x1d4ae,8,'S'},{0x1d4b6,4,'a'},{0x1d4bb,1,'f'},{0x1d4bd,7,'h'},
        {0x1d4c5,11,'p'},{0x1d4d0,26,'A'},{0x1d4ea,26,'a'},{0x1d504,2,'A'},
        {0x1d507,4,'D'},{0x1d50d,8,'J'},{0x1d516,7,'S'},{0x1d51e,26,'a'},
        {0x1d538,2,'A'},{0x1d53b,4,'D'},{0x1d540,5,'I'},{0x1d546,1,'O'},
        {0x1d54a,7,'S'},{0x1d552,26,'a'},{0x1d56c,26,'A'},{0x1d586,26,'a'},
        {0x1d5a0,26,'A'},{0x1d5ba,26,'a'},{0x1d5d4,26,'A'},{0x1d5ee,26,'a'},
        {0x1d608,26,'A'},{0x1d622,26,'a'},{0x1d63c,26,'A'},{0x1d656,26,'a'},
        {0x1d670,26,'A'},{0x1d68a,26,'a'},{0x1d7ce,10,'0'},{0x1d7d8,10,'0'},
        {0x1d7e2,10,'0'},{0x1d7ec,10,'0'},{0x1d7f6,10,'0'}
    };
    if (c >= 0xff01 && c <= 0xff5e) return (char)(c - 0xff01 + 0x21);
    if (c >= 0x24b6 && c <= 0x24cf) return (char)(c - 0x24b6 + 'A');
    if (c >= 0x24d0 && c <= 0x24e9) return (char)(c - 0x24d0 + 'a');
    for (size_t i = 0; i < sizeof ranges / sizeof ranges[0]; ++i)
        if (c >= ranges[i].start && c - ranges[i].start < ranges[i].count)
            return (char)(ranges[i].ascii + c - ranges[i].start);
    return 0;
}
static int hidden(uint32_t c) {
    return c == 0x200b || c == 0x200c || c == 0x200d || c == 0x200e || c == 0x200f ||
           (c >= 0x202a && c <= 0x202e) || (c >= 0x2060 && c <= 0x206f) ||
           c == 0xfeff || extension(c);
}

void display_text_name(const char *source, char *target, size_t capacity) {
    size_t length = 0, recent[3] = {0,0,0};
    if (!target || !capacity) return;
    target[0] = 0;
    if (!source) return;
    while (*source) {
        const char *start = source, *replacement = NULL;
        uint32_t c = next(&source);
        char token[16] = {0};
        size_t bytes;
        if (hidden(c)) continue;
        if (regional(c)) {
            uint32_t second = peek(source);
            if (regional(second)) {
                next(&source);
                token[0] = '['; token[1] = (char)('A' + c - 0x1f1e6);
                token[2] = (char)('A' + second - 0x1f1e6); token[3] = ']';
                replacement = token;
            } else replacement = "[*]";
        } else if (c == '#' || c == '*' || (c >= '0' && c <= '9')) {
            const char *end = source;
            if (peek(end) == 0xfe0f) next(&end);
            if (peek(end) == 0x20e3) {
                next(&end); source = end;
                token[0] = '['; token[1] = (char)c; token[2] = ']'; replacement = token;
            }
        } else if (pictograph(c)) {
            int joined = 0;
            while (extension(peek(source))) next(&source);
            while (peek(source) == 0x200d) {
                const char *end = source;
                next(&end);
                if (!pictograph(peek(end))) break;
                next(&end); source = end; joined = 1;
                while (extension(peek(source))) next(&source);
            }
            replacement = joined ? "[*]" : pictograph_text(c);
        }
        if (!replacement) {
            char ascii = plain_letter(c);
            if (ascii) { token[0] = ascii; replacement = token; }
            else if (c == 0xfffd) replacement = "[?]";
            else if (c == '\r' || c == '\t' || c == 0xa0 || c == 0x3000 ||
                     (c >= 0x2000 && c <= 0x200a) || c == 0x202f) replacement = " ";
            else if (c == 0x2028 || c == 0x2029) replacement = "\n";
            else if ((c < 0x20 && c != '\n') || (c >= 0x7f && c <= 0x9f)) continue;
            else if (c > 0xffff || (c >= 0xe000 && c <= 0xf8ff)) replacement = "[*]";
        }
        bytes = replacement ? strlen(replacement) : (size_t)(source - start);
        if (bytes >= capacity - length) {
            /* The three most recent token boundaries are enough to reclaim
             * three bytes without splitting a UTF-8 scalar or [country] token. */
            for (unsigned i = 0; i < 3 && length + 3 >= capacity; ++i) length = recent[i];
            if (length + 3 < capacity) { memcpy(target + length,"...",3); length += 3; }
            else length = 0;
            break;
        }
        recent[2] = recent[1]; recent[1] = recent[0]; recent[0] = length;
        memcpy(target + length,replacement ? replacement : start,bytes);
        length += bytes;
    }
    target[length] = 0;
}
