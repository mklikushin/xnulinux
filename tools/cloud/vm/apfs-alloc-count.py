#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Check, and with --fix correct, the block counters in the volume superblocks of an APFS container that is not mounted.

    apfs-alloc-count.py [--offset BYTES] [--fix] IMAGE

IMAGE is a raw APFS container, or a disk image with the container at --offset (a GPT partition's start). For every volume it
walks the volume's object map, file-system tree, extent-reference tree and snapshot-metadata tree and compares:

    apfs_fs_alloc_count                                   with  tree nodes + 1 (the object map itself) + data blocks
    apfs_total_blocks_alloced - apfs_total_blocks_freed   with  data blocks

where "data blocks" is the sum of the physical extents in the extent-reference tree. Both hold on a volume written by
Apple (checked on the System volume of a restore image).

Why it exists: the Linux apfs driver (linux-apfs-rw) keeps apfs_fs_alloc_count right, but it also adds every tree node it
allocates or frees to apfs_total_blocks_alloced / apfs_total_blocks_freed, which macOS keeps for data blocks only. The
macOS kernel takes "alloced - freed" as the volume's data blocks, adds the tree nodes, and prints
"sanity_check_alloced_blocks: ... fs_alloc_count mismatch" for such a volume at every mount, for as long as the volume
lives. Nothing is lost and Apple's fsck_apfs does not complain, but the line never goes away by itself. --fix sets
apfs_total_blocks_alloced to apfs_total_blocks_freed + data blocks (and apfs_fs_alloc_count, should it differ) in the
latest volume superblock in place, and recomputes that block's checksum. Nothing else is touched.

Volumes it cannot walk (snapshots, sealed extents, encryption rolling) are reported and left alone.
Exit: 0 all counters agree (or were fixed), 1 a mismatch was found and not fixed, 2 usage or an unreadable image.
"""
import argparse
import struct
import sys

HDR = 32
BTNODE_ROOT, BTNODE_LEAF, BTNODE_FIXED = 1, 2, 4
NX_MAGIC, APSB_MAGIC = b'NXSB', b'APSB'
# nx_superblock_t
NX_BLOCK_SIZE, NX_XP_DESC_BLOCKS, NX_XP_DESC_BASE, NX_OMAP, NX_MAX_FS, NX_FS_OID = 36, 104, 112, 160, 180, 184
# apfs_superblock_t
APSB_ALLOC, APSB_OMAP, APSB_ROOT, APSB_EXTENTREF, APSB_SNAP_META, APSB_NUM_SNAPSHOTS = 88, 128, 136, 144, 152, 216
APSB_TOTAL_ALLOCED, APSB_TOTAL_FREED = 224, 232
APSB_NAME, APSB_ER_STATE, APSB_SNAP_META_EXT, APSB_FEXT, APSB_PFKUR = 704, 976, 1000, 1032, 1048
APFS_TYPE_EXTENT = 2


def fletcher64(block):
    """APFS's object checksum over everything after the first 8 bytes."""
    words = struct.unpack_from('<%dI' % ((len(block) - 8) // 4), block, 8)
    s1 = s2 = 0
    for start in range(0, len(words), 1024):
        for word in words[start:start + 1024]:
            s1 += word
            s2 += s1
        s1 %= 0xffffffff
        s2 %= 0xffffffff
    c1 = 0xffffffff - ((s1 + s2) % 0xffffffff)
    c2 = 0xffffffff - ((s1 + c1) % 0xffffffff)
    return (c2 << 32) | c1


class Container:
    def __init__(self, path, offset, writable):
        self.handle = open(path, 'r+b' if writable else 'rb')
        self.offset = offset
        self.bs = 4096
        first = self.block(0)
        if first[32:36] != NX_MAGIC:
            raise SystemExit(f'{path}: no APFS container at byte {offset}')
        self.bs = struct.unpack_from('<I', first, NX_BLOCK_SIZE)[0]
        first = self.block(0)
        base = struct.unpack_from('<Q', first, NX_XP_DESC_BASE)[0]
        count = struct.unpack_from('<I', first, NX_XP_DESC_BLOCKS)[0]
        if base >> 63 or count >> 31:
            raise SystemExit(f'{path}: a checkpoint area that is not contiguous is not supported')
        # the latest valid container superblock in the checkpoint descriptor area
        self.sb, self.xid = None, -1
        for i in range(count):
            block = self.block(base + i)
            if block[32:36] != NX_MAGIC or struct.unpack_from('<Q', block, 0)[0] != fletcher64(block):
                continue
            xid = struct.unpack_from('<Q', block, 16)[0]
            if xid > self.xid:
                self.sb, self.xid = block, xid
        if self.sb is None:
            raise SystemExit(f'{path}: no valid checkpoint')

    def block(self, number):
        self.handle.seek(self.offset + number * self.bs)
        data = self.handle.read(self.bs)
        if len(data) != self.bs:
            raise SystemExit(f'block {number:#x} is past the end of the image')
        return data

    def write(self, number, data):
        self.handle.seek(self.offset + number * self.bs)
        self.handle.write(data)

    def records(self, block):
        """(flags, level, [(key, value)]) of a B-tree node."""
        flags, level, nkeys = struct.unpack_from('<HHI', block, HDR)
        toc_off, toc_len = struct.unpack_from('<HH', block, HDR + 8)
        toc = HDR + 24 + toc_off
        keys = toc + toc_len
        end = self.bs - (40 if flags & BTNODE_ROOT else 0)
        out = []
        for i in range(nkeys):
            if flags & BTNODE_FIXED:
                koff, voff = struct.unpack_from('<HH', block, toc + 4 * i)
                klen = vlen = None
            else:
                koff, klen, voff, vlen = struct.unpack_from('<HHHH', block, toc + 8 * i)
            key = block[keys + koff:keys + koff + (klen or 16)]
            value = block[end - voff:end - voff + (vlen or 16)] if voff != 0xffff else b''
            out.append((key, value))
        return flags, level, out

    def walk(self, root, resolve=None, leaf=None):
        """Number of nodes in the tree whose root is at block ROOT. Child links are block numbers, or object ids that RESOLVE
        maps to block numbers. LEAF is called with every leaf record."""
        nodes, stack = 0, [root]
        while stack:
            flags, level, records = self.records(self.block(stack.pop()))
            nodes += 1
            if flags & BTNODE_LEAF:
                if leaf:
                    for key, value in records:
                        leaf(key, value)
                continue
            for _, value in records:
                child = struct.unpack_from('<Q', value, 0)[0]
                stack.append(resolve(child) if resolve else child)
        return nodes

    def omap(self, omap_block):
        """An object map as {oid: block} (the newest mapping not after this checkpoint) and its tree's node count."""
        tree = struct.unpack_from('<Q', self.block(omap_block), 48)[0]
        best = {}

        def leaf(key, value):
            oid, xid = struct.unpack_from('<QQ', key, 0)
            if xid <= self.xid and xid >= best.get(oid, (-1, 0))[0]:
                best[oid] = (xid, struct.unpack_from('<Q', value, 8)[0])
        nodes = self.walk(tree, leaf=leaf)
        return {oid: paddr for oid, (_, paddr) in best.items()}, nodes

    def volumes(self):
        """(index, superblock block number, superblock) for each volume."""
        mapping, _ = self.omap(struct.unpack_from('<Q', self.sb, NX_OMAP)[0])
        slots = struct.unpack_from('<I', self.sb, NX_MAX_FS)[0]
        for index in range(min(slots, 100)):
            oid = struct.unpack_from('<Q', self.sb, NX_FS_OID + 8 * index)[0]
            if oid:
                number = mapping[oid]
                block = self.block(number)
                if block[32:36] != APSB_MAGIC:
                    raise SystemExit(f'volume {index}: block {number:#x} is not a volume superblock')
                yield index, number, block


def expected(container, apsb):
    """The count macOS expects, with its parts; or (None, reason) when this tool does not know how to count the volume."""
    def field(at):
        return struct.unpack_from('<Q', apsb, at)[0]
    for at, what in ((APSB_ER_STATE, 'encryption rolling'), (APSB_SNAP_META_EXT, 'extended snapshot metadata'),
                     (APSB_FEXT, 'sealed extents'), (APSB_PFKUR, 'a key-rolling tree'), (APSB_NUM_SNAPSHOTS, 'snapshots')):
        if field(at):
            return None, what
    mapping, omap_nodes = container.omap(field(APSB_OMAP))
    fs_nodes = container.walk(mapping[field(APSB_ROOT)], resolve=mapping.__getitem__)
    data = [0]

    def extent(key, value):
        if struct.unpack_from('<Q', key, 0)[0] >> 60 == APFS_TYPE_EXTENT:
            data[0] += struct.unpack_from('<Q', value, 0)[0] & 0x0fffffffffffffff
    extent_nodes = container.walk(field(APSB_EXTENTREF), leaf=extent)
    snap_nodes = container.walk(field(APSB_SNAP_META))
    parts = {'fs': fs_nodes, 'extent': extent_nodes, 'omap': omap_nodes, 'snap_meta': snap_nodes, 'data': data[0]}
    return sum(parts.values()) + 1, parts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('image')
    parser.add_argument('--offset', type=int, default=0, help='byte offset of the container in IMAGE')
    parser.add_argument('--fix', action='store_true', help='write the expected count where it differs')
    args = parser.parse_args()
    try:
        container = Container(args.image, args.offset, args.fix)
    except OSError as error:
        print(f'apfs-alloc-count: {error}', file=sys.stderr)
        return 2
    bad = 0
    for index, number, apsb in container.volumes():
        name = apsb[APSB_NAME:APSB_NAME + 256].split(b'\0')[0].decode('utf-8', 'replace')
        stored = struct.unpack_from('<Q', apsb, APSB_ALLOC)[0]
        alloced, freed = struct.unpack_from('<QQ', apsb, APSB_TOTAL_ALLOCED)
        want, parts = expected(container, apsb)
        if want is None:
            print(f'volume {index} "{name}": not checked (the volume has {parts}); alloc count {stored}')
            continue
        detail = ' '.join(f'{k} {v}' for k, v in parts.items())
        net = (alloced - freed) & 0xffffffffffffffff
        if want == stored and net == parts['data']:
            print(f'volume {index} "{name}": ok, alloc count {stored}, alloced - freed {net} ({detail})')
        elif args.fix:
            block = bytearray(apsb)
            struct.pack_into('<Q', block, APSB_ALLOC, want)
            struct.pack_into('<Q', block, APSB_TOTAL_ALLOCED, (freed + parts['data']) & 0xffffffffffffffff)
            struct.pack_into('<Q', block, 0, fletcher64(block))
            container.write(number, bytes(block))
            print(f'volume {index} "{name}": fixed, alloc count {stored} -> {want}, alloced - freed {net} -> {parts["data"]} ({detail})')
        else:
            print(f'volume {index} "{name}": MISMATCH, alloc count {stored} (expected {want}), alloced - freed {net} '
                  f'(expected {parts["data"]}) ({detail})')
            bad = 1
    container.handle.close()
    return bad


if __name__ == '__main__':
    sys.exit(main())
