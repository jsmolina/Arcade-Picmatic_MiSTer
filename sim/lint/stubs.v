// Altera IP stand-ins for Verilator lint only.

module pll
(
	input         refclk,
	input         rst,
	output        outclk_0,
	output        outclk_1,
	output        locked,
	input  [63:0] reconfig_to_pll,
	output [63:0] reconfig_from_pll
);
endmodule

module pll_cfg
(
	input         mgmt_clk,
	input         mgmt_reset,
	output        mgmt_waitrequest,
	input         mgmt_read,
	output [31:0] mgmt_readdata,
	input         mgmt_write,
	input   [5:0] mgmt_address,
	input  [31:0] mgmt_writedata,
	output [63:0] reconfig_to_pll,
	input  [63:0] reconfig_from_pll
);
endmodule

// altsyncram with defparams
module denise_colortable_ram_mf
(
	input   [3:0] byteena_a,
	input         clock,
	input  [31:0] data,
	input         enable,
	input   [7:0] rdaddress,
	input   [7:0] wraddress,
	input         wren,
	output [31:0] q
);
endmodule
