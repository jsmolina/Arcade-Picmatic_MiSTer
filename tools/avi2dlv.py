#!/usr/bin/env python3
"""
avi2dlv.py -- pack a PAL LaserDisc capture (one video file, e.g. the WinUAE .avi) into the
.dlv v3 image the core streams from SD.

    avi2dlv.py Marbella_Vice_-_Picmatic_1994_Laserdisc_PAL_Spanish.avi marbella_vice.dlv

Disc frame N is video frame N: the WinUAE genlock seeks the .avi by frame number, so the
capture must start at disc frame 0 and run at 25 fps. Video is scaled to 384x288 (one
framebuffer pixel = one Amiga lores pixel, one row = one PAL line), audio to 44.1 kHz stereo.

JPEG scanning, validation and the jpegtran DHT fix come from pack_dlv.py (Arcade-LaserdiscGames).
Needs ffmpeg and jpegtran on PATH.
"""
import os, sys, struct, argparse, subprocess, tempfile
from multiprocessing import Pool, cpu_count

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pack_dlv import split_bounds, check_frame_compat, _jpegtran, ffmpeg_fps_flags, SECTOR, MAGIC, VER

SRATE, CHANS = 44100, 2
FPS = 25
FBUF_BYTES = 1 << 17          # dlv_streamer.v FBUF_AW = 17


def build(src, out, w=384, h=288, q=4, start=None, duration=None, deint=False, jobs=None):
    cut = (["-ss", str(start)] if start is not None else []) + \
          (["-t", str(duration)] if duration is not None else [])
    vf = ("yadif," if deint else "") + f"scale={w}:{h}:flags=lanczos"

    with tempfile.TemporaryDirectory() as tmp:
        mjpeg = os.path.join(tmp, "v.mjpeg")
        pcm = os.path.join(tmp, "a.pcm")
        # -threads 1: no restart markers (core_jpeg cannot decode them)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *cut, "-i", src,
                        "-an", "-threads", "1", *ffmpeg_fps_flags(), "-vf", vf,
                        "-pix_fmt", "yuvj420p", "-q:v", str(q), "-huffman", "default",
                        "-f", "mjpeg", mjpeg], check=True)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *cut, "-i", src,
                        "-vn", "-ar", str(SRATE), "-ac", str(CHANS), "-f", "s16le", pcm],
                       check=True)

        buf = open(mjpeg, "rb").read()
        bounds = split_bounds(buf, len(buf))
        check_frame_compat(buf[bounds[0][0]:bounds[0][1]], w, h, "frame 0 (pre-jpegtran)", strict_dht=False)

        with Pool(jobs or cpu_count()) as pool:
            res = pool.map(_jpegtran, ((i, buf[a:b]) for i, (a, b) in enumerate(bounds)), chunksize=16)
        res.sort()
        frames, last = [], None
        for i, data, status, err in res:
            if status != "ok":
                if last is None:
                    sys.exit(f"[fatal] frame {i} unusable: {err}")
                print(f"[warn] frame {i} unusable ({err}), holding frame {i - 1}")
                data = last
            frames.append(data)
            last = data
        check_frame_compat(frames[0], w, h, "frame 0")

        big = max(len(f) for f in frames)
        if big >= FBUF_BYTES:
            sys.exit(f"[fatal] largest frame {big} B does not fit the {FBUF_BYTES} B frame buffer; raise -q")

        n = len(frames)
        spf = SRATE // FPS                                   # 1764 samples per disc frame
        asize = n * spf * CHANS * 2
        audio = open(pcm, "rb").read()[:asize]
        audio += b"\0" * (asize - len(audio))

    index, off = bytearray(), 0
    for f in frames:
        index += struct.pack("<II", off, len(f))
        off += len(f)
    vsize = off

    def up(x):
        return (x + SECTOR - 1) // SECTOR * SECTOR

    idx_off = SECTOR
    vid_off = idx_off + up(len(index))
    aud_off = vid_off + up(vsize)

    hdr = bytearray(SECTOR)
    struct.pack_into("<4sIIII", hdr, 0, MAGIC, VER, w, h, n)
    struct.pack_into("<II", hdr, 20, FPS, 1)                 # disc rate 25/1
    struct.pack_into("<i", hdr, 28, 0)                       # disc frame 0 = video frame 0
    struct.pack_into("<IIQ", hdr, 32, SRATE, CHANS, n * spf)
    struct.pack_into("<QQ", hdr, 48, idx_off, len(index))
    struct.pack_into("<QQ", hdr, 64, vid_off, vsize)
    struct.pack_into("<QQ", hdr, 80, aud_off, asize)
    struct.pack_into("<II", hdr, 96, spf << 16, big)
    struct.pack_into("<I16s", hdr, 104, 0xFF, b"picmatic")

    def pad(f):
        f.write(b"\0" * ((-f.tell()) % SECTOR))

    with open(out, "wb") as f:
        f.write(hdr)
        f.write(index); pad(f)
        for fr in frames:
            f.write(fr)
        pad(f)
        f.write(audio)
    print(f"[dlv] {out}: {n} frames {w}x{h}, largest {big} B, {n / FPS:.1f} s")
    return n


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--size", default="384x288", help="WxH (must match ld_video.sv)")
    ap.add_argument("-q", type=int, default=4, help="ffmpeg mjpeg quality 2..31, lower is better")
    ap.add_argument("--start", type=float, help="seconds; only for test clips (breaks the frame map)")
    ap.add_argument("--duration", type=float, help="seconds")
    ap.add_argument("--deint", action="store_true", help="deinterlace before scaling")
    a = ap.parse_args()
    w, h = map(int, a.size.lower().split("x"))
    build(a.src, a.out, w, h, a.q, a.start, a.duration, a.deint)
