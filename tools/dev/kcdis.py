#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Disassemble [va, va+len) of a fileset kernel collection (top-level LC_SEGMENT_64s) with llvm-mc. Debugging aid.
import struct, subprocess, sys
path, va, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 0)
d = open(path, 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]; off = 32
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
        if vmaddr <= va < vmaddr + filesize:
            fo = fileoff + (va - vmaddr); code = d[fo:fo + n]
            words = struct.unpack('<%dI' % (len(code) // 4), code)
            import tempfile, os
            t = tempfile.mkdtemp()
            open(t + '/c.s', 'w').write('.text\n.globl _x\n_x:\n' + ''.join('.inst 0x%08x\n' % w for w in words))
            subprocess.run(['xcrun', 'clang', '-arch', 'arm64e', '-c', t + '/c.s', '-o', t + '/c.o'], check=True)
            # -z: a run of zero words is one '...' line otherwise, and the lines are counted for the addresses below
            out = subprocess.run(['xcrun', 'llvm-objdump', '-d', '-z', '--no-show-raw-insn', '--mattr=+v8.5a,+pauth', t + '/c.o'],
                                 capture_output=True, text=True).stdout.splitlines()
            k = 0
            for l in out:
                l = l.strip()
                if ':' in l and l.split(':')[0].strip().isalnum() and '\t' in l:
                    print('%x %s' % (va + 4 * k, l.split(':', 1)[1].strip())); k += 1
            sys.exit(0)
    off += sz
print('va not found')
