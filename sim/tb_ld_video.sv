// End to end LaserDisc picture: a real .dlv -> SD model -> dlv_streamer -> core_jpeg -> fb_writer
// -> DDR3 model -> beam-slaved line reader. Dumps one displayed field as a PPM for
// sim/check_ld_video.py to compare against ffmpeg's decode of the same disc frame.
// Run: sim/run.sh ld_video   (needs DLV=<file.dlv> FRAME=<n> PPM=<out.ppm> in the environment)
`timescale 1ns/1ps
module tb_ld_video;

reg clk = 0;
always #17.6 clk = ~clk;
reg [1:0] div = 0;
always @(posedge clk) div <= div + 1'd1;
wire clk7_en = (div == 0);

reg reset = 1;

// ---------------- Amiga beam: 1816 clocks per line, 313 lines ----------------
reg [11:0] hc = 0;
reg  [9:0] vc = 0;
always @(posedge clk) begin
	hc <= (hc == 1815) ? 12'd0 : hc + 1'd1;
	if (hc == 1815) vc <= (vc == 312) ? 10'd0 : vc + 1'd1;
end
wire hs_n = !(hc < 4 * 17);
wire vs_n = !(vc < 3);

// ---------------- SD model (hps_io slot) ----------------
reg  [7:0] dlv[int];
integer    dlv_len;
reg        img_mounted = 0;
wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire        sd_rd;
reg         sd_ack = 0;
reg   [8:0] sd_buff_addr = 0;
reg   [7:0] sd_buff_dout = 0;
reg         sd_buff_wr = 0;

initial begin : sd
	integer i;
	forever begin
		@(posedge clk);
		if (sd_rd && !sd_ack) begin
			repeat (20) @(posedge clk);
			sd_ack <= 1;
			for (i = 0; i < 512; i++) begin
				@(posedge clk);
				sd_buff_addr <= i;
				sd_buff_dout <= dlv.exists(sd_lba * 512 + i) ? dlv[sd_lba * 512 + i] : 8'h00;
				sd_buff_wr <= 1;
				@(posedge clk);
				sd_buff_wr <= 0;
			end
			@(posedge clk);
			sd_ack <= 0;
		end
	end
end

// ---------------- DDR3 model ----------------
wire        DDRAM_RD, DDRAM_WE;
wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DIN;
reg  [63:0] DDRAM_DOUT = 0;
reg         DDRAM_DOUT_READY = 0;
reg  [63:0] ddr[int];

reg  [28:0] rd_addr;
reg   [7:0] rd_left = 0;
reg   [3:0] rd_lat = 0;
wire        DDRAM_BUSY = (rd_left != 0);

always @(posedge clk) begin
	integer b;
	DDRAM_DOUT_READY <= 0;
	if (DDRAM_WE && !DDRAM_BUSY) begin
		reg [63:0] w;
		w = ddr.exists(DDRAM_ADDR) ? ddr[DDRAM_ADDR] : 64'd0;
		for (b = 0; b < 8; b++) if (DDRAM_BE[b]) w[b*8 +: 8] = DDRAM_DIN[b*8 +: 8];
		ddr[DDRAM_ADDR] = w;
	end
	if (DDRAM_RD && !DDRAM_BUSY) begin
		rd_addr <= DDRAM_ADDR;
		rd_left <= DDRAM_BURSTCNT;
		rd_lat  <= 6;
	end
	else if (rd_left) begin
		if (rd_lat) rd_lat <= rd_lat - 1'd1;
		else begin
			DDRAM_DOUT <= ddr.exists(rd_addr) ? ddr[rd_addr] : 64'd0;
			DDRAM_DOUT_READY <= 1;
			rd_addr <= rd_addr + 1'd1;
			rd_left <= rd_left - 1'd1;
		end
	end
end

// ---------------- DUT ----------------
reg  [16:0] ld_frame = 0;
wire  [7:0] ld_r, ld_g, ld_b;
wire        ld_valid;

localparam [8:0] H_OFF = 9'd60;
localparam [8:0] V_OFF = 9'd20;

ld_video dut
(
	.clk(clk), .reset(reset),
	.img_mounted(img_mounted), .img_size(64'(dlv_len)),
	.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.ld_frame(ld_frame), .ld_playing(1'b0), .ld_ch_en(2'b11), .ld_seek(1'b0),
	.pcm_l(), .pcm_r(),
	.clk7_en(clk7_en), .hs_n(hs_n), .vs_n(vs_n), .h_off(H_OFF), .v_off(V_OFF),
	.ld_r(ld_r), .ld_g(ld_g), .ld_b(ld_b), .ld_valid(ld_valid),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

// ---------------- capture one displayed field ----------------
// ld_* is valid three clocks after hcnt moves to a new lores pixel
reg [23:0] img[384*288];
integer    npx = 0;
reg  [3:0] ph = 0;
reg        cap = 0;

always @(posedge clk) begin
	ph <= clk7_en ? 4'd0 : ph + 1'd1;
	if (cap && ph == 2 && ld_valid) begin
		img[(dut.vcnt - V_OFF) * 384 + (dut.hcnt - H_OFF)] <= {ld_r, ld_g, ld_b};
		npx <= npx + 1;
	end
end

initial begin
	string fn, out;
	integer fd, c, i, fields;
	if (!$value$plusargs("DLV=%s", fn)) $fatal(1, "+DLV=<file> missing");
	if (!$value$plusargs("PPM=%s", out)) out = "ld_video.ppm";
	if (!$value$plusargs("FRAME=%d", i)) i = 3;
	ld_frame = i;

	fd = $fopen(fn, "rb");
	dlv_len = 0;
	while ((c = $fgetc(fd)) != -1) begin dlv[dlv_len] = c[7:0]; dlv_len++; end
	$fclose(fd);
	$display("loaded %0d bytes, showing disc frame %0d", dlv_len, ld_frame);

	repeat (20) @(posedge clk);
	reset = 0;
	repeat (100) @(posedge clk);
	img_mounted = 1; @(posedge clk); img_mounted = 0;

	// wait until a decoded frame is on show, then grab the next whole field
	fields = 0;
	while (!dut.shown && fields < 40) begin
		@(negedge vs_n); fields++;
	end
	if (!dut.shown) $fatal(1, "FAIL: no frame displayed after %0d fields", fields);
	@(negedge vs_n);
	cap = 1;
	@(negedge vs_n);
	cap = 0;
	$display("captured %0d pixels after %0d fields", npx, fields);
	if (npx != 384 * 288) $fatal(1, "FAIL: captured %0d pixels, want %0d", npx, 384 * 288);

	fd = $fopen(out, "wb");
	$fwrite(fd, "P6\n384 288\n255\n");
	for (i = 0; i < 384 * 288; i++) $fwrite(fd, "%c%c%c", img[i][23:16], img[i][15:8], img[i][7:0]);
	$fclose(fd);
	$display("DONE tb_ld_video -> %s", out);
	$finish;
end

endmodule
