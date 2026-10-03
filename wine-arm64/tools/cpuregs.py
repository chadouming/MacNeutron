#!/usr/bin/env python3
"""Gate G3 (native arm64 spec §8): the CPU ID registers patch 10 writes, decoded the way FEX reads them.

Usage: cpuregs.py <file.reg> | --self-test
The file is `wine reg export` of HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0 (UTF-16 with a BOM; Wine's
`reg query` prints nothing for REG_QWORD). Prints `feature <name>=0|1` per feature, then PASS g3-cpu or FAIL g3-cpu.
"""
import re
import sys

# feature: (value, field's low bit, least field value); the fields are 4 bits wide (Arm ARM).
FEATURES = {
    'LSE': ('CP 4030', 20, 2),     # ID_AA64ISAR0_EL1.Atomic
    'LRCPC': ('CP 4031', 20, 1),   # ID_AA64ISAR1_EL1.LRCPC
    'LRCPC2': ('CP 4031', 20, 2),
    'AFP': ('CP 4039', 44, 1),     # ID_AA64MMFR1_EL1.AFP
}

# "CP 4030"=hex(b):20,21,21,10,01,10,21,00 -- REG_QWORD, 8 bytes, little-endian.
QWORD = re.compile(r'^"(CP [0-9A-F]{4})"=hex\(b\):((?:[0-9a-f]{2},){7}[0-9a-f]{2})\s*$', re.M | re.I)


def parse(text):
    return {m[1]: int.from_bytes(bytes.fromhex(m[2].replace(',', '')), 'little') for m in QWORD.finditer(text)}


def decode(regs):
    """{value name: int} -> {feature: 0|1}; a missing value reads as 0."""
    return {name: int((regs.get(value, 0) >> bit) & 0xf >= least) for name, (value, bit, least) in FEATURES.items()}


def self_test():
    assert decode({'CP 4030': 0x0021100110212120, 'CP 4031': 0x0000000000200000, 'CP 4039': 0x0000100000000000}) \
        == {'LSE': 1, 'LRCPC': 1, 'LRCPC2': 1, 'AFP': 1}
    assert decode({}) == {'LSE': 0, 'LRCPC': 0, 'LRCPC2': 0, 'AFP': 0}
    assert parse('"CP 4039"=hex(b):00,00,00,00,00,10,00,00\r\n') == {'CP 4039': 0x0000100000000000}
    print('PASS cpuregs self-test')


def main(argv):
    if argv == ['--self-test']:
        self_test()
        return 0
    if len(argv) != 1:
        sys.exit(__doc__.strip())
    with open(argv[0], encoding='utf-16') as f:
        found = decode(parse(f.read()))
    for name, on in found.items():
        print(f'feature {name}={on}')
    missing = [name for name, on in found.items() if not on]
    print(f'FAIL g3-cpu: {" ".join(missing)} missing' if missing else 'PASS g3-cpu')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
