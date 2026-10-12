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
