#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""apsb.py IMAGE [--apply]: the hosted disk's volume group after the Data volume was made again (newfs_apfs -A cannot set these):
the new Data volume gets the Data role and the group of the System volume; the installed (encrypted) one loses both."""
import mmap, struct, sys, uuid
GROUP = uuid.UUID('478C06EB-C8E8-4234-B386-23433F2A8433')
OLD, NEW = GROUP, uuid.UUID(sys.argv[2])
apply = '--apply' in sys.argv
def fletcher64(data):
    lo = hi = 0
    for (w,) in struct.iter_unpack('<I', data):
        lo = (lo + w) % 0xFFFFFFFF; hi = (hi + lo) % 0xFFFFFFFF
    c0 = 0xFFFFFFFF - ((lo + hi) % 0xFFFFFFFF); c1 = 0xFFFFFFFF - ((lo + c0) % 0xFFFFFFFF)
    return (c1 << 32) | c0
f = open(sys.argv[1], 'r+b' if apply else 'rb'); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE if apply else mmap.ACCESS_READ)
pos, end, n = 524308480, 63350788096, 0
while True:
    pos = m.find(b'APSB', pos, end)
    if pos < 0: break
    b = pos - 32; pos += 4
    if b % 4096: continue
    blk = bytearray(m[b:b + 4096]); vu = uuid.UUID(bytes=bytes(blk[240:256]))
    if vu not in (OLD, NEW): continue
    ok = struct.unpack_from('<Q', blk, 0)[0] == fletcher64(bytes(blk[8:]))
    xid = struct.unpack_from('<Q', blk, 16)[0]
    feat, ro, inc = struct.unpack_from('<QQQ', blk, 40); flags = struct.unpack_from('<Q', blk, 264)[0]
    role = struct.unpack_from('<H', blk, 964)[0]; grp = uuid.UUID(bytes=bytes(blk[1008:1024]))
    print(f'{"NEW" if vu == NEW else "OLD"} block {b // 4096:#x} xid {xid} cksum {"ok" if ok else "BAD"} features {feat:#x} ro {ro:#x} incompat {inc:#x} flags {flags:#x} role {role:#x} group {grp}')
    if not ok or not apply: continue
    if vu == NEW:
        struct.pack_into('<H', blk, 964, 0x40); blk[1008:1024] = GROUP.bytes
    else:
        struct.pack_into('<H', blk, 964, 0); blk[1008:1024] = bytes(16)
    struct.pack_into('<Q', blk, 0, fletcher64(bytes(blk[8:]))); m[b:b + 4096] = bytes(blk); n += 1
if apply: m.flush(); print(n, 'superblocks rewritten')
