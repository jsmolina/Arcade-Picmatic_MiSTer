module TG68KdotC_Kernel #(parameter sr_read = 2, parameter vbr_stackframe = 2, parameter extaddr_mode = 2, parameter mul_mode = 2, parameter div_mode = 2, parameter bitfield = 2, parameter barrelshifter = 1, parameter mul_hardware = 1)
(
	input clk,
	input nreset,
	input clkena_in,
	input [15:0] data_in,
	input [2:0] ipl,
	input ipl_autovector,
	input berr,
	input [1:0] cpu,
	input cpu030,
	output [31:0] addr_out,
	output [15:0] data_write,
	output nwr,
	output nuds,
	output nlds,
	output [1:0] busstate,
	output longword,
	input s21_en,
	output long_cand,
	input long_ack,
	input [15:0] data_in_hi,
	output [15:0] data_write_lo,
	output nresetout,
	output [2:0] fc,
	output clr_berr,
	output skipfetch,
	output [31:0] regin_out,
	output [3:0] cacr_out,
	output d_cache_out,
	output [31:0] vbr_out,
	output opc_start,
	output [15:0] opc_out,
	output opc_cond,
	output [15:0] opc_snd,
	output opc_dbx,
	output [13:0] opc_cacr,
	output mmu_busy
);
endmodule

module dpram_difclk #(parameter addr_width_a = 8, parameter data_width_a = 8, parameter addr_width_b = 8, parameter data_width_b = 8, parameter mem_init_file = "")
(
	input clock0,
	input clock1,
	input [addr_width_a-1:0] address_a,
	input [data_width_a-1:0] data_a,
	input enable_a,
	input wren_a,
	output [data_width_a-1:0] q_a,
	input cs_a,
	input [addr_width_b-1:0] address_b,
	input [data_width_b-1:0] data_b,
	input enable_b,
	input wren_b,
	output [data_width_b-1:0] q_b,
	input cs_b
);
endmodule

