// Sony LDP-1450 player as Picmatic/ALG games see it, ported from WinUAE arcadia.cpp
// (sony_serial_read / sony_serial_write / alg_vsync). Runs on the Amiga clock and counts
// time in Amiga lines and fields, exactly like WinUAE.
//
// The serial link is real 8N1 at the rate the game programs into Paula's SERPER.
// Disc frame N is video frame N of the .dlv (PAL, 25 fps).

module ld_player
(
	input             clk,
	input             clk7_en,
	input             reset,

	input             hs_pulse,    // one per Amiga line
	input             vs_pulse,    // one per Amiga field
	input      [15:0] serper,      // Paula SERPER: bit period = SERPER[14:0]+1 colour clocks
	input             txd,         // from Paula
	output            rxd,         // to Paula

	input      [16:0] disc_frames, // frames on the mounted disc, 0 = unknown

	output reg [16:0] frame,       // current disc frame
	output            playing,     // 1x forward play with audio
	output      [1:0] ch_en,       // {channel 1, channel 2}
	output reg        video_on,
	output reg        seek         // 1 clk: the head jumped, flush buffered audio
);

localparam [9:0] MAXVPOS = 10'd313;

localparam [2:0] M_IDLE = 0, M_SEARCH = 1, M_PLAY = 2, M_STILL = 3, M_STOP = 4,
                 M_REPEAT = 5, M_REPEAT2 = 6, M_MARK = 7;

//------------------------------------------------------------------------------
// serial

wire [7:0] rx_byte;
wire       rx_stb;
wire       tx_busy;

serial_8n1 serial
(
	.clk(clk), .clk7_en(clk7_en), .reset(reset), .serper(serper),
	.rx(txd), .rx_byte(rx_byte), .rx_stb(rx_stb),
	.tx(rxd), .tx_byte(q[qr]), .tx_stb(pop), .tx_busy(tx_busy)
);

//------------------------------------------------------------------------------
// reply queue (WinUAE alg_ser_buf, 16 deep) and its pacing (sony_serial_write)

reg  [7:0] q[16];
reg  [3:0] qw, qr;
reg  [4:0] qn;

reg [31:0] lines;
reg [31:0] wait_ack;      // replies hold until this line after an ACK
reg [31:0] next_tx;       // two lines between reply bytes

wire pop = qn && !tx_busy && lines >= next_tx && lines >= wait_ack;

// reply sources, pushed one per clock in this priority
reg        ack_p;
reg  [7:0] ev_p;          // repeat complete (01) / mark return (07), 0 = none
reg  [7:0] seek_status;   // seek result, due at wait_seek
reg [31:0] wait_seek;
reg  [2:0] inq_i;         // address inquiry: 5 ASCII digits, 0 = idle
reg [16:0] inq_v;
reg  [3:0] inq_d;
reg  [2:0] stat_i;        // status inquiry: 5 bytes, 0 = idle

wire [16:0] inq_p = (inq_i == 1) ? 17'd10000 : (inq_i == 2) ? 17'd1000 :
                    (inq_i == 3) ? 17'd100   : (inq_i == 4) ? 17'd10 : 17'd1;

//------------------------------------------------------------------------------
// player state

reg  [2:0] mode, mode_value;
reg signed [2:0] dir;
reg [16:0] value;
reg [16:0] start_addr, end_addr;
reg [16:0] mark;
reg        mark_on;
reg  [8:0] repcnt;        // bit 8 = off (WinUAE -1), 0 = endless
reg  [1:0] audio;
reg        mute;
reg        field;

// user index text: bytes are consumed and ACKed (not drawn yet)
reg  [1:0] ui;            // 3 = idle
reg  [5:0] ui_cnt;

assign playing = (mode == M_PLAY) && (dir == 0) && !mute;
assign ch_en   = audio ? audio : 2'b11;

wire [16:0] dir_mag = dir[2] ? 17'(-dir) : 17'(dir);
wire  [7:0] stat4   = {2'b00, mode_value == M_REPEAT2, 2'b00, mode_value == M_REPEAT, mode_value == M_SEARCH, mode_value != M_IDLE};
wire  [7:0] stat5   = {dir[2], mode == M_STOP, mode == M_STILL, 4'b0000, mode == M_PLAY};

always @(posedge clk) begin
	reg [16:0] f;
	reg        push;
	reg  [7:0] push_v;

	seek <= 0;

	if (reset) begin
		qw <= 0; qr <= 0; qn <= 0;
		lines <= 0; wait_ack <= 0; next_tx <= 0; wait_seek <= 0;
		ack_p <= 0; ev_p <= 0; seek_status <= 0; inq_i <= 0; stat_i <= 0;
		mode <= M_IDLE; mode_value <= M_IDLE; dir <= 0; value <= 0;
		frame <= 0; start_addr <= 0; end_addr <= 0; mark_on <= 0; repcnt <= 9'h100;
		audio <= 0; mute <= 0; video_on <= 1; field <= 0;
		ui <= 3; ui_cnt <= 0;
	end
	else begin
		if (hs_pulse) lines <= lines + 1'd1;

		//---------------- reply arbiter ----------------
		push = 0;
		push_v = 0;
		if (ack_p) begin
			push = 1; push_v = 8'h0A; ack_p <= 0;
		end
		else if (ev_p) begin
			push = 1; push_v = ev_p; ev_p <= 0;
		end
		else if (seek_status && lines >= wait_seek) begin
			push = 1; push_v = seek_status; seek_status <= 0;
		end
		else if (inq_i) begin
			if (inq_v >= inq_p) begin
				inq_v <= inq_v - inq_p;
				inq_d <= inq_d + 1'd1;
			end
			else begin
				push = 1; push_v = 8'h30 + inq_d;
				inq_d <= 0;
				inq_i <= (inq_i == 5) ? 3'd0 : inq_i + 1'd1;
			end
		end
		else if (stat_i) begin
			push = 1;
			case (stat_i)
				1: push_v = 8'h80;
				2: push_v = 8'h00;
				3: push_v = 8'h40;
				4: push_v = stat4;
				default: push_v = stat5;
			endcase
			stat_i <= (stat_i == 5) ? 3'd0 : stat_i + 1'd1;
		end

		if (push && qn != 16) begin
			q[qw] <= push_v;
			qw <= qw + 1'd1;
		end
		if (pop) begin
			qr <= qr + 1'd1;
			next_tx <= lines + 32'd2;
		end
		qn <= qn + (push && qn != 16) - pop;

		//---------------- disc motion, once per field (alg_vsync) ----------------
		if (vs_pulse) begin
			field <= ~field;
			if (mode == M_PLAY) begin
				f = frame;
				if (dir[2])            f = (frame > dir_mag) ? frame - dir_mag : 17'd0;
				else if (dir || field) f = frame + dir_mag + 17'd1;
				frame <= f;

				if (!repcnt[8] && ((!dir[2] && f >= end_addr) || (dir[2] && f <= end_addr))) begin
					if (repcnt == 1) begin
						ev_p   <= 8'h01; // repeat complete
						repcnt <= 9'h100;
						mode   <= M_STILL;
						dir    <= 0;
					end
					else begin
						if (repcnt) repcnt <= repcnt - 1'd1;
						frame <= start_addr;
						seek  <= 1;
					end
				end

				if (mark_on && (mark == f || mark == f + 1'd1 || mark == f + 2'd2)) begin
					ev_p    <= 8'h07; // mark return
					mark_on <= 0;
				end
			end
		end

		//---------------- commands (sony_serial_read) ----------------
		if (rx_stb) begin
			if (ui != 3) begin
				ui_cnt <= ui_cnt + 1'd1;
				case (ui)
					0: if (ui_cnt == 2) ui <= 3;
					1: if (ui_cnt >= 33 || (ui_cnt != 0 && rx_byte == 8'h1A)) ui <= 3;
					default: ui <= 3;
				endcase
				ack_p <= 1; wait_ack <= next_tx + 32'd30;
			end
			else if (rx_byte >= 8'h30 && rx_byte <= 8'h39) begin
				value <= value * 17'd10 + rx_byte[3:0];
				ack_p <= 1; wait_ack <= next_tx + 32'd30;
			end
			else begin
				// every command below except ENTER-without-entry, 0x60 and 0x67 is ACKed
				if (!(rx_byte == 8'h40 && mode_value == M_IDLE) && rx_byte != 8'h60 && rx_byte != 8'h67 &&
				    ((rx_byte <= 8'h02) || (rx_byte >= 8'h24 && rx_byte <= 8'h27) || rx_byte == 8'h2B || rx_byte == 8'h2C ||
				     rx_byte == 8'h3A || rx_byte == 8'h3B || rx_byte == 8'h3F || (rx_byte >= 8'h40 && rx_byte <= 8'h41) ||
				     (rx_byte >= 8'h43 && rx_byte <= 8'h44) || (rx_byte >= 8'h46 && rx_byte <= 8'h4B) || rx_byte == 8'h4F ||
				     rx_byte == 8'h50 || rx_byte == 8'h51 || rx_byte == 8'h55 || rx_byte == 8'h56 || rx_byte == 8'h73 ||
				     (rx_byte >= 8'h80 && rx_byte <= 8'h82))) begin
					ack_p <= 1; wait_ack <= next_tx + 32'd30;
				end

				case (rx_byte)
					8'h00, 8'h01, 8'h02: begin ui <= rx_byte[1:0]; ui_cnt <= 0; end
					8'h24: mute <= 1;
					8'h25: mute <= 0;
					8'h26: video_on <= 0;
					8'h27: video_on <= 1;
					8'h2B: begin frame <= frame + 1'd1; mode <= M_STILL; dir <= 0; end
					8'h2C: begin if (frame) frame <= frame - 1'd1; mode <= M_STILL; dir <= 0; end
					8'h3A: if (mode != M_PLAY) begin mode <= M_PLAY; dir <= 0; repcnt <= 9'h100; end
					8'h3B: begin mode <= M_PLAY; dir <= 1; end
					8'h3F: begin dir <= 0; repcnt <= 9'h100; mode <= M_STOP; end
					8'h40: case (mode_value) // ENTER
							M_MARK: begin
								mode_value <= M_IDLE;
								mark <= value; mark_on <= 1;
							end
							M_REPEAT: begin
								dir <= 0;
								end_addr <= value;
								start_addr <= frame;
								value <= 0;
								mode_value <= M_REPEAT2;
							end
							M_REPEAT2: begin
								repcnt <= value[7:0];
								frame <= start_addr;
								if (start_addr > end_addr) dir <= -1;
								mode_value <= M_IDLE;
								mode <= M_PLAY;
								seek <= 1;
							end
							M_SEARCH: begin
								// status follows two frames later (Platoon requires the delay)
								wait_seek <= lines + {MAXVPOS, 1'b0};
								if (disc_frames && value >= disc_frames) begin
									frame <= disc_frames - 1'd1;
									seek_status <= 8'h06; // no frame number
								end
								else begin
									frame <= value;
									seek_status <= 8'h01; // completion
								end
								mode <= M_STILL;
								mode_value <= M_IDLE;
								dir <= 0;
								seek <= 1;
							end
							default: ;
						endcase
					8'h41: value <= 0;
					8'h43: begin mode <= M_STILL; mode_value <= M_SEARCH; dir <= 0; value <= 0; end
					8'h44: begin mode_value <= M_REPEAT; dir <= 0; value <= 0; end
					8'h46: audio[1] <= 1;
					8'h47: audio[1] <= 0;
					8'h48: audio[0] <= 1;
					8'h49: audio[0] <= 0;
					8'h4A: begin mode <= M_PLAY; dir <= -1; end
					8'h4B: begin mode <= M_PLAY; dir <= -2; end
					8'h4F: begin mode <= M_STILL; dir <= 0; end
					8'h56: begin
						mode <= M_STILL; repcnt <= 9'h100; mark_on <= 0;
						mode_value <= M_IDLE; dir <= 0; video_on <= 1; value <= 0;
					end
					8'h60: begin inq_i <= 1; inq_v <= frame; inq_d <= 0; end
					8'h67: stat_i <= 1;
					8'h73: begin value <= 0; mode_value <= M_MARK; end
					default: ;
				endcase
			end
		end
	end
end

endmodule

//------------------------------------------------------------------------------
// 8N1 serial at Paula's rate: one bit = SERPER[14:0]+1 colour clocks = 2*(SERPER+1) clk7 ticks

module serial_8n1
(
	input            clk,
	input            clk7_en,
	input            reset,
	input     [15:0] serper,

	input            rx,
	output reg [7:0] rx_byte,
	output reg       rx_stb,

	output reg       tx = 1,
	input      [7:0] tx_byte,
	input            tx_stb,
	output           tx_busy
);

wire [15:0] bit_len = {serper[14:0], 1'b1};   // ticks - 1

// receiver
reg  [1:0] rx_s = 2'b11;
reg  [3:0] rx_n;
reg [15:0] rx_cnt;
reg  [8:0] rx_sh;
reg        rx_act;

always @(posedge clk) begin
	rx_stb <= 0;
	if (reset) begin
		rx_act <= 0;
		rx_s <= 2'b11;
	end
	else if (clk7_en) begin
		rx_s <= {rx_s[0], rx};
		if (!rx_act) begin
			if (!rx_s[1]) begin                     // start bit: sample mid-bit
				rx_act <= 1;
				rx_cnt <= {1'b0, bit_len[15:1]};
				rx_n   <= 0;
			end
		end
		else if (rx_cnt) rx_cnt <= rx_cnt - 1'd1;
		else begin
			rx_cnt <= bit_len;
			rx_sh  <= {rx_s[1], rx_sh[8:1]};
			rx_n   <= rx_n + 1'd1;
			if (rx_n == 0 && rx_s[1]) rx_act <= 0;  // false start
			if (rx_n == 9) begin                    // stop bit
				rx_act  <= 0;
				rx_byte <= rx_sh[8:1];
				rx_stb  <= rx_s[1];
			end
		end
	end
end

// transmitter
reg [10:0] tx_sh;         // start, 8 data, stop, plus one stop period before going idle
reg  [3:0] tx_n;
reg [15:0] tx_cnt;
reg        tx_req;
reg  [7:0] tx_d;

assign tx_busy = tx_req | (tx_n != 0);

always @(posedge clk) begin
	if (reset) begin
		tx <= 1;
		tx_n <= 0;
		tx_req <= 0;
	end
	else begin
		if (tx_stb) begin
			tx_req <= 1;
			tx_d <= tx_byte;
		end
		if (clk7_en) begin
			if (!tx_n) begin
				if (tx_req) begin
					tx_req <= 0;
					tx_sh  <= {2'b11, tx_d, 1'b0};
					tx_n   <= 11;
					tx_cnt <= 0;
				end
			end
			else if (tx_cnt) tx_cnt <= tx_cnt - 1'd1;
			else begin
				tx     <= tx_sh[0];
				tx_sh  <= {1'b1, tx_sh[10:1]};
				tx_n   <= tx_n - 1'd1;
				tx_cnt <= bit_len;
			end
		end
	end
end

endmodule
