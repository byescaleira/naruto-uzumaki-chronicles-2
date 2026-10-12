"""PS2 GS local-memory swizzle (PSMCT32 / PSMT8 / PSMT4) — enough to decode textures that
were uploaded as PSMCT32 and sampled as PSMT8/PSMT4, plus CSM1 CLUTs."""

BLOCK32 = [
    [0, 1, 4, 5, 16, 17, 20, 21],
    [2, 3, 6, 7, 18, 19, 22, 23],
    [8, 9, 12, 13, 24, 25, 28, 29],
    [10, 11, 14, 15, 26, 27, 30, 31],
]
COLUMN32 = [
    [0, 1, 4, 5, 8, 9, 12, 13],
    [2, 3, 6, 7, 10, 11, 14, 15],
    [16, 17, 20, 21, 24, 25, 28, 29],
    [18, 19, 22, 23, 26, 27, 30, 31],
    [32, 33, 36, 37, 40, 41, 44, 45],
    [34, 35, 38, 39, 42, 43, 46, 47],
    [48, 49, 52, 53, 56, 57, 60, 61],
    [50, 51, 54, 55, 58, 59, 62, 63],
]
BLOCK8 = BLOCK32
COLUMN8 = [
    [0, 4, 16, 20, 32, 36, 48, 52, 2, 6, 18, 22, 34, 38, 50, 54],
    [8, 12, 24, 28, 40, 44, 56, 60, 10, 14, 26, 30, 42, 46, 58, 62],
    [33, 37, 1, 5, 49, 53, 17, 21, 35, 39, 3, 7, 51, 55, 19, 23],
    [41, 45, 9, 13, 57, 61, 25, 29, 43, 47, 11, 15, 59, 63, 27, 31],
    [96, 100, 112, 116, 64, 68, 80, 84, 98, 102, 114, 118, 66, 70, 82, 86],
    [104, 108, 120, 124, 72, 76, 88, 92, 106, 110, 122, 126, 74, 78, 90, 94],
    [65, 69, 81, 85, 97, 101, 113, 117, 67, 71, 83, 87, 99, 103, 115, 119],
    [73, 77, 89, 93, 105, 109, 121, 125, 75, 79, 91, 95, 107, 111, 123, 127],
    [128, 132, 144, 148, 160, 164, 176, 180, 130, 134, 146, 150, 162, 166, 178, 182],
    [136, 140, 152, 156, 168, 172, 184, 188, 138, 142, 154, 158, 170, 174, 186, 190],
    [161, 165, 129, 133, 177, 181, 145, 149, 163, 167, 131, 135, 179, 183, 147, 151],
    [169, 173, 137, 141, 185, 189, 153, 157, 171, 175, 139, 143, 187, 191, 155, 159],
    [224, 228, 240, 244, 192, 196, 208, 212, 226, 230, 242, 246, 194, 198, 210, 214],
    [232, 236, 248, 252, 200, 204, 216, 220, 234, 238, 250, 254, 202, 206, 218, 222],
    [193, 197, 209, 213, 225, 229, 241, 245, 195, 199, 211, 215, 227, 231, 243, 247],
    [201, 205, 217, 221, 233, 237, 249, 253, 203, 207, 219, 223, 235, 239, 251, 255],
]

def addr32(x, y, bw):
    """Byte address of a PSMCT32 pixel (base 0, buffer width bw in 64-px units)."""
    page = (x >> 6) + (y >> 5) * bw
    block = BLOCK32[(y >> 3) & 3][(x >> 3) & 7]
    return (page * 2048 + block * 64 + COLUMN32[y & 7][x & 7]) * 4

def addr8(x, y, bw):
    """Byte address of a PSMT8 pixel (bw in 64-px units, even)."""
    page = (x >> 7) + (y >> 6) * (bw >> 1)
    block = BLOCK8[(y >> 4) & 3][(x >> 4) & 7]
    return page * 8192 + block * 256 + COLUMN8[y & 15][x & 15]

def ct32_to_t8(data, w32, h32):
    """Pixels uploaded as a w32×h32 PSMCT32 rect → (2w32)×(2h32) PSMT8 indices."""
    bw = max(1, (w32 + 63) // 64)
    mem = bytearray(max(len(data), addr32(w32 - 1, h32 - 1, bw) + 4) * 2)
    for y in range(h32):
        for x in range(w32):
            a = addr32(x, y, bw)
            i = (y * w32 + x) * 4
            mem[a:a + 4] = data[i:i + 4]
    w8, h8 = w32 * 2, h32 * 2
    tbw = max(2, bw * 2)
    return bytes(mem[addr8(x, y, tbw)] for y in range(h8) for x in range(w8)), w8, h8

def ct32_linear(data, w, h):
    """Un-swizzle a PSMCT32 upload read back as PSMCT32 (identity for linear data)."""
    return data[:w * h * 4]

def clut256(data):
    """16×16 PSMCT32 CLUT, CSM1 order, PS2 alpha (0x80 = opaque) → 256 RGBA tuples."""
    raw = [tuple(data[i * 4:i * 4 + 4]) for i in range(256)]
    out = []
    for i in range(256):
        j = (i & 0xE7) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)
        r, g, b, a = raw[j]
        out.append((r, g, b, min(255, a * 2)))
    return out

def indexed_to_rgba(indices, palette):
    return b''.join(bytes(palette[i]) for i in indices)
