#!/bin/sh
# Verilator lint of the whole core (top: emu). VHDL entities and Altera IP are stubbed.
#   sim/lint/lint.sh [extra verilator args]
set -e
cd "$(dirname "$0")/../.."

files=$(python3 -I - <<'EOF'
import re, os
def walk(qip, base):
    out = []
    for line in open(qip):
        m = re.search(r"-name (QIP_FILE|VERILOG_FILE|SYSTEMVERILOG_FILE)\s+(\[file join \$::quartus\(qip_path\)\s+(\S+)\s*\]|(\S+))", line)
        if not m:
            continue
        rel = m.group(3) or m.group(4)
        path = os.path.normpath(os.path.join(base, rel)) if m.group(3) else rel
        if m.group(1) == "QIP_FILE":
            out += walk(path, os.path.dirname(path))
        else:
            out.append(path)
    return out
stubbed = {"rtl/denise_colortable_ram_mf.v"}
print(" ".join(f for f in walk("files.qip", ".") if f not in stubbed))
EOF
)

sys="sys/hps_io.sv sys/video_mixer.sv sys/scandoubler.v sys/hq2x.sv sys/gamma_corr.sv sys/video_freak.sv sys/iir_filter.v sys/math.sv"

verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
	-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNUSEDPARAM -Wno-PROCASSINIT \
	-Wno-IMPLICITSTATIC -Wno-GENUNNAMED -Wno-EOFNEWLINE -Wno-PROCASSWIRE \
	-Isys -Irtl -Irtl/ld/core_jpeg -Irtl/fx68k \
	--top-module emu sim/lint/stubs.v sim/lint/stubs_vhdl.v sim/dpram.v $sys $files "$@"
