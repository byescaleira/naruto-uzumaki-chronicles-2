"""Generates the README images from the user's own extracted disc data.

  python3 -I re/scripts/docs_images.py <dig-extract-dir> <tex-dir> <out-dir>
"""
import os, struct, sys, zlib
sys.path.insert(0, os.path.dirname(__file__))
import gs, png, textures

dig, tex, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)

def load_png(path):
    b = open(path, 'rb').read()
    w, h = struct.unpack('>II', b[16:24])
    p, idat = 8, b''
    while p < len(b):
        n = struct.unpack('>I', b[p:p + 4])[0]
        if b[p + 4:p + 8] == b'IDAT':
            idat += b[p + 8:p + 8 + n]
        p += 12 + n
    raw, s = zlib.decompress(idat), w * 4
    return w, h, b''.join(raw[y * (s + 1) + 1:(y + 1) * (s + 1)] for y in range(h))

class Canvas:
    def __init__(self, w, h, rgb):
        self.w, self.h = w, h
        self.px = bytearray(bytes((*rgb, 255)) * (w * h))

    def blit(self, img, x0, y0, scale=1.0, checker=False):
        w, h, px = img
        dw, dh = int(w * scale), int(h * scale)
        for y in range(dh):
            for x in range(dw):
                cx, cy = x0 + x, y0 + y
                if not (0 <= cx < self.w and 0 <= cy < self.h):
                    continue
                si = (int(y / scale) * w + int(x / scale)) * 4
                r, g, b, a = px[si:si + 4]
                o = (cy * self.w + cx) * 4
                if checker:
                    bg = 70 if ((x // 12 + y // 12) & 1) else 52
                    under = (bg, bg, bg)
                else:
                    under = tuple(self.px[o:o + 3])
                k = a / 255
                self.px[o:o + 4] = bytes((int(r * k + under[0] * (1 - k)), int(g * k + under[1] * (1 - k)),
                                          int(b * k + under[2] * (1 - k)), 255))

    def save(self, path):
        png.write_png(path, self.w, self.h, bytes(self.px))
        print('wrote', path, self.w, self.h)

# 1. Swizzle explainer: the face atlas as stored, after the GS swizzle, and with its CLUT.
d = open(os.path.join(dig, '0039', '00.bin'), 'rb').read()
for off, recs in textures.upload_tables(d):
    texs = textures.texture_table(d, off, len(recs))
    if texs and max(t[2] for t in texs) >= 256:
        break
img, clut, tw, th = next(t for t in texs if t[2] == 256)
ao, aw, ah = recs[img]
co = recs[clut][0]
raw = d[ao:ao + aw * ah * 4]
gray = lambda idx: bytes(c for i in idx for c in (i, i, i, 255))
stored = (aw * 2, ah * 2, gray(raw))                       # bytes as laid out in the file
idx, w8, h8 = gs.ct32_to_t8(raw, aw, ah)
unswizzled = (w8, h8, gray(idx))
final = (w8, h8, gs.indexed_to_rgba(idx, gs.clut256(d[co:co + 1024])))
S = 2
c = Canvas(3 * 256 * S + 4 * 40, 256 * S + 80, (18, 22, 20))
for i, im in enumerate((stored, unswizzled, final)):
    c.blit(im, 40 + i * (256 * S + 40), 40, S, checker=(i == 2))
c.save(os.path.join(out, 'swizzle.png'))

# 2. Gallery of decoded textures.
picks = ['0039_00_001', '0041_01_004', '0041_01_005', '0041_01_008', '0041_01_012', '0041_01_001',
         '0042_00_001', '0042_00_002', '0216_00_004', '0014_61_000', '0002_04_003', '0002_04_000']
avail = [p for p in picks if os.path.exists(os.path.join(tex, p + '.png'))]
cell, cols = 220, 6
rows = (len(avail) + cols - 1) // cols
g = Canvas(cols * cell + (cols + 1) * 16, rows * cell + (rows + 1) * 16, (18, 22, 20))
for i, p in enumerate(avail):
    im = load_png(os.path.join(tex, p + '.png'))
    s = min(cell / im[0], cell / im[1])
    x = 16 + (i % cols) * (cell + 16) + int((cell - im[0] * s) / 2)
    y = 16 + (i // cols) * (cell + 16) + int((cell - im[1] * s) / 2)
    g.blit(im, x, y, s, checker=True)
g.save(os.path.join(out, 'textures.png'))
