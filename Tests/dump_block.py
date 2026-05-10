#!/usr/bin/env python3
"""
dump_block.py — PTX binary block inspector

Usage:
  python3 Tests/dump_block.py <file.ptx> [options]

Options:
  --list                 List all content-type counts
  --type 0x104f          Show all blocks of this content type
  --type 0x104f --n 3    Show first N blocks of that type
  --type 0x104f --fields Annotate known field offsets
  --offset 0x3000 --len 64   Dump raw decoded bytes at offset
  --find "PART ONE"     Search for UTF-8 string in decoded data

Block header (9 bytes, anchored by 0x5a):
  [0]     0x5a
  [1-2]   blockType   (LE u16)
  [3-6]   blockSize   (LE u32) — byte count of content that follows
  [7-8]   contentType (LE u16) — what we filter by (0x104f, 0x1028, …)
  [9...]  content bytes
"""

import sys, struct, argparse
from collections import Counter

# ── XOR decode (mirrors PTXBlockDecoder.swift exactly) ───────────────────────

def gen_xor_delta(xor_value: int, mul: int, negative: bool) -> int:
    for i in range(256):
        if (i * mul) & 0xff == xor_value:
            return (256 - i) & 0xff if negative else i
    return 0

def xor_decode(raw: bytes) -> tuple[bytes, bool]:
    if len(raw) < 0x14:
        return raw, False
    file_type = raw[0x12]
    xor_value = raw[0x13]
    big_endian = raw[0x11] != 0

    if file_type == 0x05:       # PT 10+
        mul, negative = 11, True
    elif file_type == 0x01:     # PT 5–9
        mul, negative = 53, False
    else:
        return raw, big_endian  # unknown format, return as-is

    delta = gen_xor_delta(xor_value, mul, negative)
    # Build XOR table: table[i] = (i * delta) & 0xff
    table = [(i * delta) & 0xff for i in range(256)]

    out = bytearray(raw)
    chunk_size = 4096 if file_type == 0x05 else len(raw)

    if file_type == 0x05:
        # First chunk (0..4095) uses table[0] = 0, which is a no-op — skip it
        for chunk_idx in range(1, (len(raw) + chunk_size - 1) // chunk_size):
            xor_byte = table[chunk_idx & 0xff]
            if xor_byte == 0:
                continue
            start = chunk_idx * chunk_size
            end   = min(start + chunk_size, len(raw))
            for i in range(start, end):
                out[i] = raw[i] ^ xor_byte
    else:
        for i in range(len(raw)):
            out[i] = raw[i] ^ table[i & 0xff]

    return bytes(out), big_endian

# ── Block scanner ─────────────────────────────────────────────────────────────

def scan_blocks(data: bytes, big_endian: bool) -> list[dict]:
    """Byte-by-byte 0x5a anchor scan — same approach as Swift."""
    bo = '>' if big_endian else '<'
    blocks = []
    i = 0x1f   # first block starts here (as in Swift)
    while i + 9 <= len(data):
        if data[i] != 0x5a:
            i += 1
            continue
        try:
            block_size   = struct.unpack_from(f'{bo}I', data, i + 3)[0]
            content_type = struct.unpack_from(f'{bo}H', data, i + 7)[0]
        except struct.error:
            i += 1
            continue
        if block_size == 0 or block_size >= 50_000_000:
            i += 1
            continue
        if i + 9 + block_size > len(data):
            i += 1
            continue
        blocks.append({
            'offset':       i,
            'content_type': content_type,
            'size':         block_size,
            'data':         data[i + 9: i + 9 + block_size],
        })
        i += 1   # byte-by-byte to catch nested blocks
    return blocks

# ── Hex dump ──────────────────────────────────────────────────────────────────

def hexdump(data: bytes, base: int = 0, width: int = 16) -> str:
    lines = []
    for i in range(0, len(data), width):
        chunk = data[i:i+width]
        hex_part   = ' '.join(f'{b:02x}' for b in chunk)
        ascii_part = ''.join(chr(b) if 0x20 <= b < 0x7f else '.' for b in chunk)
        lines.append(f'  {base+i:08x}  {hex_part:<{width*3}}  |{ascii_part}|')
    return '\n'.join(lines)

# ── Known field annotations ───────────────────────────────────────────────────

FIELDS = {
    0x104f: [
        ( 0, 1, 'muted flag      (0x01=muted)'),
        ( 2, 2, 'clip pool index (LE u16)'),
        ( 7, 4, 'timeline sample (LE u32)'),
        (18, 1, 'group flag      (0x01=compound group)'),
        (35, 1, 'hidden flag     (0x01=hidden dialog ref)'),
    ],
    0x1001: [
        (0, 4, 'sample rate     (LE u32)'),
        (4, 1, 'channel count'),
        (5, 1, 'bit depth raw   (0x18=24)'),
        (6, 4, 'file length samples (LE u32)'),
    ],
    0x1028: [
        ( 0, 1, 'unknown'),
        ( 1, 1, 'bit depth raw   (0x18=24)'),
        ( 2, 4, 'sample rate     (LE u32)'),
        (12, 4, 'path component count (LE u32)'),
    ],
}

def annotate(ctype: int, data: bytes) -> str:
    flds = FIELDS.get(ctype, [])
    if not flds:
        return ''
    lines = ['  Fields:']
    for off, size, label in flds:
        if off + size > len(data):
            lines.append(f'    +{off:<3d} {label}  → (out of range, data={len(data)} bytes)')
            continue
        raw = data[off:off+size]
        if size == 1:
            v = f'0x{raw[0]:02x}  ({raw[0]})'
        elif size == 2:
            v = f'0x{struct.unpack_from("<H", raw)[0]:04x}  ({struct.unpack_from("<H", raw)[0]})'
        elif size == 4:
            v = f'0x{struct.unpack_from("<I", raw)[0]:08x}  ({struct.unpack_from("<I", raw)[0]})'
        else:
            v = raw.hex()
        lines.append(f'    +{off:<3d} {label}  →  {v}')
    return '\n'.join(lines)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='PTX block inspector')
    ap.add_argument('ptx', help='.ptx file path')
    ap.add_argument('--type',   help='Content type to show (hex e.g. 0x104f)')
    ap.add_argument('--n',      type=int, default=0, help='Max blocks to print (0=all)')
    ap.add_argument('--fields', action='store_true', help='Print known field annotations')
    ap.add_argument('--offset', help='Raw decoded offset to dump (hex or dec)')
    ap.add_argument('--len',    type=int, default=64, dest='length')
    ap.add_argument('--find',   help='Search for UTF-8 string in decoded data')
    ap.add_argument('--list',   action='store_true', help='List content-type counts')
    args = ap.parse_args()

    raw  = open(args.ptx, 'rb').read()
    data, big_endian = xor_decode(raw)
    print(f'File : {args.ptx}')
    print(f'Size : {len(raw)} bytes  endian={"big" if big_endian else "little"}')

    # Raw offset dump
    if args.offset is not None:
        off = int(args.offset, 0) if args.offset.startswith('0x') else int(args.offset)
        end = min(off + args.length, len(data))
        print(f'\nDecoded bytes at 0x{off:x}–0x{end:x}:')
        print(hexdump(data[off:end], base=off))
        return

    # String search
    if args.find:
        needle = args.find.encode('utf-8')
        hits, pos = 0, 0
        while True:
            idx = data.find(needle, pos)
            if idx < 0: break
            hits += 1
            s = max(0, idx - 8)
            ctx = data[s: idx + len(needle) + 16]
            print(f'  0x{idx:08x}  {hexdump(ctx, s).strip()}')
            pos = idx + 1
        print(f'\n{hits} hit(s) for {args.find!r}')
        return

    blocks = scan_blocks(data, big_endian)
    counts = Counter(b['content_type'] for b in blocks)

    # List mode
    if args.list:
        print(f'\n{len(blocks)} blocks total:')
        for ct, c in sorted(counts.items()):
            print(f'  0x{ct:04x}  ×{c}')
        return

    # Block type filter
    if args.type:
        target  = int(args.type, 0)
        matches = [b for b in blocks if b['content_type'] == target]
        limit   = args.n if args.n > 0 else len(matches)
        print(f'\n0x{target:04x}: {len(matches)} blocks, showing {min(limit, len(matches))}')
        for b in matches[:limit]:
            preview = min(128, b['size'])
            print(f'\n  block_offset=0x{b["offset"]:08x}  content_size={b["size"]}')
            print(hexdump(b['data'][:preview]))
            if b['size'] > preview:
                print(f'  … ({b["size"] - preview} more bytes, use --n and redirect to see all)')
            if args.fields:
                ann = annotate(target, b['data'])
                if ann: print(ann)
        return

    # Default summary
    print(f'\n{len(blocks)} blocks. Top types:')
    for ct, c in counts.most_common(15):
        print(f'  0x{ct:04x}  ×{c}')
    print('\nUse --list, --type 0xXXXX [--fields] [--n N], --offset N [--len N], --find "text"')

if __name__ == '__main__':
    main()
