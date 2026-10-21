#!/usr/bin/env python3
"""Compare the field tb_ld_video captured with ffmpeg's decode of the same .dlv frame.

    check_ld_video.py clip.dlv FRAME captured.ppm

Passes when the picture is in place (best alignment is 0,0) and close to the reference
(core_jpeg's IDCT plus RGB565 differ from libjpeg by a few levels).
"""
import struct, subprocess, sys

dlv, frame, ppm = sys.argv[1], int(sys.argv[2]), sys.argv[3]
W, H = 384, 288

d = open(dlv, "rb").read()
idx_off = struct.unpack_from("<Q", d, 48)[0]
vid_off = struct.unpack_from("<Q", d, 64)[0]
off, size = struct.unpack_from("<II", d, idx_off + frame * 8)
jpg = d[vid_off + off: vid_off + off + size]
ref = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "mjpeg", "-i", "-", "-f", "rawvideo",
                      "-pix_fmt", "rgb24", "-"], input=jpg, stdout=subprocess.PIPE, check=True).stdout

raw = open(ppm, "rb").read()
got = raw[raw.index(b"255\n") + 4:]
assert len(got) == len(ref) == W * H * 3, (len(got), len(ref))


def err(dx, dy):
    tot = n = 0
    for y in range(8, H - 8, 4):
        for x in range(8, W - 8, 4):
            a = ((y + dy) * W + x + dx) * 3
            b = (y * W + x) * 3
            tot += sum(abs(got[a + c] - ref[b + c]) for c in range(3))
            n += 3
    return tot / n


best = min(((err(dx, dy), dx, dy) for dy in (-1, 0, 1) for dx in (-2, -1, 0, 1, 2)))
mae, dx, dy = best
print(f"mean abs error {mae:.2f} at offset ({dx},{dy})")
if (dx, dy) != (0, 0) or mae > 6:
    sys.exit("FAIL")
print("PASS check_ld_video")
