#ifndef ZTE_NETWORK_NAME_ABI_H
#define ZTE_NETWORK_NAME_ABI_H
#include <stdint.h>
#include <stddef.h>
/* B31 stock e3914e78... and RU16eb92e2...; SDK2433d902... . The boot
 * wrapper verifies complete hashes before enabling this optional feature.
 * Both callers allocate 256 uint32_t, then append RAT; return value is ignored.
 * This replaces only registered-operator display, leaving no-service/RAT intact. */
static const struct { uintptr_t slot, target; uint32_t prolog[8]; } network_name_hooks[] = {
    {0xe7dfb0, 0x4c5248, {0xd13303ff,0xb0004dc0,0xf9452800,0xa9007bfd,0x910003fd,0xa90153f3,0xaa0103f3,0x90004a54}},
    {0xe7b358, 0x4cea40, {0xd13303ff,0x90004d80,0xf9452800,0xa9007bfd,0x910003fd,0xa90153f3,0xaa0103f3,0xf00049f4}}
};
#define NETWORK_NAME_FULL_GETTER_SLOT ((uintptr_t)0xe7f210)
#define NETWORK_NAME_SHORT_GETTER_SLOT ((uintptr_t)0xe793f8)
static inline int network_name_abi_valid(uintptr_t (*pointer)(uintptr_t), uint32_t (*word)(uintptr_t)) {
    for (size_t i = 0; i < sizeof network_name_hooks / sizeof network_name_hooks[0]; ++i) {
        if (pointer(network_name_hooks[i].slot) != network_name_hooks[i].target) return 0;
        for (size_t n = 0; n < 8; ++n)
            if (word(network_name_hooks[i].target + n * 4) != network_name_hooks[i].prolog[n]) return 0;
    }
    return pointer(NETWORK_NAME_FULL_GETTER_SLOT) && pointer(NETWORK_NAME_SHORT_GETTER_SLOT);
}
#endif
