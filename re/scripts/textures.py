"""Find and decode texture sets inside expanded DIG sub-files.

Layout (observed in UI/sprite sub-files):
  texture table: N × 20 bytes {u16 image, u16 -1, u16 -1, u16 -1, u16 clut, u8 1, u8 1, u32 0, u16 w, u16 h}
  upload table:  M × 16 bytes {u32 0, u32 offset (relative to this record), u16 w32, u16 h32, u32 w32*h32/64}
  uploads: PSMCT32 rects holding PSMT8 pixels (2w×2h) or 16×16 CSM1 CLUTs.
"""
import struct, sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
import gs

def upload_tables(d):
    off = 0
    while off + 32 <= len(d):
        z, o, w, h, k = struct.unpack_from('<IIHHI', d, off)
        if z == 0 and w and h and w <= 512 and h <= 512 and k == w * h // 64 and k and off + o + w * h * 4 <= len(d):
            recs = []
            p = off
            while p + 16 <= len(d):
                z, o, w, h, k = struct.unpack_from('<IIHHI', d, p)
                if not (z == 0 and w and h and k == w * h // 64 and p + o + w * h * 4 <= len(d)):
                    break
                recs.append((p + o, w, h))
                p += 16
            if len(recs) >= 2:
                yield off, recs
                off = p
                continue
        off += 4

def texture_table(d, end, count):
    """Walk 20-byte texture records backwards from the upload table."""
    texs = []
    p = end - 20
    while p >= 0:
        img, a, b, c, clut, one1, one2, zero, w, h = struct.unpack_from('<HHHHHBBIHH', d, p)
        if not (a == b == c == 0xFFFF and one1 == 1 and zero == 0 and img < count and clut < count and w and h):
            break
        texs.insert(0, (img, clut, w, h))
        p -= 20
    return texs

def decode_all(d):
    for off, recs in upload_tables(d):
        for img, clut, w, h in texture_table(d, off, len(recs)):
            ao, aw, ah = recs[img]
            co, cw, ch = recs[clut]
            if (cw, ch) != (16, 16):
                continue
            idx, w8, h8 = gs.ct32_to_t8(d[ao:ao + aw * ah * 4], aw, ah)
            pal = gs.clut256(d[co:co + 1024])
            yield (w8, h8, gs.indexed_to_rgba(idx, pal))
