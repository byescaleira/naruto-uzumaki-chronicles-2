# Reverse-engineering notes — Naruto: Uzumaki Chronicles 2 (PAL, SLES-55090)

All findings come from `SLES_550.90` (sha256 `a37d6664…3ac6`) analysed with **REA 6.4.0**
on **Ghidra 12.1.4** + **ghidra-emotionengine-reloaded v2.1.38** (language `r5900:LE:32:default`).

## Tooling

| Path | What |
| --- | --- |
| `re/rea` | REA CLI bound to Ghidra + the R5900 language (`REA_GHIDRA_LANGUAGE_ID`). |
| `re/tools/rea-ps2/` | Local copy (git-ignored; recreate with `cp -R` of the global install + `patch -p1 < re/rea-r5900-lane.patch`) of `rea-agents@6.4.0` with one change in `dist/ghidra/GhidraMipsProfile.js`: an `elf32-exec-r5900-ps2-ee-v1` lane that admits R5900 ELF32 executables when the R5900 language is configured. Stock REA only admits MIPS32r2 o32 ELFs with `.MIPS.abiflags`. |
| `re/rea-daemon.mjs` | Keeps one REA MCP session (one live Ghidra database) open on `127.0.0.1:7391`. |
| `re/q` | `re/q <tool> '<json args>'` — query the daemon, prints the raw result. |
| `re/rea-batch.mjs` | Runs a JSON list of REA tool calls in one session. |
| `re/scripts/dig.py` | Python prototype of the DIG reader (reference for the Swift port). |

```bash
node re/rea-daemon.mjs re/bin/SLES_550.90   # ~90 s Ghidra auto-analysis, then instant queries
re/q procedure_pseudo_code '{"procedure":"0x1308c0"}'
```

The Ghidra install also needs the extension copied into
`/opt/homebrew/opt/ghidra/libexec/Ghidra/Extensions/` (REA reads its language catalog there).

## Disc layout

| File | Content |
| --- | --- |
| `SYSTEM.CNF` | `BOOT2 = cdrom0:\SLES_550.90;1`, `VMODE = PAL` |
| `SLES_550.90` | EE executable, ELF32 MIPS-III, `e_flags = 0x20924000` (R5900, EABI64), stripped |
| `CFC*.DIG` | Main archives, one per language (UK, FR, DE, ES, IT, and `*JP` = Japanese voices) |
| `XA/XA.AFS`, `XA/XAVOICE.AFS` (+ `XAJP/`) | CRI AFS, audio streams (ADX, `CRI_ADXI.IRX`) |
| `MV/MV00.DSI` | Movie stream — format not analysed yet |
| `N*.DIR` | Text lists of the archives per language |
| `*.IRX`, `IOPRP254.IMG` | IOP modules (pad, memory card, sound, ADX) |

## CFC.DIG

Language selection — `FUN_00127300`: switch on `FUN_001f6770()` (0…9) picks one of the 10
paths at `0x50c178…0x50c208`, then `FUN_001296b0(6, 0, path)`.

Index — `FUN_001296b0`: reads `6 << 11` = 0x3000 bytes (6 sectors) into the global index
buffer. 768 slots × 16 bytes:

| Offset | Type | Field |
| --- | --- | --- |
| 0x0 | u32 | start sector (×0x800) |
| 0x4 | u32 | stored size |
| 0x8 | u16 | sub-file count |
| 0xA | u16 | compressed flag |
| 0xC | u32 | expanded size |

Entry load — `FUN_001292e0`: raw entries are read sector-aligned through `FUN_001306b0`;
compressed ones are queued with `FUN_00130600` as **I/O command 7** in a 64-slot ring
(0x124-byte slots at `0x5298c0`) and handled by the I/O thread `FUN_00130bc0`.

Decompression — `FUN_00130bc0` case 7 + `FUN_001308c0`:

- stored bytes are streamed in 0x9000-byte chunks (double-buffered at `0x52e400`);
- 256 history counters at `0x540400` are zeroed per entry; history table at `0x540500`
  (256 contexts × 32 × u32);
- 9-bit codes LSB-first, 1 byte + 1 bit per code, bit position reset per chunk;
- bit 8 set → literal; clear → copy `(code & 7) + 1` bytes from
  `history[context][(code >> 3) & 31]`;
- after each code: `history[context][counter++ & 31] = start`, `context = last byte`.

Validated: all 688 entries of all 10 `CFC*.DIG` expand to their declared size with a
consistent sub-file table (`uc-tool dig verify`).

Expanded entry — sub-file table of `{u32 index, u32 size, u32 offset, u32 0}` × count;
empty sub-files may share an offset; entries are 16-byte padded at the end.

## Open questions / next targets

- Sub-file formats: palettes (`*_3d` alpha ≤ 0x80, PS2 GS convention) seen in entry 1;
  identify textures (TIM2/raw GS), models (VIF/GIF packets), motions (`"old motion file"`
  string), scripts, text.
- What reads each entry: trace callers of the request API (`FUN_001292e0` queue producers).
- `MV00.DSI` container and codec.
- Game logic tick rate (PAL 50 Hz) vs the 60 Hz reimplementation.

## Textures (UI / sprite sub-files)

Decoded by `re/scripts/textures.py` + `re/scripts/gs.py` (3651 textures ≥ 64 px in `CFC_UK.DIG`).

- Texture table: N × 20 bytes `{u16 image, u16 -1 ×3, u16 clut, u8 1, u8 1, u32 0, u16 w, u16 h}`.
- Upload table (right after it): M × 16 bytes `{u32 0, u32 offset, u16 w32, u16 h32, u32 w32·h32/64}`;
  **offset is relative to the record itself**.
- Each upload is a PSMCT32 rect. Pixel uploads hold PSMT8 data (texture = 2·w32 × 2·h32,
  read back through the GS PSMCT32 → PSMT8 swizzle); 16×16 uploads are 256-colour CSM1 CLUTs
  (swap index bits 3/4, alpha 0x80 = opaque).
- Draw packets in the same files carry `TEX0` with relative TBP/CBP (patched at load time).

Notable sets: `0039/00` #1 character-select face atlas (Naruto top-left), `0041/01` full-body
art, `0014/36` + `0216/00` #4 green karakusa menu pattern, `0057…0068/00` loading screens.

## App icon

`re/scripts/MakeIcon.swift` builds `App/AppIcon.icon` (Icon Composer) and the tvOS brand
assets from `0039/00` #1 and `0216/00` #4:

```bash
python3 -I re/scripts/contact.py <dig-extract-dir> <tex-out-dir> 64
swiftc -O re/scripts/MakeIcon.swift -o .build/make-icon
.build/make-icon <tex-out-dir>/0039_00_001.png <tex-out-dir>/0216_00_004.png .
```

## 2D sprites (menus, HUD, loading screens)

Sprite files are DIG sub-files with a **section table** `{u32 count, {u32 offset, u32 size} × count}`
(offsets from the table; `FUN_001bf610(file, n)` returns section `n`). Type-2 files have two sections:
an **animation bank** and a **texture set**. `uc-tool sprite scan` finds 98 of them in `CFC_UK.DIG`
(PSMT8 and PSMT4 only).

### Animation bank (section 0)

`u32 0x8001`, then at `base = section + 4` (the pointer `FUN_00262b50` keeps):
`u16` frame / animation / key / piece counts, 8 reserved bytes, `u32` offsets (from `base`) of the tables.

| Table | Stride | Fields |
| --- | --- | --- |
| frame | 12 | `u16 firstPiece, u16 pieceCount, s16 x, y, w, h` (bounds) |
| animation | 12 | `u16 firstKey, u16 keyCount, …, u8 flags @8` (bit 0 = morph between frames) |
| key | 32 | `s16 frame, u16 duration, u16 durationMax, u16 event, f32 scale x/y, f32 translate x/y, s16 rotation, u16 nextAnimation, u16 nextKey (relative), u8 alpha` |
| piece | 32 | `u16 texture, u16 ?, s16 x, y, u16 u, v, uw, vh, s16 w, h, u8 transformFlags, u8 alpha, s16 pivot x/y, s16 rotation, u8 blend @1c, u8 flip @1e` |

- `FUN_002627d0` starts an animation (key = first key, ticks = duration, random up to durationMax via
  `FUN_001e2fd0` = `rand() & 0xFFF`, scaled `>> 10`). `FUN_002623f0` is the per-frame tick;
  `FUN_00262570` steps (returns the key's `event`, 1 on the last key). When `nextAnimation` differs,
  the step indexes the animation table with the *key* index (game quirk, reproduced); the draw path
  interpolates towards `animations[nextAnimation].firstKey`.
- `FUN_0025e9d0` draws: `t = remaining·1024/duration`; scale, translation, rotation and key alpha
  interpolate `target + t·(current − target)/1024`. Morph animations also lerp each piece's corners
  and alpha with the target key's frame.
- `FUN_002618d0` corners: half-size box (flip negates), piece rotation, `+ (w/2 + x, h/2 + y)`, then
  key scale + rotation (around `pivot` if `transformFlags ≠ 0`: bit 0 no scale, 1 no rotation,
  2 pivot unscaled, 3 pivot unrotated), `+ translation`, optional instance mirror. 4096 = one turn.
- `FUN_00260a40` emits per piece: the texture's register packet, `CLAMP_1 = REGION_CLAMP [u, u+uw−1] ×
  [v, v+vh−1]`, TEX1 forced bilinear (`| 0x60`), `ALPHA_1` = 0x44 / 0x48 / 0x42 for blend 0 / 1 / 2
  (`FUN_001c92a0`), `TEST_1 = 0x317FD`, then a textured alpha-blended **TRIFAN** (`PRIM 0x55`),
  `RGBAQ = instance RGB, A = pieceAlpha · instanceAlpha · keyAlpha >> 14`, `ST = (texel·16 ± 8) /
  (16·2^TW)`, `XYZ = corner·16 + position + 0x8000`: the 2D origin is the **screen centre**, logical
  space **512 × 448** (NTSC lines). The PAL build multiplies y by 8/7 (`18.285715`, `1.1428572`) to
  fill 512 lines; the reimplementation keeps the 448-line space.

### Texture set (section 1)

`u32 N textures, u32 M uploads, 0, 0`; N × 0x50 register packets (GIFtag + A+D `CLAMP_1, MIPTBP1_1,
TEX1_1, TEX0_1`, `FUN_00342f50`); N × 20 records `{u16 level[4], u16 clut, u8 levels, u8 hasClut, u32 0,
u16 w, u16 h}` (`FUN_00342f68`); M × 16 uploads `{u32 0, u32 offset (from the record), u16 w, u16 h,
u16 blocks, u16 tbp}` (`FUN_00342f98`). `FUN_001d06e0` allocates GS memory per upload
(`FUN_001d1f00`), patches TBP0 / CBP / MIPTBP1, and `FUN_001d0bc0` uploads each one as a **PSMCT32**
IMAGE transfer (`DBW = ⌈w/64⌉`). The GS samples them with the packet's `TEX0` (PSMT8 or **PSMT4**,
CSM1, CT32 CLUTs). `GSLocalMemory` in UCFormats replays exactly that. Earlier decoders missed
`0040/00` (the title screen) because it mixes PSMT4 textures.

The PSMT8 column table used before had rows 2–3 / 10–11 wrong (pairs of pixel groups swapped → dotted
outlines on ~3 % of pixels); fixed in `GSSwizzle` and `re/scripts/gs.py`, checked against the classic
unswizzle formula in the tests.

### Objects and the title module

- Object (`FUN_00265ab0`, 0x4C bytes) with layers (`FUN_002644f0`, 0x94 bytes): layer = animation
  instance + anchor (centre of another animation's bounds) + alignment + position (`FUN_00264060`),
  flags (`FUN_00263410` / `FUN_00263480`: 0x20 hidden, 0x8 paused, 0x4 hold on first key, 0x80
  absolute), priority (`FUN_002634f0`). `FUN_00265390` ticks, `FUN_00265180` draws priority 0, 1, …
- `FUN_002d4120(n)` reads handles at `DAT_004da940` (`entry << 16 | sub-file`, the loader
  `FUN_001292e0` keys loaded entries by DIG index): `[1] = 40/0` title, `[2] = 40/1` mode select,
  `[4] = 12/3`, `[5] = 39/0` character select, `[6] = 14/0`.
- Title / main menu (`0040/00`): `FUN_001a9350` → task `FUN_001a8c30` (mode 0: 21 layers, animations
  0–9, 0xC–0x14, 0xA, 0x15); `FUN_001aac40` creates 3 items `FUN_001aa070(i, 0, 0)` (names "NEW GAME",
  "LOAD GAME", "OPTION" at `0x3523b0`, `{name, animation, -1, 0}`) → `FUN_001a9b90`: highlight 0x16
  anchored on 0x17 at `y = i·40`, labels 0x18–0x1A; `FUN_001aa3e0` plays "PRESS START BUTTON" (0x1B).
  Mode 1 (`FUN_002fcce0`, "STORY MODE" table at `0x3523e0`) uses `0040/01` + `12/3`.
- Tasks: `FUN_001e7de0(update, size, order, drawOrder, flags)`; `FUN_001e7980/7970/7950` set the draw /
  update / destroy callbacks of the current task.

Open: the menu items' own update/draw callbacks (`0x1a9750`, `0x1aa370`, not functions in the Ghidra
database), what each item starts, the 50 Hz vs 60 Hz tick of the 2D animations (the port ticks them at
60 Hz), the character select / versus / loading screen modules.
