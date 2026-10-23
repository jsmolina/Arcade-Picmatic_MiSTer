# Picmatic LaserDisc core for MiSTer: feasibility and plan

Target: Picmatic Marbella Vice (1994, PAL) first, then Tierras Salvajes and Zorton Brothers.
Sources studied: WinUAE `arcadia.cpp`, `memory.cpp`, `rommgr.cpp`, `serial_win32.cpp`, `drawing.cpp`
(master, Oct 2026); `Arcade-LaserdiscGames_MiSTer` @ `d948270`; this repo @ `ec1353d`;
the Marbella Vice WinUAE package in `~/Downloads/picmatic`.

---

## 1. Decision

**Make a new core, `Arcade-Picmatic`, forked from Minimig. Give it a standard MiSTer arcade
top level and copy in the LaserDisc subsystem from `Arcade-LaserdiscGames`.**
This is neither a pure Minimig fork nor a pure LaserDisc fork:

| Question | Minimig side | LaserDisc side | Winner |
|---|---|---|---|
| Who must be the video timing master? | Amiga beam drives the CPU, copper, blitter and light gun. It can't be slaved. | The LD raster is only a framebuffer reader, so it's easy to re-slave. | **Minimig** |
| Amiga chipset + 68000 | Mature and cycle-exact. Only an A500/ECS subset is needed. | None. | **Minimig** |
| Sony LDP-1450 serial protocol (the player Picmatic talks to) | None. | `ldp_ldp1450.sv` + `ldp_transport.sv`, ported from Daphne and used by Dragon's Lair II. | **LaserDisc** |
| Disc video from SD → MJPEG decode → DDR framebuffer | None. | `dlv_streamer.v`, `jpeg_frame_decoder.v`, `fb_writer.v`, `ddram.sv` | **LaserDisc** |
| Disc audio (44.1 kHz PCM, 2 channels, mute per channel) | None. | In `dlv_streamer.v`. | **LaserDisc** |
| Overlay over disc video | Denise has the colour index, so genlock "colour 0 = video" is natural. | It overlays tile chips (Cliff Hanger TMS9928A) on *its* raster. | **Minimig** |
| HPS / OSD integration | Main_MiSTer drives Minimig through a private protocol and OSD (`io_uio`/`io_fpga`, no `sd_*`). A `.dlv` can't be mounted without changing Main. | Standard `hps_io`: the MRA loads the ROMs, S0 mounts the `.dlv`, the MRA handles NVRAM. | **LaserDisc** |
| Upstream merges later | Chipset fixes (Denise, Agnus) merge cleanly if this is a git fork. | It's under heavy development: `DIAG-REVERT` tags everywhere, "Test Build" commits. | Fork Minimig, copy LD modules |

So: **fork this repo** to keep chipset history, **replace `Minimig.sv` with an arcade-style top
level**, delete everything an A500 doesn't need, and copy in about 8 modules from the LaserDisc core.
The LaserDisc core's top level (94 KB of multi-game glue) isn't reused.

Doing it the other way round means rebuilding the LD core's top level around an Amiga. The Amiga
needs a fixed PAL beam, its own SDRAM and the `host_*` boot path, and the LD core spends SDRAM on
Dragon's Lair II. That ends up with the same module set, plus a top level we'd have to remove.

---

## 2. What Picmatic hardware needs (from WinUAE)

Config from `Marbella_Vice_[Picmatic]_LEFT_PLAYER.uae`: **A500, 68000 (24-bit, cycle exact), ECS
Agnus, 512 KB chip RAM, no fast RAM, Kickstart 1.3, no floppy, no HDD, PAL 50 Hz, genlock mode `ld`.**

### Memory map
| Address | What | Notes |
|---|---|---|
| `F00000–F3FFFF` | Game ROM (ext ROM), 128 KB mirrored | `map_banks(F0, 4)`. Even = `u2`, odd = `u1`. **No descramble needed for this set**: after interleaving, `4AFC` is at `+8`. Verified. |
| `F40000–F4FFFF` | 4 KB NVRAM, one byte per word: `(addr>>1) & 0xFFF` | Picmatic ids 198/301/302/314/315. The ROM has 99 absolute refs to `F4xxxx`. |
| `F60000–F6FFFF` | Picmatic I/O, `reg = addr[15:12]` | Writes: reg0 = `picmatic_io` (bit0 = player select), reg5/reg6 = gun latch select P1/P2. Reads at odd addresses: reg0 = gun Y[7:0], reg1 = X[7:0], reg2 = {X[11:8], Y[11:8]}, reg3 = buttons (active low: b5 L trigger, b4 R trigger, b7 L holster, b6 R holster). The ROM also writes `F64000`, `F6F000`; WinUAE ignores those. |
| `F80000–FFFFFF` | Kickstart 1.3 (256 KB, mirrored) | As today. |

### Inputs (`alg_joydat`, `alg_potgor`, Picmatic branch)
- `JOY0DAT`: coin, left start, service, right start, encoded in quadrature bit pairs.
  Copy the XOR logic from WinUAE exactly.
- `JOY1DAT`: right holster, left trigger, left holster.
- `POTGOR`: bits 12/8/14/10 forced high. Bit 12 low = right trigger.
- Light gun X/Y in Amiga beam units (`x<<1 >> gfx_resolution`), read through F6 reg0–2.

### LaserDisc link
- **Paula UART ↔ Sony LDP-1450 command set.** WinUAE hooks `SERDAT` byte-wise
  (`ld_serial_read` / `ld_serial_write`, one RX byte per hsync at most).
- Commands used: 0x24/25 audio mute, 0x26/27 video on/off, 0x2B/2C step, `0`–`9` digits, 0x3A play,
  0x3B fast fwd, 0x3F stop, 0x40 enter, 0x41 clear, 0x43 search, 0x44 repeat, 0x46–0x49 CH1/CH2,
  0x4A/4B reverse, 0x4F still, 0x55 frame mode, 0x56 clear, 0x60 address inquiry, 0x67 status inquiry,
  0x73 mark, 0x80–0x82 + 0x00–0x02 user-index text overlay.
- **The ACK delay matters.** It's `hsync + 30` lines. Commit `23aa0a3` fixed a Zorton Brothers hang by
  *shortening* it. Seek completes after about 2 frames and sends 0x01, or 0x06 if there's no frame.
- `ldp_ldp1450.sv` already implements this set, ported from Daphne `ldp1000.cpp`. Only the delays
  need checking against WinUAE.

### Video
- Genlock: an Amiga pixel with colour index 0 is transparent and shows the disc. The border is
  transparent unless ECS `BRDNTRAN` is set. WinUAE's `genlock_offset_x=25` means the position
  needs to be adjustable.
- The disc is PAL at 25 fps. In the dump it's 720×576 XviD + PCM s16 44.1 kHz stereo, 36:00 long,
  54 000 frames. The 17-bit frame counter in the LD core is enough.

---

## 3. Target architecture

```
                       ┌─────────────── clk_sys (Minimig 28/114 MHz) ───────────────┐
 MRA ioctl ──► boot shim ──host_*──► minimig.v (A500/ECS, fx68k/TG68 68000)          │
 (KS1.3 + u2/u1 interleaved)        │  gary: F0-F3 ROM, F4 NVRAM, F6 picmatic_io      │
                                    │  paula txd/rxd ─┐       denise RGB + zd(idx==0) │
 hps_io joy/mouse/gun ─► picmatic_io (gun latch, JOYxDAT/POTGOR synth)               │
                                    └─────────────────┼──────────────┬───────────────┘
                                                      │ 9600 8N1     │ beam hpos/vpos, zd
                       ┌──── clk_ld (80 MHz) ─────────▼────┐   ┌─────▼──────────────────┐
 hps_io S0 (.dlv) ───► dlv_streamer ─► jpeg_frame_decoder  │   │ ld_genlock_reader      │
                       │   ▲ frame#      └► fb_writer ─────┼─► │ DDR line fetch per     │
                       │ uart ⇄ ldp_ldp1450 ⇄ ldp_transport│ DDR│ Amiga line, scaled x/y │
                       │   PCM L/R ──────────────────────┐ │   └─────┬──────────────────┘
                       └─────────────────────────────────┼─┘         │ LD RGB
                                                         ▼           ▼
                              paula audio + LD PCM mix   zd ? LD : Amiga ─► video_mixer
```

- **Clock domains.** Minimig keeps its PLL. The LD block runs on its own 80 MHz clock, which is
  `CLK_HZ` in every LD module. The crossings are just three: two UART lines (2-flop sync), the beam
  line strobe (pulse sync), and DDR through `ddram.sv`, which already runs on `DDRAM_CLK`.
- **DDR.** Minimig's `ddram_ctrl` exists for fast RAM, RTG and A2065, none of which are kept, so
  the LD framebuffer gets DDR to itself.
- **SDRAM.** Minimig only: chip RAM and ROM.

---

## 4. Keep / delete / import

### Delete (in the fork)
68020/030 + MMU + caches (`cpu_cache_new.v`, cycle tables, TG68K 020 paths), AGA-only Denise and
Agnus paths (keep ECS: a `aga=0` tie-off first, physical removal later), RTG and the `FB_*` scaler,
Akiko/CD32, CDTV (`cdtv_*` except `cdtv_nvram.v`), `cdda.v`, Gayle/IDE, A2065, `ddram_ctrl.v`,
MiSTer floppy (`MiSTerFloppy*`, `paula_floppy*`; tie disk DMA idle), `drive_sounds.v`, MT32-pi/MIDI,
`hps_ext.v`, the userio config path to Main, cart/HRTmon, fast RAM (`fastchip.v`), and the
Z2/Z3 autoconfig.

### Keep
`minimig.v` core (agnus*, denise*, paula* minus floppy, cia*, gary, bankmapper, m68k bridge,
sram bridge, syscontrol), the 68000 CPU, `sdram_ctrl`, `amiga_clk`/PLL, the `sys/` framework,
`cdtv_nvram.v` (reused as the 4 KB Picmatic NVRAM with `ADDR_W=12`).

### Import from Arcade-LaserdiscGames (copy into `rtl/ld/`, and record the source commit)
`ldp_ldp1450.sv`, `ldp_transport.sv`, `ldp_bus.svh`, `dlv_streamer.v`, `jpeg_frame_decoder.v`,
`fb_writer.v`, `ram_rom/ddram.sv`, `text_overlay.sv` + `ldp1450_font.hex` (phase 6),
`releases/scripts/pack_dlv.py` + `dlv_games.py`.
**`rtl/video/core_jpeg` is a dangling gitlink in that repo** (`bb03cce`, no `.gitmodules` entry,
the clone is empty). Pull `ultraembedded/core_jpeg` at that commit directly.

### New code (small)
| Module | What it does | Size |
|---|---|---|
| `emu` top (replaces `Minimig.sv`) | Standard `hps_io` (`VDNUM=1`, S0 = `.dlv`), CONF_STR, clocks, audio mix | M |
| `boot_shim.sv` | ioctl index 0 → `host_*` writes (KS at F8, game ROM at F0), holds CPU reset until done, hard-wired config (A500/ECS/512K/68000/PAL) | S |
| `picmatic_io.sv` | F6 decode, gun latch per player, button reg, JOY0/1DAT + POTGOR synthesis copied from WinUAE | S |
| gary/bankmapper edits | F0–F3 → ROM region, F4 → NVRAM, F6 → `picmatic_io` | S |
| `uart_bytes.sv` | Paula txd/rxd ⇄ byte `cmd_stb`/`tx_pop` for `ldp_ldp1450`. Baud as a parameter (9600) | S |
| Denise `zd` output | Colour index == 0 (and border unless `BRDNTRAN`), delayed to match the RGB pipeline | S, but needs care |
| `ld_genlock_reader.v` | Replaces `fb_raster_reader`: on each Amiga line, fetch the matching LD row from DDR into a ping-pong dual-clock line buffer, read it by Amiga hpos with x/y scale + offset (OSD knobs) | M |
| `dlv_streamer` 25 fps | Its pacing knows 23.976/29.97 only. `pack_dlv.py` itself says "laireuro 25 fps … core cannot play it yet" | S–M |

---

## 5. Phases (each ends with something runnable)

**Phase 0: Ground truth (no RTL)**
- Find out whether set **302** (the one we have) reads the gun through F6 regs 0–3, like the
  "100Hz TV" sets 314/315, or through the Amiga native light pen (`VHPOSR` latch with `LPEN`).
  WinUAE only implements F6 gun reads under `alg_picmatic_nova==1`, which includes 302, so F6 is the
  likely answer. Confirm by disassembling `F6xxxx` reads in the interleaved ROM, or by running WinUAE
  with `log_ld` and ALG logging on.
- Get the 100Hz-TV dumps (314/315) if possible. WinUAE's newest Picmatic work targets those.
- Exit: a one-page register trace of one attract loop plus one game start.

**Phase 1: Headless A500 boots the game ROM**
- Fork, add the new top level and boot shim, delete the cut list, keep the existing video out.
- MRA: KS1.3 + `picmatic_mv_u2`/`u1` interleaved, plus the `<nvram>` element.
- Exit: the attract-mode Amiga graphics show over black. The serial TX bytes (LDP commands)
  appear on a debug UART or signal tap.

**Phase 2: Disc subsystem standalone**
- Convert the AVI to `.dlv`: `ffmpeg` → 320×288 4:2:0 baseline MJPEG, no restart markers,
  1:1 frame mapping at 25 fps (disc frame N = AVI frame N + offset; find the offset in Phase 0).
  About 1 GB.
- Add 25 fps to `dlv_streamer`, wire `ldp_ldp1450` + `ldp_transport` + decoder + `fb_writer`, and
  show the framebuffer full screen with a temporary raster.
- Exit: OSD test commands (play, search 1234, still) work, and the audio is in sync.

**Phase 3: Serial link**
- `uart_bytes` between Paula and `ldp_ldp1450`. Match ACK delay, seek completion and status
  inquiry bytes to WinUAE (§2).
- Exit: the game drives the disc. Attract sequences play and seek correctly. Nothing hangs
  for 30 minutes.

**Phase 4: Genlock**
- Denise `zd`, `ld_genlock_reader` slaved to the Amiga beam, the output mux, and the
  `genlock_offset_x/y` + scale knobs.
- Exit: the Amiga HUD lines up over the video, matching a WinUAE screenshot to within one pixel.

**Phase 5: Inputs and NVRAM**
- `picmatic_io`, JOY/POTGO synthesis, NVRAM save through the MRA.
- Gun, first iteration: **mouse only**. `hps_io` PS/2 mouse deltas → absolute X/Y clamped to the
  visible beam window → F6 regs 0–2. Left button = trigger, right button = holster/reload.
  This is player 1 only, with no calibration beyond the genlock offset knobs.
  Sinden/GUN4IR (absolute analog) and player 2 come later and change only the X/Y source.
- Exit: a full game is playable with coin, start, shots registering and the holster reload.
  High scores survive a reboot.

**Phase 6: Polish**
- User-index text overlay (`text_overlay.sv`, LDP-1450 font) if the game uses it.
- Second player, 15 kHz / scandoubler options, MRAs for 314/315/198/301.

**Later (cheap once this works):** American Laser Games titles (Mad Dog McCree, Crime Patrol, Space
Pirates…). They use the same `arcadia.cpp` code: NVRAM at F5/F7, the player chosen through POTGO,
Sony serial too, discs at 29.97 NTSC (which `dlv_streamer` already supports). The ROMs are already in
`~/Downloads/picmatic/marbella_vice/ROMs`.

---

## 6. Risks and open questions

1. **Gun interface for set 302** (Phase 0). If it uses the Agnus light pen, Minimig needs `LPEN`
   latching in `agnus_beamcounter.v`, which it doesn't have today.
2. **FPGA fit.** The A500/ECS subset is far smaller than today's AGA + 030 + RTG build, and
   core_jpeg is a few thousand ALMs + DSP + BRAM. This is probably fine, but measure after Phase 2.
3. **JPEG throughput at 320×288×25.** That's about 8 % more pixels/s than the LD core's
   320×240×29.97. If it's too slow, drop to 288×288.
4. **Picture quality.** 320-wide video under a 640-wide hires HUD looks soft. That's acceptable
   (LaserDisc is about 330 TVL), and 384 wide is an option if decode throughput allows.
5. **Frame numbering.** The Sony frame numbers on the disc vs the AVI index offset, plus CAV/CLV
   behaviour. Check with search and address inquiry (0x60) against WinUAE.
6. **LD core churn.** Copy the modules at a pinned commit and port fixes deliberately. Don't track
   its HEAD.
7. **Legal/distribution.** The core and scripts are fine to publish. The ROMs, the KS1.3 ROM and the
   disc rip are user-supplied only.

## 7. Size estimate

Phase 0 S · Phase 1 M · Phase 2 M · Phase 3 S–M · Phase 4 M (hardest to get pixel-exact) ·
Phase 5 S–M · Phase 6 S. The riskiest steps are Phase 2 (25 fps streaming) and Phase 4 (genlock
alignment). The rest is mostly wiring.
