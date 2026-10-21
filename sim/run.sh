#!/bin/sh
# Build and run one Verilator testbench: sim/run.sh <name> [+plusargs]  (sim/tb_<name>.sv)
# Sources each bench needs are listed in its case below.
set -e
cd "$(dirname "$0")/.."
name=$1
shift
obj=${OBJ_DIR:-/tmp}/picmatic_sim_$name

case $name in
	ld_player) src="rtl/ld_player.sv" ;;
	uio_boot)  src="rtl/uio_boot.sv rtl/userio.v" ;;
	picmatic)  src="rtl/picmatic.v sim/dpram.v"
	           flags="-Wno-PINMISSING" ;;  # sim dpram has no default pin values
	ld_video)  src="rtl/ld_video.sv rtl/ld/dlv_streamer.v rtl/ld/jpeg_frame_decoder.v rtl/ld/fb_writer.v rtl/ld/ddram.sv rtl/ld/core_jpeg/*.v"
	           flags="-Wno-fatal" ;;  # vendored core_jpeg/ddram lint noise
	*) echo "unknown bench $name"; exit 1 ;;
esac

verilator --binary --timing -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
	-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-PROCASSINIT \
	-Wno-IMPLICITSTATIC $flags --Mdir "$obj" -Irtl -Irtl/ld/core_jpeg "sim/tb_$name.sv" $src --top "tb_$name" -o tb
"$obj/tb" "$@"
