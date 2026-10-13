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
| `MV/MV00.DSI` | The intro movie: MPEG-2 video + SPU ADPCM audio in 0x40000-byte blocks (see *Movie*) |
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
  identify textures (TIM2/raw GS), motions (`"old motion file"`
  string), scripts, text.
- What reads each entry: trace callers of the request API (`FUN_001292e0` queue producers).
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

## 3D models (character / stage sub-files)

Decoded by `ModelFile` / `ModelGeometry` / `ModelTextureTable` / `VIF` (UCFormats);
`uc-tool model scan|info|export`. 78 models in `CFC_UK.DIG`, all decoding with consistent skinning.

### Sectioned files

`u32 count` + `count × {u32 offset, u32 size}` (offsets relative to the sub-file). The first word
is therefore the section count, not a type: 0x14 (characters `0119…0144/00`) and 0x17 (entries
`0007…0009`, `0147…0219/00`, story/enemy/boss sets). `FUN_001bf610(file, i)` returns
`file + offset[i]` (null when out of range or zero). `FUN_001b7640` binds an actor:

| Section | Consumer | Content |
| --- | --- | --- |
| 0 | `FUN_0013e360` → `FUN_0013e3b0` → `FUN_0033f978` | skinned model (below) |
| 1 | same call (texture table) | materials + textures |
| 2 | `FUN_0013daf0` | motion: magic `"Mt"` (0x744D), version 0x01FF, coord count must match (`"No Match Model Coord"`) |
| 3 / 4 | `FUN_00139d40` / `FUN_00139d10` | ? |
| 5 | `FUN_0013d800`, `FUN_0013d730` | probably a UV-scroll table (`{u16 count, 12-byte records}`, stored at obj+0x1E4) |
| 6, 7, 0xF/0x10, 0x15, 0x16 | `FUN_0013e070`, `FUN_0013de50`, `FUN_0013dd50`, `FUN_0013da70`, `FUN_0013dac0` | ? |
| 9, 10 | `FUN_001b9f50` (0xF0-byte obj), `FUN_001baa40` (0xB0) | ? |
| 0xC, 0x12–0x14, 0x17–0x19 | `FUN_0016fdc0` (0xBC-byte obj each) | effect attachments? |

### Model section (section 0)

Header `{u32 partTable, u32 partCount, u32 boneCount, u32 ?(10)}`; `FUN_0033f978` stores
`coords = +0x10`, `parents = +0x10 + 0x40·boneCount`, `parts = +partTable`.

- **Bone (coord), 0x40 bytes:** `quat{x,y,z,w}`, `scale{x,y,z,1}`, `{0,0,0,1}` (unused so far),
  `translation{x,y,z,1}`. Parents: `i16` per bone, −1 = root (always `parent < index`).
- **Pose:** `FUN_00139a30` builds `FUN_00340d30(quat, scale, translation)` matrices and chains
  them `M_i = M_i × M_parent` with `FUN_00341c10` (row vectors, `v · M`). With column vectors
  this is `world = parent · T · R(q̄) · S` — the stored quaternion acts as its **conjugate**.
  The world is Y-down (feet at y = 0, Naruto's head at y ≈ −15).
- **Part, 0x20 bytes:** `+0 commands`, `+4 VIF data`, `+8 bounding points (16 B each)`,
  `+0xC bounding bone list (u32)`, `+0x10 u16 bounding count`, `+0x16 u8 material table select`,
  `+0x17 u8 binding count`, `+0x18 bindings {u16 material, u16 slot}`, `+0x1C u32 colour (0x80282828)`.
- **Commands** (`FUN_0013a9c0`, also library twin `FUN_0033e7f0`, unused): 6-byte records
  `{u8 kind, u8 slot, u16 index, u16 qwc}` until kind 0. For each, the EE emits a DMA CNT with an
  injected UNPACK, then a DMA REF of the next `qwc` quadwords of the part's VIF data:
  1 = 6 per-draw words + MSCAL 0x58; 2 = bone matrix `mats[index]` (4 qw) to VU addr 1;
  3 = normal matrix (3 qw, `+index·0x30`); 4/7 = material GIF packet of texture slot `slot`
  (`DAT_00548650[slot]`, filled by `FUN_0013a490`/`FUN_0013a710` from the bindings, which also
  upload the texture via `FUN_001d06e0`); 5 = engine packet `FUN_001cfe70(index)`; 6 = 1 qw per
  bone; 8 = environment matrix (3 qw, `+index·0x40`).

### VU1 microcode and the packet language

`FUN_001c46b0` (frame builder) DMAs a REF of 0x3E0 qw at `0x344400` once: VIF BASE/OFFSET,
GIF templates, then MPGs from `0x344570` (microcode ≈ `0x344578…0x348200`). Draw callbacks hang
from an ordering table at `0x54EEE0` (0x65F buckets). The microcode itself was not disassembled;
its programs were modelled from the packets and validated numerically (all multi-bone vertices
land on one point from every bone: max spread 0.07 units over all 78 models, 0 on Naruto).

Each MSCAL reads a header at VU qw 0; two arrays are interleaved with STCYCL 2,1
(odd qw = vector, even qw = index):

| MSCAL | Header | Records | Effect |
| --- | --- | --- | --- |
| 0x2E / 0x06 / 0x54 | V4-8 `{n, slot}` | — | store injected bone / normal / environment matrix at VU addr `slot` |
| 0x02, 0x04 / 0x1A, 0x1C | V4-8 `{n, slot, accumulate}` | S-8 dest idx, V4-32 `{x·w, y·w, z·w, w}` | `acc[idx] (+)= M_slot · v` (weight premultiplied, so the homogeneous product sums to the skinned point) |
| 0x08 / 0x0A | V4-8 `{n}` | S-8 idx | commit `acc[idx]` to the vertex table (transform/project) |
| 0x20 / 0x22 | V4-8 `{n, slot, 11, accumulate}` | V4-32 `{nx, ny, nz, int idx}` | normals through normal-matrix slot |
| 0x12 | V2-8 `{n, 15}` | V2-8 `{normal, colour}` | light a normal into colour slot |
| 0x24 / 0x28 | V2-8 / S-8 | + V4-32 RGBA (alpha 0x80 = 1) | lit colour with base RGBA / RGBA only |
| 0x0C | S-32 `{n}` | V3-32 `{s, t, int idx}` | UV table |
| 0x50, 0x4E / 0x52 | V2-32 scale / V4-8 `{n, slot}` | V4-32 `{n, int idx}` | sphere-map UVs from normals |
| 0x18 | V3-8 `{nTri}` | V3-8 `{vertex, colour, uv}` × 3·nTri | draw textured triangles (≤ 16 per batch) |
| 0x4C | V2-8 `{nTri}` | V2-8 `{vertex, colour}` | draw untextured triangles (PRMODE without TME) |
| 0x5C / 0x5E | — | — | enter / leave the additive environment pass (ALPHA 0x48 vs 0x44) |
| 0x14 | V4-32 GIFtag + A+D | — | GIF kick: PRMODECONT, PRMODE (0x78 = IIP+TME+FGE+ABE), ALPHA_1, material TEX0… |
| 0x2A, 0x32, 0x3C/0x3E/0x40, 0x58 | V4-32 / V3-32 | — | colour (255,255,255,128) / scale (1,1,1) constants, per-draw header |
| 0x26 | S-8 `{1, 0}` | — | unknown (34 calls, ignored) |

The tables persist across batches inside a part: later batches update only some vertices
(0x0A lists) and reuse the rest. Triangles reference UV/colour indices independently of the
vertex index (OBJ-style), so exporters must de-duplicate `{position, normal, uv, colour}`.

### Texture section (section 1)

`{u32 materials, u32 uploads, 0, 0}`, `materials × 0x50` GIF packets (GIFtag NLOOP 4 A+D:
CLAMP_1, MIPTBP1_1, TEX1_1, TEX0_1 with relative TBP/CBP), `materials × 20` records
`{u16 image[4] (0xFFFF = no level), u16 clut, u8 levels, u8 hasCLUT, u32 0, u16 w, u16 h}`
(record *i* belongs to material *i*), then `uploads × 16` PSMCT32 uploads
`{0, u32 offset (relative to the record), u16 w32, u16 h32, u16 qwc, u16 runtime TBP}`.
Accessors `FUN_00342f40` (count), `FUN_00342f50` (packet), `FUN_00342f68` (record),
`FUN_00342f98` (upload); `FUN_001d06e0` uploads and patches TBP0 (bits 0–13), CBP (37–50) and
MIPTBP1. Every model material is PSMT8 with a CSM1 16×16 CLUT (same swizzle as the UI textures).

### Which entry is which (UK disc, rest pose renders)

`0119/00` Naruto (`0120/00` same mesh, smaller motion section), `0121` Kakashi, `0122` Shikamaru,
`0123` Sakura, `0124` Neji, `0125` Rock Lee, `0126` Kankuro, `0128` Temari, `0130` Tsunade,
`0133` Itachi, `0134` Kisame, `0136` Might Guy, `0137` Kiba, `0138` Gaara, `0141`/`0142`/`0144`
Sound ninja (unconfirmed), `0143` untextured variant (16×16 placeholder textures);
`0007…0009/05` and `0158…0160` puppet-like enemies (likely Kankuro's puppets); `0147…0164`, `0193…0219` enemies/NPCs
(`0219` Konohamaru); `0174…0191` the 23-section versions of the cast (`0191` Sasuke);
`0169`/`0192` the golden mechanical boss; `0185` cloaked boss; `0194` weapon prop.

### Open

- Motions (section 2, `FUN_001e1300`: per-bone tracks of key times + translation/scale floats
  and quaternions as `s16 / 32767`, slerp via `FUN_003425e8`) — not decoded yet.
- Exact VU1 semantics (lighting, fog, clipping, MSCAL 0x26, header word 11/15) need the
  microcode disassembled; the environment pass UVs are approximated as a sphere map.
- Remaining sections (3–19, 21, 22) and the `{0,0,0,1}` coord vector.

## Audio (CRI ADX streams)

Both AFS archives hold only CRI ADX, all **encoding 3 (standard), header version 4, 4-bit, 18-byte
frames, 48 kHz, high-pass cutoff 500 Hz, unencrypted** (`uc-tool adx info`):

| Archive | Entries | Layout | Loops | Names |
| --- | --- | --- | --- | --- |
| `XA/XA.AFS` (= `XAJP/XA.AFS`, byte-identical) | 131 | 110 stereo, 21 mono | 94 | `bg000…bg130.adx` |
| `XA/XAVOICE.AFS` (English) | 2002 | 19 stereo, 1983 mono | 0 | `xavoi0000…xavoi2000.adx`, `xavoiLAST.adx` |
| `XAJP/XAVOICE.AFS` (Japanese) | 2002 | 31 stereo, 1971 mono | 0 | same names |

No AHX, no other codec. The AFS name table's last u32 is not a size: it repeats the TOC words
shifted by one (record *i* holds TOC word *i*: count, offset 0, size 0, …).

### Opening and playing

- `FUN_0012b8c0` (sound init): `FUN_00127930(0,1,0,0)` / `FUN_00127930(1,0,0,0)` create two
  ACSSND/ADXT channels at 48000 Hz (`ERROR: Can't create ADXT/ADXCS` on failure); then, with
  `FUN_001f67c0() == 1` (Japanese voices) `\xajp\xa.afs` + `\xajp\xavoice.afs` (`0x50c700`, `0x50c710`),
  else `\xa\xa.afs` + `\xa\xavoice.afs` (`0x50c6d8`, `0x50c6f0`), are loaded as ADXF partitions 0
  and 1 by `FUN_00127af0(ptid, path, files)` with 0x82 / 0x7d2 files (`FUN_0031c418` =
  `ADXF_LoadPartitionNw`, polled until state 3).
- Channel table at `0x51fbd0`, 2 × 0x18 bytes: `+0` path, `+8` ADXT handle, `+0xC` partition
  info, `+0x10` work buffer. Wrappers: `FUN_00127c80(ch, index, fade)` start (`FUN_003277e8` =
  start from AFS; fade-in parameters 0x3c/0x5a when `fade`), `FUN_00127e10(ch, fade)` stop,
  `FUN_00127bc0` volume, `FUN_00127f20` is-stopped, `FUN_00128010(ch, vol, time)` volume ramp.
- **Play API `FUN_00129c60(ch, index, ?, fade, force)`** (ch 0 = music, 1 = voice): looks the
  stream up in the sound table, starts it and sets the level to
  `FUN_00128090((volume × channelLevel + 0x40) >> 7)`, `channelLevel` at `0x5215c8 + ch·16`
  (default 0x80). `FUN_00129c30(ch, fade)` stops.
- `FUN_00128090(level)` → ADXT attenuation in 0.1 dB: `a = 0x80 − level`; `a ≤ 0` → 0;
  `a ≤ 0x40` → a; `≤ 0x60` → 2a − 0x40; `≤ 0x70` → 4a − 0x100; `< 0x80` → 50a − 0x1520; else 999
  (`CRIVolume`).

### Sound table — DIG entry 567 (0x237), sub-file 0

Loaded by the sound task `FUN_0012b630` (asset id `0x2370000` = entry << 16 | sub-file, via
`FUN_00129280` / `FUN_00128f60`), kept at `gp-0x7b88` (`iGpffff8478`). `SoundTable` parses:
`+0x08` music table, `+0x10 u16` music count (131), `+0x12 u16` movie count (2), `+0x14..0x17`
bytes handed to `FUN_001da200`, `+0x18` movie table (`mv01`, `mv00`, volume 0x73), `+0x1C` voice
table, `+0x28 u16` voice count (2001). Records: `u32 name offset, u8 0, u8 0x10, u8 volume,
u8 channels`; record *i* ↔ AFS entry *i*. `channels` matches all 2002 voice files but is 2 for every
music record (21 music files are mono). `uc-tool adx table CFC_UK.DIG` lists them. The shipped sub-file is truncated inside the voice
names (≈ `xavoi1200`), so names are optional.

### Which music plays where (partial)

17 call sites of `FUN_00129c60`. Constant ones: `FUN_00164140` (staff-roll state, scrolls
DIG `0x2ab0001`) → **bg095** (293.7 s, no loop, the only track dated 2007 — PAL credits);
`FUN_002fcd90` → bg117; `FUN_001aaed0` → bg093 (51.9 s, after resetting both channel levels);
`FUN_001baf30` → bg037 (4.8 s jingle); `FUN_0023acd0` → bg087; `FUN_0023d730`/`FUN_0023dfa0` →
bg110. `FUN_0027ed40(i)` (10 callers, menu/scene states) plays `u16[10]` at `0x358590` =
{41, 100, 56, 57, 39, 59, 91, 37, 130, 126}. Voices are started with indices from data
(`FUN_0015a5a0`, `FUN_0015e330`, `FUN_001a9890`, `FUN_00248310`, …). Title-screen track: not
identified yet.

### ADX decoding as the game does it (EE side, `ADXB`)

- `FUN_00318538` = `ADXB_DecodeHeaderAdx` (`"E1060101 ADXB_DecodeHeaderAdx: "`); encodings ≥ 5 go
  to AHX (`"can't play AHX data by this handle"`).
- `FUN_0031a240(cutoff, rate, &c1, &c2)`: single-precision `a = √2 − cos(2π·cutoff/rate)`,
  `b = √2 − 1`, `c = (a − √((a+b)(a−b)))/b`, `c1 = (short)(2c·4096)`, `c2 = (short)(−c²·4096)`,
  truncated → **7400, −3342** for 500 Hz @ 48 kHz (vgmstream/ffmpeg round differently).
- `FUN_0031b430` (block decoder): `scale = ((u16 ^ key) & 0x1FFF) + 1` (key 0 when unencrypted,
  LCG `key = key·mul + add & 0x7FFF` per frame otherwise), stop at bit 15;
  `s = nibble·scale + ((c1·h1 + c2·h2) >> 12)`, clamped to 16 bits; high nibble first.
  ffmpeg's `adpcm_adx` omits the `+ 1` and differs by up to ~3700 LSB on loud tracks.
- `FUN_0031a6c0`: version ≥ 4 headers carry the **initial predictor history** at 0x18
  (`u16 h1, h2` ch 0; 0x1C ch 1), copied by `FUN_003273f0` — nonzero in 23 music tracks and 736
  Japanese voices.
- `FUN_0031a7f8` (loop info): block at 0x14 (v3) / 0x20 (v4) = `u16 inserted samples, u16 loop
  count (must be 1), u16, u16 type, u32 start sample, u32 start byte, u32 end sample, u32 end byte`;
  ignored unless the copyright offset is ≥ 0x2C / 0x38 (all voices have 0x24: no loop).
- `FUN_003272f8` allocates ADXB handles (16 × 0x3c at `0x4ea1c8`); `FUN_003276b8` runs them.

### Verification (`uc-tool adx verify`, release build, on a loaded machine)

- XA.AFS: 131/131 decode to exactly the header sample count, 1.18 G samples in 6.7 s; every loop
  start is frame-aligned and matches its start byte; 0.019 % of samples clip (hot masters, also
  clipped by ffmpeg).
- XAVOICE.AFS (EN 2002/2002, 263 M samples; JP 2002/2002, 297 M samples), no silent entries.
- The playback path (`uc-tool adx mix`, AVAudioEngine offline) is bit-identical to the decoder
  across a loop jump.

## Movie (`MV/MV00.DSI`)

One movie: the 109.28 s intro (2732 frames). Found from the path string `\MV\MV00.DSI;1`
(`0x50c848`), referenced by a 2-entry table at `0x34c3d0` (0x14 bytes each:
`{char *path, u32 width = 512, u32 height = 448, u32 0x00740001, u32 seek flag}`; both entries
are the same file with the seek flag 0). `FUN_00131b30` starts playback of entry
`param[0xe]`: it calls `FUN_00128230(path, w, h, …)` and allocates three 512×448×4 frame
buffers. When an entry's seek flag is set it loads DIG entry 0x74 and takes a
`{u32 offset, u32 size}` pair from it, so the engine supports several movies in one DSI; this
disc does not use it.

Player task (`FUN_00128230` → state machine at `LAB_001288e0`):

- `FUN_00128840`: 1 MiB ring = 4 × 0x40000 blocks (`FUN_001bf7f0(ring, buf, 4, 0x40000, 2)`),
  sinks registered by stream id with `FUN_001bf7c0`: **0xFFFFC000 → video** (`+0x6c`),
  **0xFFFFE000 → audio** (`+0x50`); `FUN_001bf6e0` queues the file read (I/O ring at `0x54a420`).
- `FUN_001bfa20` finds a sink's chunk in a block: `u32 count`, then `count × {u32 offset,
  s32 stream id, u32 size}` from +4 (offset relative to the block). Data starts at 0x40;
  the rest of each block is zero padding. Every MV00 block holds one video then one audio chunk.
- Video: `FUN_001d8fe0(w, h)` creates the `sceMpeg` decoder (`FUN_00107f78` = `sceMpegCreate`
  on `0x553d00`, `FUN_00108390` = `sceMpegAddCallback`; `[MPEG ERROR]%s` at `0x50a628`) — the
  stock libmpeg / IPU path, so the stream is plain MPEG-2.
- Audio: `FUN_00128520` → `FUN_001d9960(1, 1, 0x5040, 0, 1, …, volL, volR, pull = FUN_001289b0,
  release = FUN_00128970)`, a 0x40-byte command (`0x20000`) on the ring at `0x5560c0` that
  `FUN_001da690` sends to the IOP sound server over SIF RPC (`FUN_0010d028`). Volumes are
  `vol × 0x3FFF >> 7`, mono when `DAT_00517488` (the sound option) is set.

| Stream | MV00 |
| --- | --- |
| Blocks | 205 × 0x40000 (53,739,520 bytes) |
| Video | 43,712,064 bytes, MPEG-2 MP@ML, 512×448, 25 fps, progressive, 3.2 Mbit/s nominal, 217 GOPs (≈ 12.6 frames each; I 217 / P 842 / B 1673), aspect code 1, PAL, BT.470 B/G colour tags, encoded by TMPGEnc 2.524, ends with a sequence end code. ffmpeg decodes it without errors. |
| Audio | 5,994,496 bytes, SPU ADPCM (16-byte frames, 28 samples), stereo interleaved every 0x100 bytes (L, R, L, R…), 5,245,184 samples per channel |

The audio rate is not in the file (it reaches the IOP at run time); **48 kHz** makes the audio
109.275 s for 109.280 s of video, and scene cuts line up with audio onsets with no drift over
the whole movie (at 44.1 kHz the audio would be 8.8 s longer). Display: the 512×448 frame
fills a 4:3 TV (round objects such as the opening sphere are only round at 4:3), so the pixel
aspect is 7:6 and the stream's "square samples" flag is wrong.

`UCFormats.DSIMovie` demuxes it, `MPEGVideoStream` summarises the video, `SPUADPCMDecoder`
decodes the audio; `uc-tool movie info|convert` (package time, ffmpeg) makes the HEVC/AAC file.
Default output: 512×448 HEVC Main10 (`hvc1`, CRF 18, 7:6 pixel aspect → AVFoundation presents
597⅓×448), BT.709 tags, 25 fps, AAC-LC 192 kbit/s 48 kHz stereo, faststart MP4: 24,976,508
bytes for MV00 (vs 53,739,520 for the DSI), byte-identical across runs; 2732 frames,
109.28 s video / 109.29 s audio (AAC priming handled by the edit list: 0-sample offset
against the decoded PCM), RGB SSIM 0.965 against the MPEG-2 source. `--height 1080`
pre-scales to 1440×1080 instead (61 MB at CRF 20).

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

- Title flow (state task chain, `FUN_001e7350` = next state): `FUN_001aaed0` (music, fade-in) →
  `FUN_001aae30` (one announcer line, `0x352490`) → `FUN_001aadd0` (900-frame idle timer) →
  `FUN_001aad00` (Start, pad bit 8 → `FUN_001aacc0` → `FUN_001aac40`: items, selection starts at 1 =
  LOAD GAME; idle → `FUN_001aa6b0`, attract) → `FUN_001aaa90`: up/down with repeat (`FUN_001db120`),
  decide 0x2000 → `FUN_001aaa20` (screen fade `FUN_001c4610(15)`, both channels `FUN_00129c30(ch, 15)`)
  → `FUN_001aa970`: NEW GAME `FUN_001d71a0` + `FUN_001aa550` (`FUN_002fadc0(0xf)`, `FUN_00137a80(0xf, 0)`:
  the story), LOAD GAME `FUN_00188c00` + memory card (`FUN_00170b80`), OPTION `0x1aa500`;
  cancel 0x4000 → back to PRESS START.
- Pad (`FUN_001db2a0` pressed, `FUN_001db120` repeat, libpad bits) with the decide swap on: physical
  ✕ (0x4000) → 0x2000 "decide", ○ (0x2000) → 0x1000, △ (0x1000) → 0x4000 "cancel". Start = 8,
  up 0x10 (| 0x10000 analog), down 0x40 (| 0x40000).
- SELECT MODE (title module mode 1, `0040/01`): `FUN_002fcd90` (bg117 = 0x75, fade-in 15) →
  `FUN_002fcce0`: 11 items `FUN_001aa070(i, 1, 1)`, table `{name, label animation, voice}` at
  `0x3523e0` (STORY MODE 0xF/0x70B, KAKASHI STORY 0x2F/0x730, MISSION 0x10/0x70C, CHALLENGE 0x11/0x70D,
  LEVEL UP 0x15/0x70E, GINOUBAKO 0x31/0x70E, ITEM SHOP 0x13/0x70F, OPTION 0x16/0x710, VS 0x12/0x711,
  EXIT 0x18/0x712, SAVE 0x17/0x713). `FUN_001a9b90` mode 1: label held (0xC) on layer 0, a copy on layer
  1 (priority 2) scaled 0 → 1 over 4 frames when selected; locked (`FUN_002f87b0/8760/8740/8720`) show
  0x30 "???". `FUN_001aa1d0`: wheel around the centre of animation 0x19, offset d → `(20d, 44d)` for
  |d| = 1 else `(20d, 40d)`, alpha 0x80 / 0x70 / 0x60, 0 for |d| = 3, hidden beyond; moves over 5 frames
  (`FUN_00263fe0`, `FUN_00263b90`). `FUN_002fc8c0`: up/down wrap, SE 0x7F move / 0x82 locked / 0x83
  confirm; EXIT → `FUN_002fc860` (yes/no dialog `FUN_002c3620(0xc, …)`); others → `FUN_002fc700` (fade,
  remembered selection `DAT_00517d40`). `FUN_001a9890` plays the item's voice on channel 1 once it is
  free. Backdrop `FUN_001a8c30` mode 1: animations 0–5, portraits (`FUN_001a9460`: 3 random unlocked
  characters of `0x352350` `{id << 8, animation}`; a new save has 0x000 Naruto 0x1F, 0x100 Kakashi
  0x20, 0x500 Kankuro 0x24) on layers 8, 7, 6 anchored on 0x2A / 0x2B / 0x2C, title 7, frame 9/10,
  arrows 0xB on 0xD / 0xC on 0xE, a text window (`FUN_00272150`, font `14/0` section 1) for the
  description from `12/3`.
- Layers draw in insertion order within a priority (`FUN_002660a0` appends to the list).

Open: the menu items' own update/draw callbacks (`0x1a9750`, `0x1aa370`, not functions in the Ghidra
database), the story start (`FUN_00137a80`), the options screen (`0x1aa500`), the SELECT MODE text
window and its `12/3` strings, the 50 Hz vs 60 Hz tick of the 2D animations (the port ticks them at
60 Hz), the character select / versus / loading screen modules.

## High-resolution package (format 3)

Not from the binary: a port-side addition. `uc-tool pack` runs Apple's VideoToolbox super-resolution
scaler (`VTSuperResolutionScalerConfiguration`, macOS 26 / iOS 26 only, scale factor 4 only, `64RGBAHalf`,
models downloaded once by the framework; tvOS has no such API) on:
- the intro, in video mode (sequential submissions), 512×448 → 2048×1792 with the 7:6 pixel aspect kept,
  libx265 CRF 20 medium: 131 MB, ~1.3 frames/s end to end;
- the 2D textures of the implemented screens (`0040/00`, `0040/01`), in image mode. The scaler returns
  opaque pixels, so colour (transparent texels bled from their neighbours) and alpha (as grey) run
  separately; a 16 px mirrored margin avoids seams where the game butts 256×256 tiles of one picture.

The app swaps `HD/<entry>_<sub>_t<n>.png` in for the decoded texture; texel coordinates stay normalised
by the original `TEX0` size, REGION_CLAMP is widened back to half a pixel of the upscaled layer, and the
atlas gets GPU-generated mipmaps. The atlas also scales each layer's coordinates into its padded slice
(smaller textures of a file used to be sampled as if they filled the slice).
