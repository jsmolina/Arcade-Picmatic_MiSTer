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
	input      [11:0] gun_x0,
	input      [11:0] gun_y0,
	input      [11:0] gun_x1,
	input      [11:0] gun_y1,

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
wire [7:0] io_wbyte = hwr ? din[15:8] : din[7:0];

reg [7:0] picmatic_io;
reg       gun_ply;
always @(posedge clk) begin
	if (reset) begin
		picmatic_io <= 0;
		gun_ply <= 0;
	end
	else if (sel_io && (hwr || lwr)) begin
		case (reg_sel)
			0: picmatic_io <= io_wbyte;
			5: gun_ply <= 0;
			6: gun_ply <= 1;
			default: ;
		endcase
	end
end

// WinUAE selects lightpen index 1 - gun_ply. The top level mirrors its single
// mouse aim into both inputs until a second independent gun is available.
wire [11:0] selected_gun_x = gun_ply ? gun_x0 : gun_x1;
wire [11:0] selected_gun_y = gun_ply ? gun_y0 : gun_y1;
wire [7:0] btn = ~{flag[8], flag[9], flag[6], flag[7], 4'b0000};

reg [7:0] io_q;
always @(posedge clk) begin
	case (reg_sel)
		0: io_q <= selected_gun_y[7:0];
		1: io_q <= selected_gun_x[7:0];
		2: io_q <= {selected_gun_x[11:8], selected_gun_y[11:8]};
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
