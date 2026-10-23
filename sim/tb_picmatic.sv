// picmatic.v against WinUAE's alg_joydat / alg_potgor / alg_bget (Picmatic branch), every flag
// combination, plus NVRAM byte access from the CPU and the HPS. Run: sim/run.sh picmatic
`timescale 1ns/1ps
module tb_picmatic;

reg clk = 0;
always #17.6 clk = ~clk;

reg         sel_nvram = 0, sel_io = 0, hwr = 0, lwr = 0, reset = 1;
reg  [23:1] addr = 0;
reg  [15:0] din = 0;
wire [15:0] dout;
reg   [8:1] reg_address = 0;
wire        joy_sel;
wire [15:0] joy_dout;
wire [15:0] serper;
reg   [9:1] flag = 0;
reg  [11:0] gun_x0 = 12'h345, gun_y0 = 12'h1A7;
reg  [11:0] gun_x1 = 12'hABC, gun_y1 = 12'h123;
reg  [11:0] nv_addr = 0;
reg   [7:0] nv_din = 0;
reg         nv_we = 0;
wire  [7:0] nv_dout;

picmatic dut
(
	.clk(clk), .clk7_en(1'b1), .reset(reset),
	.sel_nvram(sel_nvram), .sel_io(sel_io), .addr(addr), .din(din), .dout(dout), .hwr(hwr), .lwr(lwr),
	.reg_address(reg_address), .reg_din(16'd0), .joy_sel(joy_sel), .joy_dout(joy_dout), .serper(serper),
	.flag(flag), .gun_x0(gun_x0), .gun_y0(gun_y0), .gun_x1(gun_x1), .gun_y1(gun_y1),
	.nv_addr(nv_addr), .nv_din(nv_din), .nv_we(nv_we), .nv_dout(nv_dout)
);

// ---- WinUAE, alg_picmatic_nova == 1 ----
function [15:0] w_joydat(input integer joy, input [9:0] f);
	reg [15:0] v;
	v = 0;
	if (joy == 0) begin
		if (f & (16 | 32)) v |= 16'h0002;
		if (f & 4) v |= 16'h0200;
		if (f & 2) v |= (v & 16'h0200) ? 16'h0000 : 16'h0100;
		else       v |= (v & 16'h0200) ? 16'h0100 : 16'h0000;
		if (f & 8) v |= (v & 16'h0002) ? 16'h0000 : 16'h0001;
		else       v |= (v & 16'h0002) ? 16'h0001 : 16'h0000;
	end
	else begin
		if (f & 512) v |= 16'h0200;
		if (f & 64)  v |= 16'h0002;
		if (f & 256) v |= (v & 16'h0002) ? 16'h0000 : 16'h0001;
		else         v |= (v & 16'h0002) ? 16'h0001 : 16'h0000;
	end
	return v;
endfunction

function [15:0] w_potgor(input [9:0] f);
	reg [15:0] p;
	p = 16'h0000 | 16'h1000 | 16'h0100 | 16'h4000 | 16'h0400;   // userio's other POTGOR bits are 0 with nothing attached
	if (f & 128) p &= ~16'h1000;
	return p;
endfunction

function [7:0] w_btn(input [9:0] f);
	reg [7:0] v;
	v = 8'hFF;
	if (f & 64)  v &= ~8'h20;
	if (f & 128) v &= ~8'h10;
	if (f & 256) v &= ~8'h80;
	if (f & 512) v &= ~8'h40;
	return v;
endfunction

integer f, errs = 0;
task rd_io(input [3:0] r, output [7:0] v);
	begin
		@(negedge clk); sel_io = 1; addr = {8'hF6, r, 11'h000};   // byte read at $F6r001
		@(negedge clk); @(negedge clk); v = dout[7:0]; sel_io = 0;
	end
endtask

task wr_io(input [3:0] r, input [7:0] data, input odd);
	begin
		@(negedge clk);
		sel_io = 1;
		addr = {8'hF6, r, 11'h000};
		din = odd ? {8'h00, data} : {data, 8'h00};
		hwr = !odd;
		lwr = odd;
		@(negedge clk);
		hwr = 0;
		lwr = 0;
		sel_io = 0;
	end
endtask

reg [7:0] v;
initial begin
	repeat (2) @(negedge clk);
	reset = 0;

	for (f = 0; f < 1024; f += 2) begin
		flag = f[9:1];
		reg_address = 8'h05; #1; if (!joy_sel || joy_dout !== w_joydat(0, f)) begin errs++; $display("FAIL JOY0DAT f=%03h got %04h want %04h", f, joy_dout, w_joydat(0, f)); end
		reg_address = 8'h06; #1; if (joy_dout !== w_joydat(1, f)) begin errs++; $display("FAIL JOY1DAT f=%03h got %04h want %04h", f, joy_dout, w_joydat(1, f)); end
		reg_address = 8'h0B; #1; if (joy_dout !== w_potgor(f))   begin errs++; $display("FAIL POTGOR f=%03h got %04h want %04h", f, joy_dout, w_potgor(f)); end
		rd_io(3, v); if (v !== w_btn(f)) begin errs++; $display("FAIL F63001 f=%03h got %02h want %02h", f, v, w_btn(f)); end
	end
	reg_address = 8'h18; #1; if (joy_sel) begin errs++; $display("FAIL joy_sel on SERDATR"); end

	// gun registers
	rd_io(0, v); if (v !== 8'h23) begin errs++; $display("FAIL initial gun Y lo %02h", v); end
	rd_io(1, v); if (v !== 8'hBC) begin errs++; $display("FAIL initial gun X lo %02h", v); end
	rd_io(2, v); if (v !== 8'hA1) begin errs++; $display("FAIL initial gun hi %02h", v); end

	// WinUAE writes reg6 to select lightpen 0; reg5 selects lightpen 1.
	wr_io(6, 8'hFF, 1);
	rd_io(0, v); if (v !== 8'hA7) begin errs++; $display("FAIL selected gun0 Y lo %02h", v); end
	rd_io(1, v); if (v !== 8'h45) begin errs++; $display("FAIL selected gun0 X lo %02h", v); end
	wr_io(5, 8'hFF, 1);
	rd_io(0, v); if (v !== 8'h23) begin errs++; $display("FAIL selected gun1 Y lo %02h", v); end
	rd_io(1, v); if (v !== 8'hBC) begin errs++; $display("FAIL selected gun1 X lo %02h", v); end
	rd_io(2, v); if (v !== 8'hA1) begin errs++; $display("FAIL selected gun1 hi %02h", v); end
	wr_io(0, 8'h01, 1);
	if (dut.picmatic_io !== 8'h01) begin errs++; $display("FAIL Picmatic player select %02h", dut.picmatic_io); end

	// NVRAM: byte write on the even and the odd address of a word, both land in the same byte
	@(negedge clk); sel_nvram = 1; addr = {8'hF4, 15'h0123}; din = 16'h5A00; hwr = 1;
	@(negedge clk); hwr = 0; sel_nvram = 0;
	nv_addr = 12'h123; @(negedge clk); @(negedge clk);
	if (nv_dout !== 8'h5A) begin errs++; $display("FAIL nvram via hps %02h", nv_dout); end
	@(negedge clk); sel_nvram = 1; din = 16'h00C3; lwr = 1;
	@(negedge clk); lwr = 0;
	@(negedge clk); @(negedge clk); if (dout !== 16'hC3C3) begin errs++; $display("FAIL nvram cpu read %04h", dout); end
	sel_nvram = 0;
	// HPS load, CPU read back
	@(negedge clk); nv_addr = 12'h010; nv_din = 8'h99; nv_we = 1;
	@(negedge clk); nv_we = 0; sel_nvram = 1; addr = {8'hF4, 15'h0010};
	@(negedge clk); @(negedge clk); if (dout !== 16'h9999) begin errs++; $display("FAIL nvram load %04h", dout); end

	if (errs) $fatal(1, "%0d errors", errs);
	$display("PASS tb_picmatic");
	$finish;
end

endmodule
