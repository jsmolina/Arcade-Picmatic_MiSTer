# Picmatic LaserDisc arcade for MiSTer

Picmatic's 1993–1995 Spanish LaserDisc light-gun cabinets (Marbella Vice, Tierras Salvajes, Zorton
Brothers) were an Amiga 500 genlocked over a Sony LDP-1450 LaserDisc player. This core is that
cabinet: a cut-down [Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) A500
plus the LaserDisc video path from
[Arcade-LaserdiscGames_MiSTer](https://github.com/MiSTer-devel/Arcade-LaserdiscGames_MiSTer), with
board behaviour taken from WinUAE (`arcadia.cpp`).

Status: **untested on hardware.** The new blocks pass simulation (see *Simulation*) and the whole
core lints clean in Verilator, but it has not been through Quartus yet.

## What is inside

| Part | Where | Notes |
|---|---|---|
| A500: 68000, ECS, 512K chip, Kickstart 1.3 | Minimig `rtl/` | AGA/020/030/RTG/IDE/CD/floppy unused, config hard-wired |
| MRA boot | `rtl/uio_boot.sv` | Replays MiSTer Main's Minimig UIO protocol from the MRA download |
| Board: ROM at $F00000, 4K NVRAM at $F40000, I/O at $F60000, cabinet inputs | `rtl/picmatic.v`, `rtl/gary.v` | WinUAE `alg_bget`/`alg_joydat`/`alg_potgor` |
| Sony LDP-1450 player | `rtl/ld_player.sv` | Port of WinUAE `sony_serial_read`; real 8N1 at the game's SERPER rate |
| Disc video and audio | `rtl/ld_video.sv` + `rtl/ld/` | .dlv streamer, core_jpeg MJPEG decoder, DDR3 triple buffer |
| Genlock | `rtl/denise.v` (`zd`), `Picmatic.sv` | Amiga colour 0 shows the disc |
| Mouse light gun + crosshair | `Picmatic.sv` | First iteration; Sinden/GUN4IR later |

The disc picture is a 384x288 framebuffer read back one line per Amiga line, so one disc pixel is
one Amiga lores pixel and the Amiga beam drives everything: no scaler, and one clock (28.375 MHz)
for the whole disc path.

## Files you need

From the WinUAE Marbella Vice package:

* `amiga-os-130.rom` (Kickstart 1.3, CRC `c4f0f55f`)
* `picmatic_mv_u1.bin`, `picmatic_mv_u2.bin` (CRC `78eb6fd6`, `01c9a503`)
* the PAL LaserDisc capture, e.g. `Marbella_Vice_-_Picmatic_1994_Laserdisc_PAL_Spanish.avi`

Put the ROMs in `games/mame/marbvice.zip` (or the Kickstart in `kick13.zip`), copy
`releases/Marbella Vice.mra` to `_Arcade`, and convert the disc:

    tools/avi2dlv.py Marbella_Vice_-_Picmatic_1994_Laserdisc_PAL_Spanish.avi marbella_vice.dlv

(needs `ffmpeg` and `jpegtran`; about 1.2 GB). Put it in `games/Picmatic/` and mount it with
*Mount LaserDisc*.

## Controls

| | Mouse | Joystick |
|---|---|---|
| Aim | move | – |
| Trigger | left button | A |
| Holster (reload) | right button | B |
| Coin / Start / Service | – | Select / Start / X |

*Mouse/Joy 1 plays* picks the left or right gun position. Joystick 2 gives the other side
coin, start and trigger.

## Calibration (OSD)

* *Disc H/V position* moves the disc picture under the Amiga graphics.
* *Gun X/Y adjust* shifts what the game reads from the gun latch until shots land on the crosshair.

## Simulation

    sim/run.sh ld_player        # LDP-1450 protocol + serial, against WinUAE behaviour
    sim/run.sh uio_boot         # MRA boot through the real userio.v
    sim/run.sh picmatic         # board registers and inputs, all combinations vs WinUAE
    sim/run.sh ld_video +DLV=clip.dlv +FRAME=3 +PPM=out.ppm   # .dlv -> screen, then:
    sim/check_ld_video.py clip.dlv 3 out.ppm
    sim/lint/lint.sh            # whole core
    sim/system/run.sh +ROM=<tools/mkrom.py image> +FIELDS=150 +SNAP0=100   # boots the real ROMs

`doc/picmatic-plan.md` has the design study; `doc/Minimig-README.md` is the upstream README.

## Known gaps

* Not yet compiled in Quartus, so fit and timing are unknown. `core_jpeg` is upstream's; the
  LaserDisc core builds a locally tweaked copy (`*_flat` Huffman tables) that may matter for Quartus.
* LDP-1450 on-screen text (user index) is accepted and acknowledged but not drawn.
* Gun calibration defaults are guesses; the second gun is not wired.
* Only Marbella Vice has an MRA. Tierras Salvajes and Zorton Brothers use the same board.
