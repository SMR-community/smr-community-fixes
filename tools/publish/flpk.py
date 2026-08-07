#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FLPK archive codec (Surviving Mars Relaunched .fpk) - reader and writer.

Reverse-engineered from 180 game/mod archives plus chosen-plaintext archives
produced by the game engine's own AsyncPack. Layout:

Header (32 bytes, little-endian):
    0x00 char[4] "FLPK" | 0x04 u32 0x20 | 0x08 u32 1 (version) | 0x0C u32 0x20
    (toc offset) | 0x10 u32 0 | 0x14 u32 toc_size | 0x18 u32 root_block_size |
    0x1C u32 4 (constant)

TOC: one block per directory (root first, then breadth-first by directory, in
each block's stored record order). A block is a binary search tree over entry
names (unsigned bytewise), serialized in PREORDER; each record ends with the
byte length of its left subtree, letting the engine binary-search by name.
Record: u32 data_off | u16 0 | u8 flags | u8 name_len | u32 size | name |
u32 left_subtree_bytes.  flags: 0x01 dir, 0x10 raw file, 0x30 zstd file.
Files: data_off absolute, size = stored blob length. Dirs: data_off = child
block offset relative to 0x20, size = child block byte length.

Tree shape (validated against AsyncPack output): the BST is built recursively
from the bytewise-sorted entries by weighted median: each entry weighs its
subtree file count (a file weighs 1), and the root of every span is the entry
whose cumulative-weight interval contains index total_weight // 2.

Data: blobs tightly packed after the TOC, ordered by full path sorted
case-insensitively (ASCII fold). A zstd blob is "ZSTD" | u32 raw_size |
u32 chunk_size | u32 first_fragment_off, then (n_fragments-1) u32 fragment
start offsets (blob-relative), then fragments: each is a zstd frame
(single-segment, content size, no checksum) or the chunk stored verbatim
when compression does not shrink it. A file is stored raw when the whole
zstd blob would not be smaller than the file. AsyncPack uses 1 KiB chunks
for mod archives and zstd level 3.
"""

import io
import os
import struct
import zstandard

MAGIC = b"FLPK"
FLAG_DIR = 0x01
FLAG_FILE = 0x10
FLAG_COMPRESSED = 0x20
CHUNK_SIZE = 0x400          # AsyncPack (mod pipeline); game paks use 0x40000
ZSTD_LEVEL = 3


class FlpkError(Exception):
    pass


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------

class Entry(object):
    __slots__ = ("name", "path", "flags", "data_off", "size", "left_size",
                 "children")

    def __init__(self, name, path, flags, data_off, size, left_size):
        self.name, self.path, self.flags = name, path, flags
        self.data_off, self.size, self.left_size = data_off, size, left_size
        self.children = [] if flags & FLAG_DIR else None

    @property
    def is_dir(self):
        return bool(self.flags & FLAG_DIR)


def _parse_block(toc, off, size, dir_path):
    entries = []
    p, end = off, off + size
    while p < end:
        if p + 12 > end:
            raise FlpkError("record overruns block at TOC+0x%x" % p)
        doff, pad, flags, nlen = struct.unpack_from("<IHBB", toc, p)
        fsize = struct.unpack_from("<I", toc, p + 8)[0]
        if pad != 0:
            raise FlpkError("nonzero u16 at TOC+0x%x" % p)
        if p + 12 + nlen + 4 > end:
            raise FlpkError("record name/tail overruns block at TOC+0x%x" % p)
        name = toc[p + 12: p + 12 + nlen]
        left = struct.unpack_from("<I", toc, p + 12 + nlen)[0]
        entries.append(Entry(name, dir_path + name.decode("utf-8"),
                             flags, doff, fsize, left))
        p += 16 + nlen
    if p != end:
        raise FlpkError("block did not tile at TOC+0x%x" % p)
    return entries


def parse(path_or_data):
    """Parse an archive; returns (header dict, flat entry list, root list)."""
    if isinstance(path_or_data, (bytes, bytearray)):
        data = bytes(path_or_data)
    else:
        with open(path_or_data, "rb") as f:
            data = f.read()
    if data[:4] != MAGIC:
        raise FlpkError("bad magic %r" % data[:4])
    hdr_size, version, toc_off, toc_hi, toc_size, root_size, c4 = \
        struct.unpack_from("<7I", data, 4)
    if (hdr_size, version, toc_off, toc_hi) != (0x20, 1, 0x20, 0):
        raise FlpkError("unexpected header fields %r"
                        % ((hdr_size, version, toc_off, toc_hi),))
    toc = data[toc_off: toc_off + toc_size]
    if len(toc) != toc_size:
        raise FlpkError("short TOC")

    flat = []

    def walk(off, size, dir_path):
        entries = _parse_block(toc, off, size, dir_path)
        flat.extend(entries)
        for e in entries:
            if e.is_dir:
                if e.size:
                    e.children = walk(e.data_off, e.size, e.path + "/")
                else:
                    e.children = []
        return entries

    root = walk(0, root_size, "")
    header = {"toc_size": toc_size, "root_size": root_size, "field_1c": c4,
              "data_start": toc_off + toc_size, "file_size": len(data)}
    return header, flat, root, data


def decode_blob(blob, flags):
    """Decode one file's stored blob to its original bytes."""
    if not flags & FLAG_COMPRESSED:
        return blob
    if blob[:4] != b"ZSTD":
        raise FlpkError("compressed blob lacks ZSTD fourcc")
    raw_size, chunk_size, first_off = struct.unpack_from("<3I", blob, 4)
    n_frag = max(1, -(-raw_size // chunk_size)) if raw_size else 1
    table_end = 16 + 4 * (n_frag - 1)
    if first_off != table_end:
        raise FlpkError("fragment table mismatch: first_off %d expected %d"
                        % (first_off, table_end))
    starts = [first_off]
    for i in range(n_frag - 1):
        starts.append(struct.unpack_from("<I", blob, 16 + 4 * i)[0])
    ends = starts[1:] + [len(blob)]
    out = bytearray()
    dctx = zstandard.ZstdDecompressor()
    for i, (s, e) in enumerate(zip(starts, ends)):
        want = min(chunk_size, raw_size - i * chunk_size)
        frag = blob[s:e]
        if len(frag) == want:                     # stored verbatim
            out += frag
        else:
            out += dctx.decompress(frag, max_output_size=chunk_size)
    if len(out) != raw_size:
        raise FlpkError("blob decoded to %d bytes, expected %d"
                        % (len(out), raw_size))
    return bytes(out)


def extract(path_or_data):
    """Return {relative_path: content} for every file in the archive."""
    header, flat, _root, data = parse(path_or_data)
    out = {}
    for e in flat:
        if not e.is_dir:
            blob = data[e.data_off: e.data_off + e.size]
            out[e.path] = decode_blob(blob, e.flags)
    return out


# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

def encode_blob(content, chunk_size=CHUNK_SIZE, level=ZSTD_LEVEL):
    """Build the ZSTD blob for `content`; returns None if storing raw wins."""
    if not content:
        return None
    params = zstandard.ZstdCompressionParameters.from_level(
        level, source_size=0)
    frags = []
    n_frag = -(-len(content) // chunk_size)
    for i in range(n_frag):
        chunk = content[i * chunk_size: (i + 1) * chunk_size]
        cctx = zstandard.ZstdCompressor(
            compression_params=zstandard.ZstdCompressionParameters.from_level(
                level, source_size=len(chunk)))
        frame = cctx.compress(chunk)
        frags.append(frame if len(frame) < len(chunk) else chunk)
    first_off = 16 + 4 * (n_frag - 1)
    blob = bytearray()
    blob += b"ZSTD"
    blob += struct.pack("<3I", len(content), chunk_size, first_off)
    starts, pos = [], first_off
    for f in frags:
        starts.append(pos)
        pos += len(f)
    for s in starts[1:]:              # table lists fragments 1..n-1
        blob += struct.pack("<I", s)
    for f in frags:
        blob += f
    if len(blob) > len(content):
        return None
    return bytes(blob)


class _Node(object):
    __slots__ = ("name", "is_dir", "content", "children", "weight",
                 "flags", "data_off", "size", "block_off", "block_size")

    def __init__(self, name, is_dir):
        self.name = name          # bytes
        self.is_dir = is_dir
        self.content = None       # file: original bytes
        self.children = {}        # dir: name bytes -> _Node
        self.weight = 0


WEIGHT_FILES = "files"            # dir weight = subtree file count
WEIGHT_ENTRIES = "entries"        # dir weight = subtree entry count


def _weigh(node, mode):
    if not node.is_dir:
        node.weight = 1
        return 1
    total = 0
    for child in node.children.values():
        total += _weigh(child, mode)
    node.weight = total + (0 if mode == WEIGHT_FILES else 1)
    if node.weight == 0:
        node.weight = 1           # never observed (no empty dirs), be safe
    return node.weight


def _shape(entries):
    """entries: bytewise-sorted [(node)] -> preorder [(node, left_bytes)]."""
    if not entries:
        return []
    total = sum(n.weight for n in entries)
    target = total // 2
    acc = 0
    for i, n in enumerate(entries):
        if acc + n.weight > target:
            root_i = i
            break
        acc += n.weight
    else:
        root_i = len(entries) - 1
    left = _shape(entries[:root_i])
    right = _shape(entries[root_i + 1:])
    left_bytes = sum(16 + len(n.name) for n, _ in left)
    return [(entries[root_i], left_bytes)] + left + right


def pack(files, chunk_size=CHUNK_SIZE, level=ZSTD_LEVEL, weight=WEIGHT_FILES,
         blob_order=None):
    """files: {relative_path(str, '/'-separated): bytes} -> archive bytes.

    Blobs are laid out in the order AsyncPack received its file list; pass
    blob_order (list of relative paths) to reproduce a specific archive,
    default is the case-insensitively sorted path list.
    """
    if not files:
        raise FlpkError("refusing to pack an empty file set")
    root = _Node(b"", True)
    for rel, content in files.items():
        parts = rel.replace("\\", "/").strip("/").split("/")
        node = root
        for part in parts[:-1]:
            key = part.encode("utf-8")
            nxt = node.children.get(key)
            if nxt is None:
                nxt = node.children[key] = _Node(key, True)
            if not nxt.is_dir:
                raise FlpkError("%r is both file and directory" % part)
            node = nxt
        leaf_key = parts[-1].encode("utf-8")
        if leaf_key in node.children:
            raise FlpkError("duplicate path %r" % rel)
        leaf = node.children[leaf_key] = _Node(leaf_key, False)
        leaf.content = content

    _weigh(root, weight)

    # Per-directory preorder record lists (BST shape), block sizes.
    def block_records(dnode):
        entries = sorted(dnode.children.values(), key=lambda n: n.name)
        return _shape(entries)

    # Breadth-first block layout: root block, then each dir's block in the
    # order dirs appear in already-laid-out blocks (stored record order).
    blocks = []                   # (dnode, records)
    root_records = block_records(root)
    blocks.append((root, root_records))
    queue = [n for n, _ in root_records if n.is_dir]
    while queue:
        d = queue.pop(0)
        recs = block_records(d)
        blocks.append((d, recs))
        queue.extend(n for n, _ in recs if n.is_dir)

    # Assign TOC-relative block offsets.
    pos = 0
    for dnode, recs in blocks:
        dnode.block_off = pos
        dnode.block_size = sum(16 + len(n.name) for n, _ in recs)
        pos += dnode.block_size
    toc_size = pos

    # Encode blobs in case-insensitively sorted full-path order.
    def full_paths(dnode, prefix):
        out = []
        for child in dnode.children.values():
            p = prefix + child.name.decode("utf-8")
            if child.is_dir:
                out.extend(full_paths(child, p + "/"))
            else:
                out.append((p, child))
        return out

    if blob_order is None:
        ordered = sorted(full_paths(root, ""), key=lambda t: t[0].lower())
    else:
        by_path = dict(full_paths(root, ""))
        if sorted(by_path) != sorted(blob_order):
            raise FlpkError("blob_order does not cover the file set")
        ordered = [(p, by_path[p]) for p in blob_order]
    data_start = 0x20 + toc_size
    cursor = data_start
    payload = bytearray()
    for _p, node in ordered:
        blob = encode_blob(node.content, chunk_size, level) \
            if node.content else None
        if blob is None:
            node.flags = FLAG_FILE
            stored = node.content
        else:
            node.flags = FLAG_FILE | FLAG_COMPRESSED
            stored = blob
        node.data_off = cursor
        node.size = len(stored)
        payload += stored
        cursor += len(stored)

    # Serialize TOC.
    toc = bytearray()
    for dnode, recs in blocks:
        for n, left_bytes in recs:
            if n.is_dir:
                doff, size, flags = n.block_off, n.block_size, FLAG_DIR
            else:
                doff, size, flags = n.data_off, n.size, n.flags
            toc += struct.pack("<IHBB", doff, 0, flags, len(n.name))
            toc += struct.pack("<I", size)
            toc += n.name
            toc += struct.pack("<I", left_bytes)
    assert len(toc) == toc_size

    header = MAGIC + struct.pack("<7I", 0x20, 1, 0x20, 0, toc_size,
                                 blocks[0][0].block_size, 4)
    return bytes(header) + bytes(toc) + bytes(payload)


def pack_dir(source_dir, chunk_size=CHUNK_SIZE, level=ZSTD_LEVEL,
             weight=WEIGHT_FILES):
    files = {}
    for base, _dirs, names in os.walk(source_dir):
        for name in names:
            p = os.path.join(base, name)
            rel = os.path.relpath(p, source_dir).replace("\\", "/")
            with open(p, "rb") as f:
                files[rel] = f.read()
    return pack(files, chunk_size, level, weight)


def check_against_dir(archive_path, source_dir):
    """Extract `archive_path` in memory and compare byte-for-byte against the
    files under `source_dir`. Returns a list of problems (empty = identical)."""
    problems = []
    got = extract(archive_path)
    want = {}
    for base, _dirs, names in os.walk(source_dir):
        for name in names:
            p = os.path.join(base, name)
            rel = os.path.relpath(p, source_dir).replace("\\", "/")
            with open(p, "rb") as f:
                want[rel] = f.read()
    for rel in sorted(set(want) - set(got)):
        problems.append("missing from archive: %s" % rel)
    for rel in sorted(set(got) - set(want)):
        problems.append("unexpected in archive: %s" % rel)
    for rel in sorted(set(got) & set(want)):
        if got[rel] != want[rel]:
            problems.append("content differs: %s (archive %d bytes, source %d)"
                            % (rel, len(got[rel]), len(want[rel])))
    return problems


def selftest():
    """Pack a synthetic tree exercising every format feature, then verify the
    reader gets the exact bytes back. Raises on any failure."""
    files = {
        "metadata.lua": b"return PlaceObj('ModDef', { 'id', 'X' })\n",
        "empty.bin": b"",
        "Code/a.lua": b"-- compressible " + b"x" * 5000,
        "Code/deep/nested/leaf.txt": b"leaf",
        "Images/rand.jpg": os.urandom(4096),           # stays raw
        "big_zeros.bin": b"\0" * 300000,               # multi-fragment
    }
    data = pack(files)
    back = extract(data)
    assert set(back) == set(files), "file set mismatch"
    for rel in files:
        assert back[rel] == files[rel], "content mismatch: %s" % rel
    # Structural invariant the engine's name lookup relies on: walking each
    # directory block as the BST its left_size fields describe must visit the
    # names in exact bytewise order.
    toc_size, root_size = struct.unpack_from("<I", data, 0x14)[0], \
        struct.unpack_from("<I", data, 0x18)[0]
    toc = data[0x20:0x20 + toc_size]

    def check_block(off, size):
        recs, p = [], off
        while p < off + size:
            _doff, _pad, flags, nlen = struct.unpack_from("<IHBB", toc, p)
            dsize = struct.unpack_from("<I", toc, p + 8)[0]
            name = toc[p + 12: p + 12 + nlen]
            left = struct.unpack_from("<I", toc, p + 12 + nlen)[0]
            recs.append((p, 16 + nlen, name, left, flags, _doff, dsize))
            p += 16 + nlen
        by_off = {r[0]: r for r in recs}
        order = []

        def walk(rec_off, span_end):
            rec = by_off[rec_off]
            left_start = rec[0] + rec[1]
            left_end = left_start + rec[3]
            if left_end > left_start:
                walk(left_start, left_end)
            order.append(rec[2])
            if left_end < span_end:
                walk(left_end, span_end)

        if recs:
            walk(off, off + size)
        assert order == sorted(order), "BST in-order violates bytewise sort"
        for _p, _sz, _n, _l, flags, doff, dsize in recs:
            if flags & FLAG_DIR and dsize:
                check_block(doff, dsize)

    check_block(0, root_size)
    return "selftest ok: %d files, %d byte archive" % (len(files), len(data))


def _main(argv):
    if len(argv) >= 4 and argv[1] == "pack":
        data = pack_dir(argv[2])
        with open(argv[3], "wb") as f:
            f.write(data)
        print("packed %s -> %s (%d bytes)" % (argv[2], argv[3], len(data)))
        return 0
    if len(argv) >= 4 and argv[1] == "extract":
        files = extract(argv[2])
        for rel, content in files.items():
            dest = os.path.join(argv[3], rel)
            os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
            with open(dest, "wb") as f:
                f.write(content)
        print("extracted %d files" % len(files))
        return 0
    if len(argv) >= 4 and argv[1] == "check":
        problems = check_against_dir(argv[2], argv[3])
        for p in problems:
            print("MISMATCH:", p)
        print("check %s: %s" % (argv[2], "FAILED" if problems else "ok"))
        return 1 if problems else 0
    if len(argv) >= 2 and argv[1] == "selftest":
        print(selftest())
        return 0
    print(__doc__)
    print("usage: flpk.py pack <dir> <out.fpk> | extract <fpk> <dir> "
          "| check <fpk> <dir> | selftest")
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv))
