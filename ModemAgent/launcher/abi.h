/* Generated from abi-profiles.json by abi.py. */
#ifndef ZTE_LAUNCHER_ABI_H
#define ZTE_LAUNCHER_ABI_H
#include <stdint.h>
#include <stddef.h>
struct launcher_abi {
 const char *name;
 uintptr_t entry, phdr, language, modal, palette;
 uintptr_t functions[34];
 struct { uintptr_t slot, target; } hooks[5];
 struct { uintptr_t address; uint32_t word; } checks[9];
};
static const struct launcher_abi launcher_abis[] = {
 {"b31", 0x421dc4, 0x400040, 0x2288088, 0x2287598, 0xe80214,
  {0x429128, 0x4291a0, 0x42a8c0, 0x42ace8, 0x42ad14, 0x42e3c0, 0x42e4f4, 0x42e660, 0x42e67c, 0x433134, 0x433198, 0x481428, 0x481540, 0x4b7ffc, 0x4bc1d0, 0x4bd900, 0x4bd9ec, 0x52f73c, 0x52f904, 0x52fa04, 0x52fa80, 0x52fcc4, 0x533dcc, 0x534a94, 0x534c08, 0x534c14, 0x537450, 0x537868, 0x53793c, 0x538080, 0x5380bc, 0x5382b4, 0x5384a0, 0x538658},
  {{0xe72aa0,0x4bd900}, {0xe7d968,0x4bd9ec}, {0xe7b448,0x4bc1d0}, {0xe72a08,0x4b7ffc}, {0xe79c30,0x4b7ffc}},
  {{0x433198,0xa9be7bfd}, {0x4331d0,0x33180e81}, {0x433134,0xa9be7bfd}, {0x433174,0x33000681}, {0x5380bc,0xa9be7bfd}, {0x5380f0,0xf9469e10}, {0x42ace8,0xb4000120}, {0x42ad04,0xd3608c00}, {0x42ad2c,0xf9402000}}
 },
 {"fly-b28", 0x41b118, 0x400040, 0x2277f40, 0x2277450, 0xe7020c,
  {0x42247c, 0x4224f4, 0x423c14, 0x42403c, 0x424068, 0x427714, 0x427848, 0x4279b4, 0x4279d0, 0x42c488, 0x42c4ec, 0x47a77c, 0x47a894, 0x4b1350, 0x4b5524, 0x4b6c54, 0x4b6d40, 0x527ee8, 0x5280b0, 0x5281b0, 0x52822c, 0x528470, 0x52c578, 0x52d240, 0x52d3b4, 0x52d3c0, 0x52fbfc, 0x530014, 0x5300e8, 0x53082c, 0x530868, 0x530a60, 0x530c4c, 0x530e04},
  {{0xe62b98,0x4b6c54}, {0xe6d970,0x4b6d40}, {0xe6b458,0x4b5524}, {0xe62b00,0x4b1350}, {0xe69c50,0x4b1350}},
  {{0x42c4ec,0xa9be7bfd}, {0x42c524,0x33180e81}, {0x42c488,0xa9be7bfd}, {0x42c4c8,0x33000681}, {0x530868,0xa9be7bfd}, {0x53089c,0xf946a210}, {0x42403c,0xb4000120}, {0x424058,0xd3608c00}, {0x424080,0xf9402000}}
 },
};
static inline const struct launcher_abi *launcher_abi_select(uintptr_t phdr, uintptr_t entry) {
 for (size_t i=0;i<sizeof launcher_abis/sizeof launcher_abis[0];i++)
  if (launcher_abis[i].phdr==phdr && launcher_abis[i].entry==entry) return &launcher_abis[i];
 return NULL;
}
static inline uintptr_t launcher_abi_address(const struct launcher_abi *abi, uintptr_t b31) {
 if (!abi) return 0;
 for (size_t i=0;i<34;i++) if (launcher_abis[0].functions[i]==b31) return abi->functions[i];
 return 0;
}
static inline int launcher_abi_valid(const struct launcher_abi *abi,
 uintptr_t (*read_pointer)(uintptr_t), uint32_t (*read_word)(uintptr_t)) {
 if (!abi) return 0;
 for (size_t i=0;i<9;i++) if (read_word(abi->checks[i].address)!=abi->checks[i].word) return 0;
 for (size_t i=0;i<5;i++) if (read_pointer(abi->hooks[i].slot)!=abi->hooks[i].target) return 0;
 return 1;
}
#endif
