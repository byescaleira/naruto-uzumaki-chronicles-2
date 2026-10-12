"""CFC.DIG reader — prototype derived via REA from SLES_550.90.

Index (FUN_001296b0 / FUN_001292e0): first 0x3000 bytes, 16-byte entries:
  u32 sector, u32 stored_size, u16 unk, u16 compressed, u32 size
Decompressor (I/O worker case 7 -> FUN_001308c0): 9-bit LSB-first codes,
per-chunk (0x9000 bytes) bit reset, context-indexed 32-slot history.
"""
import struct, sys

SECTOR = 0x800
CHUNK = 0x9000

def read_index(f):
    f.seek(0)
    head = f.read(0x3000)
    entries = []
    for i in range(0, len(head) // 16):
        sector, stored, unk, comp, size = struct.unpack_from('<IIHHI', head, i * 16)
        entries.append((sector, stored, unk, comp, size))
    return entries

def decompress(src: bytes, size: int) -> bytes:
    out = bytearray(size)
    counters = [0] * 256
    table = [[0] * 32 for _ in range(256)]
    ctx = 0
    o = 0
    for base in range(0, len(src), CHUNK):
        chunk = src[base:base + CHUNK] + b'\0'
        n = min(CHUNK, len(src) - base)
        p = bit = 0
        while p < n and o < size:
            start = o
            code = (chunk[p] | chunk[p + 1] << 8) >> bit
            bit += 1
            p += 1
            if bit > 7:
                p += 1
                bit = 0
            if code & 0x100:
                out[o] = code & 0xFF
                o += 1
            else:
                s = table[ctx][(code >> 3) & 0x1F]
                for _ in range((code & 7) + 1):
                    out[o] = out[s]
                    o += 1
                    s += 1
            table[ctx][counters[ctx]] = start
            counters[ctx] = (counters[ctx] + 1) & 0x1F
            ctx = out[o - 1]
    return bytes(out)

if __name__ == '__main__':
    path = sys.argv[1]
    with open(path, 'rb') as f:
        idx = read_index(f)
        live = [e for e in idx if e[1] or e[4]]
        print(f'{len(live)} entries')
        for i, (sector, stored, unk, comp, size) in enumerate(idx[:int(sys.argv[2]) if len(sys.argv) > 2 else 8]):
            f.seek(sector * SECTOR)
            raw = f.read(stored)
            data = decompress(raw, size) if comp else raw[:size]
            print(i, hex(sector), stored, unk, comp, size, data[:32].hex())
