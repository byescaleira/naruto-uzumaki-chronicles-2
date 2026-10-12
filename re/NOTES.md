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
