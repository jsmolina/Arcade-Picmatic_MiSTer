// Whole core (emu) booting the real ROMs: Kickstart 1.3 + Picmatic game ROM, loaded through the
// MRA path (hps_io model -> uio_boot -> userio host writes). Logs what the game does with the
// LaserDisc player and the $F4/$F6 board, and dumps Amiga fields as PPM.
//   sim/system/run.sh +ROM=<mra image> +FIELDS=<n> [+SNAP=<field>]...
`timescale 1ns/1ps
module tb_system;

reg         clk50 = 0;
reg         clk_audio = 0;
always #10 clk50 = ~clk50;
always #20.345 clk_audio = ~clk_audio;

wire [45:0] HPS_BUS;
wire [15:0] SDRAM_DQ;
wire  [3:0] ADC_BUS;

emu dut
(
	.CLK_50M(clk50), .RESET(1'b0), .HPS_BUS(HPS_BUS),
	.HDMI_WIDTH(12'd0), .HDMI_HEIGHT(12'd0),
	.CLK_AUDIO(clk_audio), .ADC_BUS(ADC_BUS), .SD_MISO(1'b1), .SD_CD(1'b1),
	.DDRAM_BUSY(1'b0), .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
	.SDRAM_DQ(SDRAM_DQ),
	.UART_CTS(1'b0), .UART_RXD(1'b1), .UART_DSR(1'b0), .USER_IN(7'h7F), .OSD_STATUS(1'b0)
);

wire clk = dut.clk_sys;

//------------------------------------------------------------------------------
// LaserDisc serial traffic

always @(posedge clk) begin
	if (dut.ld_player.serial.rx_stb) $display("[%0t] LD <- %02h '%s'", $time, dut.ld_player.serial.rx_byte,
	                                         (dut.ld_player.serial.rx_byte >= 8'h20 && dut.ld_player.serial.rx_byte < 8'h7F) ? dut.ld_player.serial.rx_byte : 8'h2E);
	if (dut.ld_player.pop) $display("[%0t] LD -> %02h", $time, dut.ld_player.q[dut.ld_player.qr]);
end

reg [15:0] serper_q = 0;
always @(posedge clk) if (dut.pm_serper != serper_q) begin
	serper_q <= dut.pm_serper;
	$display("[%0t] SERPER = %04h (%0d baud)", $time, dut.pm_serper, 3546895 / (dut.pm_serper[14:0] + 1));
end

//------------------------------------------------------------------------------
// Picmatic board accesses ($F4 NVRAM, $F6 I/O), first few of each kind

wire        pm_sel = dut.minimig.sel_picmatic;
wire [23:1] pm_a   = dut.minimig.cpu_address_out;
integer     n_nvw = 0, n_nvr = 0, n_io = 0;
reg         pm_d = 0;
always @(posedge clk) begin
	pm_d <= pm_sel & (dut.minimig.cpu_rd | dut.minimig.cpu_hwr | dut.minimig.cpu_lwr);
	if (pm_sel & (dut.minimig.cpu_rd | dut.minimig.cpu_hwr | dut.minimig.cpu_lwr) & !pm_d) begin
		if (dut.minimig.sel_picmatic_io) begin
			if (n_io < 40) $display("[%0t] F6 %s %06h %04h", $time, dut.minimig.cpu_rd ? "rd" : "wr", {pm_a, ~dut.chip_lds}, dut.minimig.cpu_data_out);
			n_io++;
		end
		else if (dut.minimig.cpu_rd) begin
			if (n_nvr < 8) $display("[%0t] F4 rd %06h", $time, {pm_a, ~dut.chip_lds});
			n_nvr++;
		end
		else begin
			if (n_nvw < 8) $display("[%0t] F4 wr %06h %04h", $time, {pm_a, ~dut.chip_lds}, dut.minimig.cpu_data_out);
			n_nvw++;
		end
	end
end

// +TRACE=n: the first n CPU bus cycles after the boot shim releases the CPU (address, then data at DTACK)
integer trace_n = 0, traced = 0;
reg     released = 0, seen_dl = 0, dt_d = 1;
initial if (!$value$plusargs("TRACE=%d", trace_n)) trace_n = 0;
always @(posedge clk) begin
	if (dut.ioctl_download) seen_dl <= 1;
	if (seen_dl && !dut.ioctl_download && !dut.minimig.cpuhlt) released <= 1;
	dt_d <= dut.chip_dtack;
	if (released && traced < trace_n && dt_d && !dut.chip_dtack) begin
		traced++;
		$display("[%0t] cpu %s %06h %04h", $time, dut.chip_rw ? "rd" : "wr", {dut.chip_addr, 1'b0}, dut.chip_rw ? dut.chip_din : dut.chip_dout);
	end
end

// +BUSDBG: every data source minimig ORs onto the CPU bus during the reset-vector reads
always @(posedge clk) if ($test$plusargs("BUSDBG") && released && dut.minimig.cpu_rd && dut.chip_addr < 23'h4)
	$display("[%0t] bus %06h gary %04h cia %04h gayle %04h cart %04h rtc %04h toc %04h a2065 %04h -> %04h cpu_wrapper.chip_data %04h", $time,
	         {dut.chip_addr, 1'b0}, dut.minimig.gary_data_out, dut.minimig.cia_data_out, dut.minimig.gayle_data_out, dut.minimig.cart_data_out,
	         dut.minimig.rtc_out, dut.minimig.toccata_out, dut.minimig.a2065_dout, dut.minimig.cpu_data_in, dut.cpu_wrapper.chip_data);

// last 48 CPU bus cycles, printed at the end
reg [23:0] ring_a[48];
reg [15:0] ring_d[48];
reg        ring_w[48];
integer    ring_i = 0;
always @(posedge clk) if (released && dt_d && !dut.chip_dtack) begin
	ring_a[ring_i % 48] <= {dut.chip_addr, 1'b0};
	ring_d[ring_i % 48] <= dut.chip_rw ? dut.chip_din : dut.chip_dout;
	ring_w[ring_i % 48] <= !dut.chip_rw;
	ring_i <= ring_i + 1;
end
task dump_ring;
	integer k;
	for (k = 0; k < 48; k++) $display("  tail %s %06h %04h", ring_w[(ring_i + k) % 48] ? "wr" : "rd", ring_a[(ring_i + k) % 48], ring_d[(ring_i + k) % 48]);
endtask

// first instruction fetch from the game ROM
reg rom_seen = 0;
always @(posedge clk) if (!rom_seen && dut.minimig.cpu_rd && pm_a[23:18] == 6'b1111_00) begin
	rom_seen <= 1;
	$display("[%0t] game ROM first read at %06h", $time, {pm_a, 1'b0});
end

//------------------------------------------------------------------------------
// fields: count, snapshot to PPM (hires pixels, one row per line)

integer field = 0, fields_max = 100;
integer x = 0, y = 0, snap_fd = 0, maxx = 0;
reg     vs_d = 1, hs_d = 1;
reg [23:0] row[1024];
string  snap_name;

function bit want_snap(input integer f);
	string s;
	integer i;
	want_snap = 0;
	for (i = 0; i < 32; i++)
		if ($value$plusargs($sformatf("SNAP%0d=%%d", i), s) && s.atoi() == f) want_snap = 1;
	if ($test$plusargs($sformatf("SNAPALL"))) want_snap = 1;
endfunction

always @(posedge clk) begin
	vs_d <= dut.vs;
	hs_d <= dut.hs;
	if (vs_d & ~dut.vs) begin
		if (snap_fd) begin
			$fclose(snap_fd);
			snap_fd = 0;
			$display("[%0t] wrote %s (%0dx%0d)", $time, snap_name, maxx, y);
		end
		field++;
		if (field % 10 == 0) $display("[%0t] field %0d", $time, field);
		if (field >= fields_max) begin
			$display("state: uio_boot %0d cpuhlt %b cpurst %b usrrst %b chipset %h mem %h cpu %h _cpu_reset %b dl %b wait %b", dut.uio_boot.state,
			         dut.minimig.cpuhlt, dut.minimig.cpurst, dut.minimig.usrrst, dut.minimig.chipset_config, dut.minimig.memory_config, dut.minimig.cpucfg, dut.cpu_rst, dut.ioctl_download, dut.ioctl_wait);
			$display("reset %b reset_d %b locked %b sys_reset %b nrst_out %b", dut.reset, dut.reset_d, dut.locked, dut.minimig.sys_reset, dut.cpu_nrst_out);
			dump_ring();
			if ($test$plusargs("CHIPDUMP")) begin : chipdump
				integer fd, w;
				reg [15:0] v;
				fd = $fopen("chip.bin", "wb");
				for (w = 0; w < 24'h40000; w++) begin v = dut.ram1.rd(w); $fwrite(fd, "%c%c", v[15:8], v[7:0]); end
				$fclose(fd);
				$display("wrote chip.bin");
			end
			$display("DONE tb_system: %0d fields, F6 accesses %0d, F4 reads %0d writes %0d", field, n_io, n_nvr, n_nvw);
			$finish;
		end
		if (want_snap(field)) begin
			snap_name = $sformatf("field%04d.ppm", field);
			snap_fd = $fopen(snap_name, "wb");
			// fixed size so the header can be written up front
			$fwrite(snap_fd, "P6\n720 288\n255\n");
		end
		y = 0;
	end
	if (hs_d & ~dut.hs) begin
		if (snap_fd && y >= 24 && y < 24 + 288) begin
			integer i;
			for (i = 0; i < 720; i++) $fwrite(snap_fd, "%c%c%c", row[i + 120][23:16], row[i + 120][15:8], row[i + 120][7:0]);
		end
		if (x > maxx) maxx = x;
		x = 0;
		y++;
	end
	else if (dut.clk7_en | dut.clk7n_en) begin
		if (x < 1024) row[x] <= {dut.mr, dut.mg, dut.mb};
		x++;
	end
end

initial begin
	if (!$value$plusargs("FIELDS=%d", fields_max)) fields_max = 100;
end

//------------------------------------------------------------------------------
// Cabinet buttons on joystick 0: +COIN=<field> +START=<field> +TRIG=<field>, each held 5 fields.
// Logs pm_flag changes and how often the game reads JOY0DAT/JOY1DAT/POTGOR.

integer coin_f = -100, start_f = -100, trig_f = -100;
initial begin
	void'($value$plusargs("COIN=%d", coin_f));
	void'($value$plusargs("START=%d", start_f));
	void'($value$plusargs("TRIG=%d", trig_f));
end

always @(posedge clk)
	dut.hps_io.joystick_0 <= {23'd0, 1'b0,
	                          field >= start_f && field < start_f + 5,
	                          field >= coin_f  && field < coin_f  + 5,
	                          1'b0,
	                          field >= trig_f  && field < trig_f  + 5,
	                          4'd0};

// +REGLOG: display register writes (CPU or copper), logged when the value changes
reg [15:0] reg_last[256];
initial for (int i = 0; i < 256; i++) reg_last[i] = 16'hDEAD;
always @(posedge clk) if ($test$plusargs("REGLOG") && dut.clk7_en) begin
	automatic logic [8:1] ra = dut.minimig.reg_address;
	automatic logic [15:0] rd = dut.minimig.custom_data_in;
	if ((ra == 9'h096 >> 1 || ra == 9'h100 >> 1 || ra == 9'h092 >> 1 || ra == 9'h08e >> 1 ||
	     ra == 9'h080 >> 1 || ra == 9'h082 >> 1 || (ra >= 9'h180 >> 1 && ra <= 9'h186 >> 1)) && reg_last[ra] != rd) begin
		reg_last[ra] = rd;
		$display("[%0t] field %0d REG %03h <= %04h", $time, field, {ra, 1'b0}, rd);
	end
end

// +DBGSQ: OSD "Debug squares" on
always @(posedge clk) if ($test$plusargs("DBGSQ")) dut.hps_io.status[24] <= 1;

reg  [9:1] flag_q = 0;
integer    joy_reads = 0, joy_field = 0;
always @(posedge clk) begin
	if (dut.pm_flag != flag_q) begin
		flag_q <= dut.pm_flag;
		$display("[%0t] field %0d pm_flag = %09b", $time, field, dut.pm_flag);
	end
	if (dut.clk7_en && dut.minimig.pm_joy_sel) joy_reads++;
	if (field != joy_field) begin
		joy_field <= field;
		if (field % 10 == 0) begin
			$display("[%0t] JOY/POTGO read cycles in last 10 fields: %0d", $time, joy_reads);
			joy_reads = 0;
		end
	end
end

endmodule
