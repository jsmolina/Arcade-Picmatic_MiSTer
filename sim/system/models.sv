// Behavioural stand-ins used by tb_system: clocks, SDRAM chip port, HPS, Altera IP, video out.
`timescale 1ns/1ps

//------------------------------------------------------------------------------
// PLL: 113.5 MHz and 28.375 MHz, edge-aligned like the real outclk_0/outclk_1

module pll
(
	input         refclk,
	input         rst,
	output reg    outclk_0 = 0,
	output reg    outclk_1 = 0,
	output        locked,
	input  [63:0] reconfig_to_pll,
	output [63:0] reconfig_from_pll
);
reg [1:0] n = 0;
always #4.405 begin
	outclk_0 = ~outclk_0;
	if (outclk_0) begin
		n = n + 1'd1;
		if (n[0]) outclk_1 = ~outclk_1;
	end
end
reg [7:0] lk = 0;
always @(posedge outclk_1) if (~&lk) lk <= lk + 1'd1;
assign locked = &lk;
assign reconfig_from_pll = 0;
endmodule

module pll_cfg
(
	input         mgmt_clk, mgmt_reset, mgmt_read, mgmt_write,
	output        mgmt_waitrequest,
	output [31:0] mgmt_readdata,
	input   [5:0] mgmt_address,
	input  [31:0] mgmt_writedata,
	output [63:0] reconfig_to_pll,
	input  [63:0] reconfig_from_pll
);
assign {mgmt_waitrequest, mgmt_readdata, reconfig_to_pll} = 0;
endmodule

//------------------------------------------------------------------------------
// SDRAM controller: only the chip port Minimig's 68000 path uses. Same slot timing as
// sdram_ctrl.v: a 16-state slot per 7 MHz cycle, request taken in state 0, data in state 9,
// the rest of the 4-word burst in states 11/13/15.

module sdram_ctrl
(
	input             sysclk,
	input             reset_n,
	input             c_7m,
	input             cache_rst,
	input       [3:0] cpu_cache_ctrl,
	input             dcache_sw_en,

	inout      [15:0] sd_data,
	output     [12:0] sd_addr,
	output      [1:0] sd_dqm,
	output      [1:0] sd_ba,
	output            sd_cs, sd_we, sd_ras, sd_cas, sd_cke, sd_clk,

	input      [15:0] cpuWR,
	input      [22:1] cpuAddr,
	input             cpuU, cpuL,
	input       [1:0] cpustate,
	input             cpuCS,
	output     [15:0] cpuRD,
	output            ramready,

	input      [15:0] chipWR,
	input      [24:1] chipAddr,
	input             chipU, chipL, chipRW, chipDMA,
	output reg [15:0] chipRD,
	output     [47:0] chip48,
	input             chip32,
	input      [15:0] chipWR2,
	output     [15:0] chipRD2
);
assign {sd_addr, sd_dqm, sd_cs, sd_ba, sd_we, sd_ras, sd_cas, sd_cke, sd_clk} = 0;
assign sd_data = 'Z;
assign {cpuRD, ramready, chipRD2} = 0;

reg [15:0] mem[int];
function [15:0] rd(input [24:1] a);
	rd = mem.exists(a) ? mem[a] : 16'h0000;
endfunction

integer    trace = 0, nw = 0, nr = 0;
initial if (!$value$plusargs("MEMTRACE=%d", trace)) trace = 0;

reg  [3:0] st;
reg        old_7m;
reg        act, rw;
reg [24:1] a;
reg [15:0] c48_1, c48_2, c48_3;
assign chip48 = {c48_1, c48_2, c48_3};

always @(posedge sysclk) begin
	old_7m <= c_7m;
	st <= st + 1'd1;
	if (~old_7m & c_7m) st <= 0;
	if (st == 0) begin
		act <= ~chipDMA | ~chipRW;
		rw  <= chipRW;
		a   <= chipAddr;
		if (~chipRW) begin
			reg [15:0] w;
			w = rd(chipAddr);
			if (!chipU) w[15:8] = chipWR[15:8];
			if (!chipL) w[7:0]  = chipWR[7:0];
			mem[chipAddr] = w;
			if (nw < trace) begin nw++; $display("[%0t] mem wr %06h <= %04h (U%b L%b)", $time, {chipAddr, 1'b0}, w, chipU, chipL); end
		end
	end
	if (act && rw) case (st)
		 9: begin
		 	chipRD <= rd(a);
		 	if (nr < trace && a[24:19] != 0) begin nr++; $display("[%0t] mem rd %06h => %04h", $time, {a, 1'b0}, rd(a)); end
		 end
		11: c48_1  <= rd({a[24:3], a[2:1] + 2'd1});
		13: c48_2  <= rd({a[24:3], a[2:1] + 2'd2});
		15: c48_3  <= rd({a[24:3], a[2:1] + 2'd3});
	endcase
end
endmodule

//------------------------------------------------------------------------------
// Denise colour table (altsyncram, registered address, old data on read-during-write)

module denise_colortable_ram_mf
(
	input   [3:0] byteena_a,
	input         clock,
	input  [31:0] data,
	input         enable,
	input   [7:0] rdaddress,
	input   [7:0] wraddress,
	input         wren,
	output reg [31:0] q
);
reg [31:0] m[256];
integer b;
always @(posedge clock) if (enable) begin
	q <= m[rdaddress];
	if (wren) for (b = 0; b < 4; b++) if (byteena_a[b]) m[wraddress][b*8 +: 8] <= data[b*8 +: 8];
end
endmodule

//------------------------------------------------------------------------------
// HPS: streams +ROM=<file> as ioctl index 0 after reset, like an MRA load. No disc, no OSD.

module hps_io #(parameter CONF_STR = "", CONF_STR_BRAM = 0, PS2DIV = 0, WIDE = 0, VDNUM = 1, BLKSZ = 2, PS2WE = 0)
(
	input             clk_sys,
	inout      [45:0] HPS_BUS,
	output reg [31:0] joystick_0 = 0,
	output reg [31:0] joystick_1 = 0,
	output      [1:0] buttons,
	output reg [127:0] status = 0,
	input      [15:0] status_menumask,
	output            forced_scandoubler,
	inout      [21:0] gamma_bus,
	output reg [24:0] ps2_mouse = 0,

	output reg        ioctl_download = 0,
	output            ioctl_upload,
	input             ioctl_upload_req,
	output reg [15:0] ioctl_index = 0,
	output reg        ioctl_wr = 0,
	output reg [26:0] ioctl_addr = 0,
	output reg  [7:0] ioctl_dout = 0,
	input       [7:0] ioctl_din,
	input             ioctl_wait,

	output reg        img_mounted = 0,
	output            img_readonly,
	output reg [63:0] img_size = 0,
	input      [31:0] sd_lba[VDNUM],
	input       [5:0] sd_blk_cnt[VDNUM],
	input             sd_rd,
	input             sd_wr,
	output reg        sd_ack = 0,
	output reg [13:0] sd_buff_addr = 0,
	output reg  [7:0] sd_buff_dout = 0,
	input       [7:0] sd_buff_din[VDNUM],
	output reg        sd_buff_wr = 0
);
assign {buttons, forced_scandoubler, ioctl_upload, img_readonly} = 0;

reg [7:0] rom[int];
integer   rom_len = 0;

initial begin
	string fn;
	integer fd, c, i;
	if ($value$plusargs("ROM=%s", fn)) begin
		fd = $fopen(fn, "rb");
		while ((c = $fgetc(fd)) != -1) begin rom[rom_len] = c[7:0]; rom_len++; end
		$fclose(fd);
	end
	$display("[hps] ROM image %0d bytes", rom_len);

	repeat (2000) @(posedge clk_sys);
	ioctl_index = 0;
	ioctl_download = 1;
	repeat (8) @(posedge clk_sys);
	for (i = 0; i < rom_len; i++) begin
		while (ioctl_wait) @(posedge clk_sys);
		ioctl_addr <= i; ioctl_dout <= rom[i]; ioctl_wr <= 1;
		@(posedge clk_sys); ioctl_wr <= 0;
		repeat (2) @(posedge clk_sys);
	end
	while (ioctl_wait) @(posedge clk_sys);
	repeat (8) @(posedge clk_sys);
	ioctl_download = 0;
	$display("[hps] ROM download done at %0t", $time);
end
endmodule

//------------------------------------------------------------------------------
// video out is captured inside tb_system; the scaler/mixer is not simulated

module video_mixer #(parameter LINE_LENGTH = 768, HALF_DEPTH = 0, GAMMA = 0)
(
	input CLK_VIDEO, ce_pix, scandoubler, hq2x, HSync, VSync, HBlank, VBlank, HDMI_FREEZE,
	inout [21:0] gamma_bus,
	input [7:0] R, G, B,
	output CE_PIXEL, freeze_sync,
	output [7:0] VGA_R, VGA_G, VGA_B,
	output VGA_VS, VGA_HS, VGA_DE
);
assign {CE_PIXEL, freeze_sync, VGA_R, VGA_G, VGA_B, VGA_VS, VGA_HS, VGA_DE} = 0;
endmodule

module video_freak
(
	input CLK_VIDEO, CE_PIXEL, VGA_VS, VGA_DE_IN,
	input [11:0] HDMI_WIDTH, HDMI_HEIGHT,
	output VGA_DE,
	output [12:0] VIDEO_ARX, VIDEO_ARY,
	input [11:0] ARX, ARY, CROP_SIZE,
	input [4:0] CROP_OFF,
	input [2:0] SCALE
);
assign {VGA_DE, VIDEO_ARX, VIDEO_ARY} = 0;
endmodule
