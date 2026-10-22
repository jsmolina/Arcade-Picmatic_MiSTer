#!/usr/bin/env python3
"""Build the ioctl index 0 image the MRA produces, for simulation or a manual load.

    mkrom.py kick13.rom game_even.bin game_odd.bin out.rom
    mkrom.py amiga-os-130.rom picmatic_mv_u2.bin picmatic_mv_u1.bin mv.rom   # Marbella Vice: u2 is even

Layout (rtl/uio_boot.sv): Kickstart 1.3 twice (256K each, $F80000/$FC0000), then the game ROM
with even/odd bytes interleaved ($F00000).
"""
import sys

kick, even, odd, out = sys.argv[1:5]
k = open(kick, "rb").read()
e, o = open(even, "rb").read(), open(odd, "rb").read()
assert len(k) == 262144, "Kickstart 1.3 must be 256K"
assert len(e) == len(o)
game = bytes(b for pair in zip(e, o) for b in pair)
open(out, "wb").write(k + k + game)
print(f"{out}: {len(k) * 2 + len(game)} bytes, game ROM tag at +8: {game[8:10].hex()}")
