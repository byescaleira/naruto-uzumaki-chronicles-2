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
  identify textures (TIM2/raw GS), models (VIF/GIF packets), motions (`"old motion file"`
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
