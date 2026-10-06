"""Exact launcher ABI metadata. Reads captured ELFs; never executes vendor code."""
from pathlib import Path
import hashlib
import json
import struct

HERE = Path(__file__).resolve().parent
PROFILES = json.loads((HERE / 'abi-profiles.json').read_text())['profiles']


def number(value):
    return int(value, 0)


def verify(data):
    digest = hashlib.sha256(data).hexdigest()
    matches = [p for p in PROFILES if digest in p['uiSHA256']]
    if len(matches) != 1:
        raise ValueError('Unknown launcher UI SHA256')
    profile = matches[0]
    h = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    if h[0][:6] != b'\x7fELF\x02\x01' or h[1:3] != (2, 183) or h[4] != number(profile['entry']):
        raise ValueError('Unknown launcher ELF layout')
    segments = [struct.unpack_from('<IIQQQQQQ', data, h[5] + i * h[9]) for i in range(h[10])]

    def body(address, size):
        for kind, _, offset, va, _, filesz, _, _ in segments:
            if kind == 1 and va <= address and address + size <= va + filesz:
                return data[offset + address - va:offset + address - va + size]
        raise ValueError('Launcher address outside a file-backed segment')

    def u64(address):
        return struct.unpack('<Q', body(address, 8))[0]

    for fn in profile['functions']:
        if hashlib.sha256(body(number(fn['address']), fn['bytes'])).hexdigest() != fn['sha256']:
            raise ValueError('Launcher function body differs: ' + fn['id'])
    for hook in profile['hooks']:
        if u64(number(hook['slot'])) != number(hook['target']):
            raise ValueError('Launcher hook target differs')
    for check in profile['checks']:
        if struct.unpack('<I', body(number(check['address']), 4))[0] != number(check['word']):
            raise ValueError('Launcher instruction differs')
    palette = body(number(profile['globals']['palette']), profile['paletteBytes'])
    if hashlib.sha256(palette).hexdigest() != profile['paletteSHA256']:
        raise ValueError('Launcher palette differs')
    typeinfo = u64(number(profile['vtable']['firstSlot']) - 8)
    name = u64(typeinfo + 8)
    expected = profile['vtable']['rtti'].encode() + b'\0'
    if body(name, len(expected)) != expected:
        raise ValueError('Launcher vtable type differs')
    for field in ('language', 'modal'):
        address = number(profile['globals'][field])
        if not any(kind == 1 and flags & 2 and va <= address < va + memsz
                   for kind, flags, _, va, _, _, memsz, _ in segments):
            raise ValueError('Launcher global is not writable mapped data')
    return profile['id']


def header():
    count = len(PROFILES[0]['functions'])
    assert all([f['id'] for f in p['functions']] == [f['id'] for f in PROFILES[0]['functions']] for p in PROFILES)
    lines = ['/* Generated from abi-profiles.json by abi.py. */', '#ifndef ZTE_LAUNCHER_ABI_H', '#define ZTE_LAUNCHER_ABI_H', '#include <stdint.h>', '#include <stddef.h>',
             'struct launcher_abi {', ' const char *name;', ' uintptr_t entry, phdr, language, modal, palette;',
             f' uintptr_t functions[{count}];', ' struct { uintptr_t slot, target; } hooks[5];',
             ' struct { uintptr_t address; uint32_t word; } checks[9];', '};',
             'static const struct launcher_abi launcher_abis[] = {']
    for p in PROFILES:
        g = p['globals']
        lines += [' {"' + p['id'] + '", ' + ', '.join([p['entry'], p['phdr'], g['language'], g['modal'], g['palette']]) + ',',
                  '  {' + ', '.join(f['address'] for f in p['functions']) + '},',
                  '  {' + ', '.join('{' + h['slot'] + ',' + h['target'] + '}' for h in p['hooks']) + '},',
                  '  {' + ', '.join('{' + c['address'] + ',' + c['word'] + '}' for c in p['checks']) + '}', ' },']
    lines += ['};',
              'static inline const struct launcher_abi *launcher_abi_select(uintptr_t phdr, uintptr_t entry) {',
              ' for (size_t i=0;i<sizeof launcher_abis/sizeof launcher_abis[0];i++)',
              '  if (launcher_abis[i].phdr==phdr && launcher_abis[i].entry==entry) return &launcher_abis[i];',
              ' return NULL;', '}',
              'static inline uintptr_t launcher_abi_address(const struct launcher_abi *abi, uintptr_t b31) {',
              ' if (!abi) return 0;', f' for (size_t i=0;i<{count};i++) if (launcher_abis[0].functions[i]==b31) return abi->functions[i];',
              ' return 0;', '}',
              'static inline int launcher_abi_valid(const struct launcher_abi *abi,',
              ' uintptr_t (*read_pointer)(uintptr_t), uint32_t (*read_word)(uintptr_t)) {',
              ' if (!abi) return 0;',
              ' for (size_t i=0;i<9;i++) if (read_word(abi->checks[i].address)!=abi->checks[i].word) return 0;',
              ' for (size_t i=0;i<5;i++) if (read_pointer(abi->hooks[i].slot)!=abi->hooks[i].target) return 0;',
              ' return 1;', '}', '#endif', '']
    return '\n'.join(lines)


if __name__ == '__main__':
    (HERE / 'abi.h').write_text(header())
