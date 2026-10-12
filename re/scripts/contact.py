"""Render every decodable texture of the extracted DIG tree into contact sheets."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
import textures, png

root, out, minsize = sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 64
os.makedirs(out, exist_ok=True)
items = []
for e in sorted(os.listdir(root)):
    for f in sorted(os.listdir(os.path.join(root, e))):
        if f == 'entry.bin':
            continue
        d = open(os.path.join(root, e, f), 'rb').read()
        try:
            for n, (w, h, rgba) in enumerate(textures.decode_all(d)):
                if max(w, h) >= minsize:
                    items.append((f'{e}/{f[:-4]}#{n}', w, h, rgba))
                    png.write_png(os.path.join(out, f'{e}_{f[:-4]}_{n:03d}.png'), w, h, rgba)
        except Exception as ex:
            print('skip', e, f, ex)
print(len(items), 'textures')
# Contact sheets: 8×6 cells of 128 px (nearest-neighbour scaled), checkerboard behind alpha.
CELL, COLS, ROWS = 128, 8, 6
for s in range(0, len(items), COLS * ROWS):
    page = items[s:s + COLS * ROWS]
    W, H = CELL * COLS, CELL * ROWS
    sheet = bytearray(W * H * 4)
    for i, (name, w, h, rgba) in enumerate(page):
        cx, cy = (i % COLS) * CELL, (i // COLS) * CELL
        scale = max(w, h) / CELL
        for y in range(CELL):
            for x in range(CELL):
                sx, sy = int(x * scale), int(y * scale)
                bg = 200 if ((x // 8 + y // 8) & 1) else 120
                o = ((cy + y) * W + cx + x) * 4
                if sx < w and sy < h:
                    r, g, b, a = rgba[(sy * w + sx) * 4:(sy * w + sx) * 4 + 4]
                    sheet[o:o + 4] = bytes((int(r * a / 255 + bg * (1 - a / 255)), int(g * a / 255 + bg * (1 - a / 255)), int(b * a / 255 + bg * (1 - a / 255)), 255))
                else:
                    sheet[o:o + 4] = bytes((40, 40, 40, 255))
    png.write_png(os.path.join(out, f'_sheet_{s // (COLS * ROWS):03d}.png'), W, H, bytes(sheet))
    with open(os.path.join(out, f'_sheet_{s // (COLS * ROWS):03d}.txt'), 'w') as f:
        f.write('\n'.join(n for n, *_ in page))
