// Picmatic arcade board glue (Marbella Vice, Tierras Salvajes, Zorton Brothers).
//
// Behaviour follows WinUAE arcadia.cpp for alg_picmatic_nova == 1:
//   $F40000-$F4FFFF  4 KB NVRAM, one byte per word: index = addr[12:1], byte access only
//   $F60000-$F6FFFF  board I/O, reg = addr[15:12]
//                      read (odd) reg0 = gun Y[7:0], reg1 = gun X[7:0],
//                                reg2 = {X[11:8],Y[11:8]}, reg3 = buttons (active low)
//   JOY0DAT/JOY1DAT/POTGOR carry coin, start, service, trigger and holster.
//
// flag[] uses WinUAE's alg_flag bit numbers:
//   1 service, 2 left start, 3 right start, 4 left coin, 5 right coin,
//   6 left trigger, 7 right trigger, 8 left holster, 9 right holster

module picmatic
(
	input             clk,
	input             clk7_en,
	input             reset,

	// cpu bus
	input             sel_nvram,
	input             sel_io,
	input      [23:1] addr,
	input      [15:0] din,
	output     [15:0] dout,
	input             hwr,
	input             lwr,

	// custom register bus
	input       [8:1] reg_address,
	input      [15:0] reg_din,
	output            joy_sel,       // replace userio's JOY0DAT/JOY1DAT/POTGOR read
	output reg [15:0] joy_dout,
	output reg [15:0] serper,        // Paula SERPER copy for the LaserDisc UART

	// cabinet
	input       [9:1] flag,
	input      [11:0] gun_x,
	input      [11:0] gun_y,
	output            gun_valid,
	output signed [15:0] calibration_x, calibration_y,

	// NVRAM load/save (HPS)
	input      [11:0] nv_addr,
	input       [7:0] nv_din,
	input             nv_we,
	output      [7:0] nv_dout
);

localparam JOY0DAT = 9'h00a;
localparam JOY1DAT = 9'h00c;
localparam POTGOR  = 9'h016;
localparam SERPER  = 9'h032;

//------------------------------------------------------------------------------
// NVRAM

wire [7:0] wbyte = hwr ? din[15:8] : din[7:0];
wire [7:0] nv_q;

dpram #(12,8) nvram
(
	.clock    (clk),
	.address_a(addr[12:1]),
	.data_a   (wbyte),
	.wren_a   (sel_nvram & (hwr | lwr)),
	.q_a      (nv_q),
	.address_b(nv_addr),
	.data_b   (nv_din),
	.wren_b   (nv_we),
	.q_b      (nv_dout)
);

//------------------------------------------------------------------------------
// $F6 board I/O

wire [3:0] reg_sel = addr[15:12];

// Both coordinate latches share the one mouse, as in the original core.
// PAL50 selects which physical gun is sensed using F60000 bit 0.
// Accept either byte lane; a word write is not a board byte transaction.
reg [7:0] io_control;
always @(posedge clk) begin
    if (reset) io_control <= 0;
    else if (clk7_en && sel_io && reg_sel == 0 && (hwr ^ lwr))
        io_control <= hwr ? din[15:8] : din[7:0];
end
assign gun_valid = io_control[0] ? !flag[9] : !flag[8];
// Mirror only calibration bytes, on the same writes as the real dual-port SRAM.
// No reset arm: NVRAM and its mirrors both survive a game reset. HPS restore
// uses linear nv_addr, CPU bytes use addr[12:1]. Low byte precedes high byte.
reg [7:0] calibration[0:7];
integer cal_i;
initial for (cal_i=0;cal_i<8;cal_i=cal_i+1) calibration[cal_i]=0;
always @(posedge clk) begin
    if (sel_nvram && (hwr || lwr) && addr[12:1]<12'd8)
        calibration[addr[3:1]] <= wbyte;
    if (nv_we && nv_addr<12'd8) calibration[nv_addr[2:0]] <= nv_din;
end
assign calibration_x = io_control[0] ? {calibration[5],calibration[4]} : {calibration[1],calibration[0]};
assign calibration_y = io_control[0] ? {calibration[7],calibration[6]} : {calibration[3],calibration[2]};
wire [7:0] btn = ~{flag[8], flag[9], flag[6], flag[7], 4'b0000};

reg [7:0] io_q;
always @(posedge clk) begin
	case (reg_sel)
		0: io_q <= gun_y[7:0];
		1: io_q <= gun_x[7:0];
		2: io_q <= {gun_x[11:8], gun_y[11:8]};
		3: io_q <= btn;
		default: io_q <= 8'h00;
	endcase
end

assign dout = sel_io ? {8'h00, io_q} : {nv_q, nv_q};

//------------------------------------------------------------------------------
// inputs on the custom register bus

assign joy_sel = (reg_address == JOY0DAT[8:1]) || (reg_address == JOY1DAT[8:1]) || (reg_address == POTGOR[8:1]);

// JOYxDAT: bit1/bit9 are set directly, bit0/bit8 are XORed with them (quadrature encoding).
wire [1:0] j0_lo = {flag[4] | flag[5], (flag[4] | flag[5]) ^ flag[3]};
wire [1:0] j0_hi = {flag[2],           flag[2] ^ flag[1]};
wire [1:0] j1_lo = {flag[6],           flag[6] ^ flag[8]};
wire [1:0] j1_hi = {flag[9],           1'b0};

always @(*) begin
	case (reg_address)
		JOY0DAT[8:1]: joy_dout = {6'd0, j0_hi, 6'd0, j0_lo};
		JOY1DAT[8:1]: joy_dout = {6'd0, j1_hi, 6'd0, j1_lo};
		default:      joy_dout = {1'b0, 1'b1, 1'b0, ~flag[7], 1'b0, 1'b1, 1'b0, 1'b1, 8'h00};
	endcase
end

always @(posedge clk) begin
	if (reset) serper <= 0;
	else if (clk7_en && reg_address == SERPER[8:1]) serper <= reg_din;
end

endmodule
