#!/bin/sh
# Whole-core simulation booting the real ROMs (see sim/tb_system.sv).
#   sim/system/run.sh +ROM=<mra rom image> +FIELDS=<n> [+SNAP0=<field> ...|+SNAPALL]
# The ROM image is what the MRA builds: Kickstart 1.3 twice, then the game ROM even/odd interleaved
# (tools/mkrom.py writes one from the dumps).
set -e
cd "$(dirname "$0")/../.."
obj=${OBJ_DIR:-/tmp}/picmatic_sim_system

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
modelled = {"rtl/denise_colortable_ram_mf.v", "rtl/sdram_ctrl.v"}
print(" ".join(f for f in walk("files.qip", ".") if f not in modelled))
EOF
)

if [ ! -x "$obj/tb" ] || [ -n "$REBUILD" ]; then
verilator --binary --timing -O3 --no-assert-case -Wno-fatal -Wno-lint -Wno-style -Wno-PINMISSING -Wno-MULTIDRIVEN \
	-Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-PROCASSWIRE -Wno-IMPLICITSTATIC -Wno-BLKANDNBLK \
	-Isys -Irtl -Irtl/ld/core_jpeg -Irtl/fx68k --top-module tb_system --Mdir "$obj" -o tb \
	sim/tb_system.sv sim/system/models.sv sim/lint/stubs_vhdl.v sim/dpram.v sys/iir_filter.v sys/math.sv \
	$files 2>&1 | grep -E "^%Error" || true
fi
# fx68k loads its microcode relative to the working directory; snapshots land here too
run=${RUN_DIR:-$obj/run}
mkdir -p "$run"
cp rtl/fx68k/microrom.mem rtl/fx68k/nanorom.mem "$run/"
cd "$run"
echo "run dir: $run"
"$obj/tb" "$@"
