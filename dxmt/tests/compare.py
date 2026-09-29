#!/usr/bin/env python3
"""compare.py <ours.txt> <reference.txt> <group>: compare one behaviour group's words between two d3d12_dxil_exec runs.
Exact, except the 'transcendental' group, whose words are float32 compared within 4 ULP (DXIL translator plan)."""
import struct, sys

def words(path, group):
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split()
        if parts[:2] == ["group", group]:
            return parts[3:] if parts[2] == "ok" else None
    return None

def ordered(bits):  # float32 bits -> an integer that orders like the float, so the difference counts ULPs
    i = struct.unpack("<i", struct.pack("<I", bits))[0]
    return -0x80000000 - i if i < 0 else i

ours, ref, group = words(sys.argv[1], sys.argv[3]), words(sys.argv[2], sys.argv[3]), sys.argv[3]
if ref is None:
    print(f"no reference output for {group}"); sys.exit(2)
if ours is None:
    print(f"differ: {group} failed on ours"); sys.exit(1)
for i, (x, y) in enumerate(zip(ours, ref)):
    a, b = int(x, 16), int(y, 16)
    if a != b and (group != "transcendental" or abs(ordered(a) - ordered(b)) > 4):
        print(f"differ: word {i} (thread {i // 16}, slot {i % 16}) ours {x} ref {y}"); sys.exit(1)
print("match")
