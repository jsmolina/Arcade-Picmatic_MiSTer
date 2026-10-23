// LDP-1450 front end + serial: SEARCH, inquiries, PLAY rate, ACK policy. Run: sim/run.sh ld_player
`timescale 1ns/1ps
module tb_ld_player;

reg clk = 0;
always #17.6 clk = ~clk;   // ~28.4 MHz

reg [1:0] div = 0;
always @(posedge clk) div <= div + 1'd1;
wire clk7_en = (div == 0);

reg reset = 1;
localparam [15:0] SERPER = 16'd368;   // 9600 baud on PAL

// Amiga line/field pulses: 1816 clk per line, 313 lines per field
reg [11:0] hc = 0;
reg  [9:0] vc = 0;
wire hs = (hc == 0);
wire vs = hs && (vc == 0);
always @(posedge clk) begin
	hc <= (hc == 1815) ? 12'd0 : hc + 1'd1;
	if (hc == 1815) vc <= (vc == 312) ? 10'd0 : vc + 1'd1;
end

wire        amiga_tx, amiga_rx;
reg   [7:0] cmd;
reg         cmd_stb = 0;
wire        cmd_busy;
wire  [7:0] rsp;
wire        rsp_stb;

// the "Paula" end
serial_8n1 amiga
(
	.clk(clk), .clk7_en(clk7_en), .reset(reset), .serper(SERPER),
	.rx(amiga_rx), .rx_byte(rsp), .rx_stb(rsp_stb),
	.tx(amiga_tx), .tx_byte(cmd), .tx_stb(cmd_stb), .tx_busy(cmd_busy)
);

wire [16:0] frame;
wire        playing, video_on, seek;
wire  [1:0] ch_en;

ld_player dut
(
	.clk(clk), .clk7_en(clk7_en), .reset(reset),
	.hs_pulse(hs), .vs_pulse(vs), .serper(SERPER),
	.txd(amiga_tx), .rxd(amiga_rx),
	.disc_frames(17'd54000),
	.frame(frame), .playing(playing), .ch_en(ch_en), .video_on(video_on), .seek(seek)
);

// collect replies
reg [7:0] got[64];
integer   ng = 0;
always @(posedge clk) if (rsp_stb) begin got[ng] <= rsp; ng <= ng + 1; end

task send(input [7:0] b);
	begin
		@(posedge clk); cmd <= b; cmd_stb <= 1;
		@(posedge clk); cmd_stb <= 0;
		@(posedge clk);
		while (cmd_busy) @(posedge clk);
	end
endtask

task expect_rx(input integer n, input [7:0] b);
	begin
		if (got[n] !== b) begin
			$display("FAIL: reply %0d = %02h, want %02h", n, got[n], b);
			$fatal;
		end
	end
endtask

integer i, f0;
initial begin
	repeat (20) @(posedge clk);
	reset = 0;

	// SEARCH 123 ENTER -> 4 ACKs (C,1,2,3) + ACK(@) + completion 01 two frames later
	send("C"); send("1"); send("2"); send("3"); send("@");
	#(3 * 20_000_000);   // 3 fields at 20 ms
	if (ng != 6) begin $display("FAIL: %0d replies after SEARCH, want 6", ng); $fatal; end
	for (i = 0; i < 5; i++) expect_rx(i, 8'h0A);
	expect_rx(5, 8'h01);
	if (frame != 123) begin $display("FAIL: frame %0d, want 123", frame); $fatal; end

	// address inquiry -> "00123"
	send(8'h60);
	#(10_000_000);
	expect_rx(6, "0"); expect_rx(7, "0"); expect_rx(8, "1"); expect_rx(9, "2"); expect_rx(10, "3");

	// status inquiry while STILL -> 80 00 40 00 20
	send(8'h67);
	#(10_000_000);
	expect_rx(11, 8'h80); expect_rx(12, 8'h00); expect_rx(13, 8'h40); expect_rx(14, 8'h00); expect_rx(15, 8'h20);

	// PLAY: 25 frames per second (one frame per two fields)
	send(":");
	f0 = frame;
	#(400_000_000);   // 0.4 s = 20 fields
	if (frame - f0 < 9 || frame - f0 > 11) begin $display("FAIL: played %0d frames in 0.4 s", frame - f0); $fatal; end
	if (!playing) begin $display("FAIL: not playing"); $fatal; end

	// ENTER with nothing pending is not acknowledged
	i = ng;
	send("@");
	#(10_000_000);
	if (ng != i) begin $display("FAIL: bare ENTER was ACKed"); $fatal; end

	$display("PASS tb_ld_player (%0d replies)", ng);
	$finish;
end

endmodule
