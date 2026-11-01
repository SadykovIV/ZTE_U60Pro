#include "network-name.h"
#include <string.h>

static int decode(const unsigned char *text, size_t length, size_t *offset, uint32_t *out) {
    size_t i = *offset;
    unsigned char first = text[i++];
    unsigned count;
    uint32_t value;
    if (first < 0x80) { value = first; count = 1; }
    else if (first >= 0xc2 && first <= 0xdf) { value = first & 31; count = 2; }
    else if (first >= 0xe0 && first <= 0xef) { value = first & 15; count = 3; }
    else if (first >= 0xf0 && first <= 0xf4) { value = first & 7; count = 4; }
    else return 0;
    if (count - 1 > length - i) return 0;
    for (unsigned n = 1; n < count; ++n) {
        if ((text[i] & 0xc0) != 0x80) return 0;
        value = (value << 6) | (text[i++] & 63);
    }
    if ((count == 3 && value < 0x800) || (count == 4 && value < 0x10000) ||
        (value >= 0xd800 && value <= 0xdfff) || value > 0x10ffff ||
        value < 0x20 || (value >= 0x7f && value <= 0x9f) ||
        (value >= 0x200b && value <= 0x200f) || (value >= 0x2028 && value <= 0x202e) ||
        (value >= 0x2060 && value <= 0x206f) || value == 0xfeff) return 0;
    *offset = i; *out = value; return 1;
}

static int read_name(uint32_t *target, size_t capacity, network_name_getter getter) {
    char text[256];
    uint32_t result[NETWORK_NAME_WIDE_CAPACITY];
    size_t length, start = 0, end, offset, used = 0, bytes = 0;
    if (!getter) return 0;
    memset(text, 0, sizeof text);
    if (getter(text, sizeof text)) return 0;
    const char *nul = memchr(text, 0, sizeof text);
    if (!nul) return 0;
    length = (size_t)(nul - text); end = length;
    while (start < end && text[start] == ' ') ++start;
    while (end > start && text[end - 1] == ' ') --end;
    if (start == end) return 0;
    offset = start;
    while (offset < end) {
        size_t before = offset;
        uint32_t value;
        if (!decode((const unsigned char *)text, end, &offset, &value)) return 0;
        /* Validate the entire SDK value, including any truncated suffix. Leave
         * three bytes for a visible ellipsis and a NUL in both output buffers. */
        if (bytes + offset - before <= NETWORK_NAME_UTF8_LIMIT - 3 &&
            used < NETWORK_NAME_SCALAR_LIMIT - 3 &&
            used + 4 < capacity && used + 4 < NETWORK_NAME_WIDE_CAPACITY) {
            result[used++] = value; bytes += offset - before;
        } else {
            while (offset < end) if (!decode((const unsigned char *)text, end, &offset, &value)) return 0;
            if (used + 3 < capacity && used + 3 < NETWORK_NAME_WIDE_CAPACITY) {
                result[used++] = '.'; result[used++] = '.'; result[used++] = '.';
            }
            break;
        }
    }
    if (!used) return 0;
    result[used] = 0;
    memcpy(target, result, (used + 1) * sizeof *target);
    return 1;
}

void network_name_read(uint32_t *target, size_t capacity,
                       network_name_getter full, network_name_getter short_name) {
    if (!target || !capacity) return;
    target[0] = 0;
    if (capacity < 2) return;
    if (read_name(target, capacity, full) || read_name(target, capacity, short_name)) return;
    target[0] = 0x2014; target[1] = 0; /* No SIM-identity or stale stock-name fallback. */
}
