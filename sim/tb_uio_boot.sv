// uio_boot driving the real userio.v: config registers, ROM placement, reset sequence.
// Run: sim/run.sh uio_boot
`timescale 1ns/1ps
module tb_uio_boot;

reg clk = 0;
always #17.6 clk = ~clk;
reg [1:0] div = 0;
always @(posedge clk) div <= div + 1'd1;
wire clk7_en = (div == 0);

reg reset = 1;

reg         ioctl_download = 0;
reg   [7:0] ioctl_index = 0;
reg  [24:0] ioctl_addr = 0;
reg   [7:0] ioctl_dout = 0;
reg         ioctl_wr = 0;
wire        ioctl_wait;

wire        io_uio, io_strobe, io_wait;
wire [15:0] io_din;

uio_boot dut
(
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr), .ioctl_wait(ioctl_wait),
	.io_uio(io_uio), .io_strobe(io_strobe), .io_din(io_din), .io_wait(io_wait)
);

wire        host_cs, host_we;
wire [23:0] host_adr;
wire  [1:0] host_bs;
wire [15:0] host_wdat;
wire [5:0]  chipset_config;
wire [7:0]  memory_config;
wire [4:0]  cpu_config;
wire        cpurst, cpuhlt, usrrst;

// bridge model: ack follows cs by 8 clocks
reg [7:0] cs_d = 0;
always @(posedge clk) cs_d <= {cs_d[6:0], host_cs};
wire host_ack = cs_d[7];

userio uio
(
	.clk(clk), .clk7_en(clk7_en), .reset(sys_reset),
	.reg_address_in(8'h00), .data_in(16'h0000), .data_out(),
	.pot_cnt_en(1'b0), ._fire0(), ._fire1(), ._fire0_dat(1'b1), ._fire1_dat(1'b1),
	._joy1(16'hFFFF), ._joy2(16'hFFFF), .joy_ana1(16'h0), .joy_ana2(16'h0),
	.mouse_btn(3'b000), .kbd_mouse_type(2'b00), .kms_level(1'b0), .kbd_mouse_data(8'h00),
	.aud_mix(),
	.IO_ENA(io_uio), .IO_STROBE(io_strobe), .IO_WAIT(io_wait), .IO_DIN(io_din),
	.memory_config(memory_config), .chipset_config(chipset_config), .floppy_config(),
	.floppy_ext_drive(), .user_port_mode(), .scanline(), .ar(), .blver(), .ide_config(),
	.cpu_config(cpu_config), .cache_config(), .usrrst(usrrst), .cpurst(cpurst), .cpuhlt(cpuhlt),
	.bootrom(),
	.host_cs(host_cs), .host_adr(host_adr), .host_we(host_we), .host_bs(host_bs),
	.host_wdat(host_wdat), .host_rdat(16'h0000), .host_ack(host_ack)
);

// minimig_syscontrol stand-in: reset while usrrst is held (config latches during reset)
wire sys_reset = reset | usrrst;

// memory model of the host writes
reg [15:0] mem[int];
always @(posedge clk) if (host_cs && host_we && cs_d[6] && !cs_d[7]) mem[host_adr] = host_wdat;

function [7:0] rom_byte(input [24:0] a);
	rom_byte = a[7:0] ^ a[15:8] ^ a[19:16] ^ 8'h5A;
endfunction

localparam [24:0] ROM_LEN = 25'h80000 + 25'h1000;   // both Kickstart copies + 4K of game ROM

integer a, saw_halt = 0, saw_usr = 0, errs = 0;
always @(posedge clk) begin
	if (cpuhlt) saw_halt = 1;
	if (usrrst) saw_usr = 1;
end

initial begin
	repeat (20) @(posedge clk);
	reset = 0;
	repeat (200) @(posedge clk);
	if (!cpuhlt) begin $display("FAIL: CPU not halted at power-on"); $fatal; end

	ioctl_index = 0;
	ioctl_download = 1;
	repeat (4) @(posedge clk);
	for (a = 0; a < ROM_LEN; a++) begin
		while (ioctl_wait) @(posedge clk);
		ioctl_addr <= a; ioctl_dout <= rom_byte(a); ioctl_wr <= 1;
		@(posedge clk); ioctl_wr <= 0;
		repeat (3) @(posedge clk);
	end
	while (ioctl_wait) @(posedge clk);
	ioctl_download = 0;
	repeat (100000) @(posedge clk);

	if (chipset_config != 6'h08) begin $display("FAIL: chipset_config %h", chipset_config); errs++; end
	if (memory_config[3:0] != 0) begin $display("FAIL: memory_config %h", memory_config); errs++; end
	if (cpu_config != 0)         begin $display("FAIL: cpu_config %h", cpu_config); errs++; end
	if (cpuhlt || cpurst)        begin $display("FAIL: CPU still held"); errs++; end
	if (!saw_usr)                begin $display("FAIL: no user reset"); errs++; end

	for (a = 0; a < 25'h80000; a += 2)
		if (mem[24'hF80000 + a] !== {rom_byte(a), rom_byte(a+1)}) begin
			if (errs < 8) $display("FAIL: kick %06h = %h", 24'hF80000 + a, mem[24'hF80000 + a]);
			errs++;
		end
	for (a = 0; a < 25'h1000; a += 2)
		if (mem[24'hE00000 + a] !== {rom_byte(25'h80000 + a), rom_byte(25'h80000 + a + 1)}) begin
			if (errs < 8) $display("FAIL: ext %06h = %h", 24'hE00000 + a, mem[24'hE00000 + a]);
			errs++;
		end
	if (mem.num() != (25'h80000 + 25'h1000) / 2) begin $display("FAIL: %0d words written", mem.num()); errs++; end

	if (errs) $fatal;
	$display("PASS tb_uio_boot (%0d words)", mem.num());
	$finish;
end

endmodule
