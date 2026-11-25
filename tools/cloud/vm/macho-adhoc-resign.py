#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""macho-adhoc-resign.py FILE...: refresh the page hashes of an ad-hoc code signature in place (thin Mach-O files).

The linkers used here (ld64.lld, cctools ld64-711) sign arm64 output ad hoc. A tool that changes the file afterwards without
changing its size (scripts/rust-pac-rewrite.py, install_name_tool) leaves stale hashes. An ad-hoc signature is only a
CodeDirectory: one hash per page of the file up to the signature. This rewrites those hashes; nothing else changes.
On a Mac the build does `codesign -s - --force` instead."""
import hashlib
import struct
import sys

LC_CODE_SIGNATURE, CSMAGIC_EMBEDDED, CSMAGIC_CODEDIRECTORY = 0x1d, 0xfade0cc0, 0xfade0c02


def resign(path):
    data = bytearray(open(path, 'rb').read())
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<IIIIIIII', data, 0)
    if magic != 0xfeedfacf:
        raise SystemExit(f'{path}: not a thin 64-bit Mach-O file')
    at, sig = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, at)
        if cmd == LC_CODE_SIGNATURE:
            sig = struct.unpack_from('<II', data, at + 8)
        at += size
    if not sig:
        raise SystemExit(f'{path}: no code signature to refresh')
    base = sig[0]
    magic, _, count = struct.unpack_from('>III', data, base)
    if magic != CSMAGIC_EMBEDDED:
        raise SystemExit(f'{path}: unexpected signature blob {magic:#x}')
    changed = 0
    for i in range(count):
        _, offset = struct.unpack_from('>II', data, base + 12 + 8 * i)
        cd = base + offset
        if struct.unpack_from('>I', data, cd)[0] != CSMAGIC_CODEDIRECTORY:
            continue
        hash_offset, = struct.unpack_from('>I', data, cd + 16)
        n_code, code_limit = struct.unpack_from('>II', data, cd + 28)
        hash_size, hash_type, _, page_shift = struct.unpack_from('>BBBB', data, cd + 36)
        algorithm = {1: hashlib.sha1, 2: hashlib.sha256}[hash_type]
        page = 1 << page_shift
        for n in range(n_code):
            digest = algorithm(bytes(data[n * page:min((n + 1) * page, code_limit)])).digest()[:hash_size]
            slot = cd + hash_offset + n * hash_size
            if data[slot:slot + hash_size] != digest:
                data[slot:slot + hash_size] = digest
                changed += 1
    open(path, 'wb').write(data)
    print(f'{path}: {changed} page hashes refreshed')


for name in sys.argv[1:]:
    resign(name)
