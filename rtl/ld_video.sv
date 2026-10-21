// LaserDisc picture for the genlock: .dlv stream -> MJPEG decoder -> DDR3 framebuffers,
// read back line by line in step with the Amiga beam so the disc is the background of
// every Amiga pixel with colour index 0.
//
// One clock (clk_sys) for everything: hps_io's SD interface, the decoder, DDR3 and the Amiga beam.
//
// Framebuffer: 384x288 RGB565. One framebuffer pixel = one Amiga lores pixel (140 ns) and one row =
// one Amiga line, so a PAL disc frame (52 us x 288 lines) maps 1:1 with no scaler.
// Three buffers: the decoder writes one, the beam shows another, the third holds the newest
// finished frame until the next Amiga vblank.

module ld_video #(parameter [31:0] CLK_HZ = 32'd28_375_160)
(
	input             clk,
	input             reset,

	// hps_io SD slot 0 (.dlv)
	input             img_mounted,
	input      [63:0] img_size,
	output     [31:0] sd_lba,
	output      [5:0] sd_blk_cnt,
	output            sd_rd,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,

	// player
	input      [16:0] ld_frame,
	input             ld_playing,
	input       [1:0] ld_ch_en,
	input             ld_seek,

	// disc audio, 44.1 kHz
	output signed [15:0] pcm_l,
	output signed [15:0] pcm_r,

	// Amiga beam
	input             clk7_en,
	input             hs_n,        // Amiga _hsync
	input             vs_n,        // Amiga _vsync
	input       [8:0] h_off,       // lores pixels from hsync to framebuffer column 0
	input       [8:0] v_off,       // lines from vsync to framebuffer row 0

	output reg  [7:0] ld_r,
	output reg  [7:0] ld_g,
	output reg  [7:0] ld_b,
	output reg        ld_valid,    // beam is inside a shown disc frame
	output      [8:0] beam_col,    // framebuffer position under the beam, two clocks ahead of ld_*
	output      [9:0] beam_row,

	// DDR3
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output            DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output            DDRAM_WE
);

localparam [15:0] FB_W   = 16'd384;
localparam [15:0] FB_H   = 16'd288;
localparam [26:0] FB_BUF = 27'd110592;     // 384*288 halfwords
localparam  [6:0] WORDS  = 7'd96;          // 64-bit words per row

//------------------------------------------------------------------------------
// .dlv -> decoder

wire  [7:0] strm_byte;
wire        strm_valid, strm_ready, strm_last;
wire        dec_reset;

dlv_streamer #(.CLK_HZ(CLK_HZ)) dlv
(
	.clk(clk), .reset(reset),
	.img_mounted(img_mounted), .img_size(img_size),
	.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.out_byte(strm_byte), .out_valid(strm_valid), .out_ready(strm_ready), .out_last(strm_last),
	.dec_reset(dec_reset),
	.pcm_l(pcm_l), .pcm_r(pcm_r),
	.ld_curr_frame(ld_frame), .pause(1'b0),
	.aud_primed(), .hold_play(1'b0), .seek_flush(ld_seek),
	.ld_playing(ld_playing), .ch_en(ld_ch_en),
	.disc_2997(), .disc_leader(),
	.hdr_valid(), .hdr_ver(), .hdr_game_id()
);

wire        px_we, px_ready;
wire [15:0] px_x, px_y;
wire  [7:0] px_r, px_g, px_b;
wire        frame_done;

jpeg_frame_decoder dec
(
	.clk(clk), .rst(dec_reset),
	.in_byte(strm_byte), .in_valid(strm_valid), .in_ready(strm_ready), .in_last(strm_last),
	.px_ready(px_ready), .px_we(px_we),
	.px_x(px_x), .px_y(px_y), .px_r(px_r), .px_g(px_g), .px_b(px_b),
	.frame_width(), .frame_height(), .frame_done(frame_done), .idle()
);

//------------------------------------------------------------------------------
// triple buffering, handed over at the Amiga vblank

reg  [1:0] wr_idx, disp_idx, ready_idx;
reg        have_new, shown;
reg        vs_d;
wire       vbl   = vs_d & ~vs_n;
wire       adopt = vbl & have_new;
wire [1:0] next_disp = adopt ? ready_idx : disp_idx;

always @(posedge clk) begin
	vs_d <= vs_n;
	if (reset) begin
		wr_idx <= 0; disp_idx <= 1; ready_idx <= 1;
		have_new <= 0; shown <= 0;
	end
	else begin
		if (adopt) begin
			disp_idx <= ready_idx;
			have_new <= 0;
			shown    <= 1;
		end
		if (frame_done) begin
			ready_idx <= wr_idx;
			wr_idx    <= 2'd3 - wr_idx - next_disp;
			have_new  <= 1;
		end
	end
end

function [26:0] buf_base(input [1:0] i);
	buf_base = (i == 0) ? 27'd0 : (i == 1) ? FB_BUF : FB_BUF * 2;
endfunction

//------------------------------------------------------------------------------
// DDR3: fb_writer on the write port, the line fetcher on read port 2

wire [27:1] wraddr;
wire [15:0] wdin;
wire [63:0] din64;
wire  [7:0] be64;
wire        we_req, we_ack;

reg  [27:1] rdaddr2;
wire [63:0] dout2_64;
reg         rd_req2;
wire        rd_ack2;
reg         fetching;

fb_writer #(
	.STRIDE_HW  (FB_W),
	.FB_COLS    (FB_W),
	.FB_ROWS    (FB_H),
	.CLEAR_ROWS (FB_H),
	.CLEAR_COLOR(16'h0000),
	.COALESCE   (1'b0)      // as shipped by the LaserDisc core
) fbw (
	.clk(clk), .reset(reset),
	.base_hw(buf_base(wr_idx)),
	.fill_idle(~fetching),
	.px_we(px_we), .px_x(px_x), .px_y(px_y), .px_r(px_r), .px_g(px_g), .px_b(px_b),
	.px_ready(px_ready),
	.wraddr(wraddr), .din(wdin), .din64(din64), .be64(be64),
	.we_req(we_req), .we_ack(we_ack)
);

ddram ddr
(
	.DDRAM_CLK(clk),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),

	.wraddr(wraddr), .din(wdin), .din64(din64), .be64(be64), .we_req(we_req), .we_ack(we_ack),

	.rdaddr(27'd0), .dout(), .rom_din(16'd0), .rom_be(2'b00), .rom_we(1'b0), .rom_req(1'b0), .rom_ack(),

	.rdaddr2(rdaddr2), .dout2(), .dout2_64(dout2_64), .rd_req2(rd_req2), .rd_ack2(rd_ack2)
);

//------------------------------------------------------------------------------
// Amiga beam position

reg  [8:0] hcnt;     // lores pixels since hsync
reg  [9:0] vcnt;     // lines since vsync
reg        hs_d;
wire       hs_fall = hs_d & ~hs_n;

always @(posedge clk) begin
	hs_d <= hs_n;
	if (hs_fall) begin
		hcnt <= 0;
		vcnt <= vcnt + 1'd1;
	end
	else if (clk7_en && hcnt != 9'h1FF) hcnt <= hcnt + 1'd1;
	if (vbl) vcnt <= 0;
end

//------------------------------------------------------------------------------
// line fetch: at each hsync, fetch the framebuffer row for the NEXT line into the free half

reg  [63:0] lbuf[256];     // two rows of 96 words, one per 128-word half
reg   [6:0] fw;            // word being fetched
reg         fbank;
reg  [26:0] frow_base;

wire  [9:0] next_line = vcnt + 1'd1 - v_off;
wire        next_in   = (vcnt + 1'd1 >= v_off) && (next_line < FB_H);

always @(posedge clk) begin
	if (reset) begin
		fetching <= 0;
		rd_req2  <= 0;
	end
	else if (hs_fall && next_in) begin
		// a fetch that has not finished in a whole line is abandoned (it never should)
		fetching  <= 1;
		fw        <= 0;
		fbank     <= next_line[0];
		frow_base <= buf_base(next_disp) + next_line * FB_W;
		rdaddr2   <= buf_base(next_disp) + next_line * FB_W;
		rd_req2   <= ~rd_ack2;
	end
	else if (fetching && rd_req2 == rd_ack2) begin
		lbuf[{fbank, 7'd0} + fw] <= dout2_64;
		if (fw == WORDS - 1'd1) fetching <= 0;
		else begin
			fw      <= fw + 1'd1;
			rdaddr2 <= frow_base + {fw + 1'd1, 2'b00};
			rd_req2 <= ~rd_req2;
		end
	end
end

//------------------------------------------------------------------------------
// pixel out, aligned to Denise's RGB by h_off

wire  [9:0] line = vcnt - v_off;
wire  [9:0] col  = hcnt - h_off;
wire        in_y = (vcnt >= v_off) && (line < FB_H);
wire        in_x = (hcnt >= h_off) && (col < FB_W);

assign beam_col = col[8:0];
assign beam_row = line;

reg  [63:0] word_q;
reg   [1:0] sub_q;
reg         valid_q;

always @(posedge clk) begin
	word_q  <= lbuf[{line[0], 7'd0} + col[8:2]];
	sub_q   <= col[1:0];
	valid_q <= in_x & in_y & shown;
end

wire [15:0] px565 = word_q[{sub_q, 4'b0000} +: 16];

always @(posedge clk) begin
	ld_r     <= {px565[15:11], px565[15:13]};
	ld_g     <= {px565[10:5],  px565[10:9]};
	ld_b     <= {px565[4:0],   px565[4:2]};
	ld_valid <= valid_q;
end

endmodule
