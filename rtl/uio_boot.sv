// Boots minimig from an MRA download by speaking the UIO protocol MiSTer Main uses for Minimig
// (see userio.v): halt the CPU, set a fixed A500 config, write the ROMs through the host bus,
// then reset. minimig.v and userio.v stay untouched.
//
// ioctl index 0 layout (built by the MRA):
//   0x00000-0x3FFFF  Kickstart 1.3    -> $F80000
//   0x40000-0x7FFFF  Kickstart 1.3    -> $FC0000 (256K mirror; writing $FE0000 also clears bootrom)
//   0x80000-0x9FFFF  game ROM, even/odd interleaved -> $E00000 (gary maps $F00000 onto it)
// Any download (ROM or NVRAM) ends with a CPU reset, so the game always starts on loaded data.

module uio_boot
(
	input             clk,
	input             reset,

	input             ioctl_download,
	input       [7:0] ioctl_index,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	input             ioctl_wr,
	output reg        ioctl_wait,

	output reg        io_uio,
	output reg        io_strobe,
	output reg [15:0] io_din,
	input             io_wait
);

localparam [24:0] EXT_START = 25'h80000;

// {cmd, data} pairs sent when the ROM download starts
localparam NCFG = 7;
localparam logic [15:0] cfg[NCFG] = '{
	16'hF1_06, // reset control: CPU halt + CPU reset
	16'hF3_08, // chipset: ECS, PAL
	16'hF4_00, // cpu: 68000
	16'hF5_00, // memory: 512K chip, no slow/fast, no HRTmon
	16'hF7_00, // floppy: 1 drive, normal speed
	16'hF8_00, // harddisk: off
	16'hF9_00  // joystick: no swap, digital
};

typedef enum logic [3:0] {
	S_HALT, S_IDLE, S_CFG, S_OPEN, S_STREAM, S_BYTE, S_WAIT, S_CLOSE, S_RESET, S_RUN
} state_t;

state_t     state = S_HALT;
reg   [2:0] cfg_i;
reg   [2:0] sub;         // step inside a command: 0 open, 1 cmd, 2+ data
reg  [23:0] mem_adr;
reg  [15:0] dly;
reg         old_dl;
reg         rom_dl;
reg         dl_end;

// one UIO command: io_uio high, strobe cmd, strobe data bytes, io_uio low.
// cmd_bytes holds up to 5 bytes (mem write: F0 + 4 address bytes)
reg  [39:0] cmd_bytes;
reg   [2:0] cmd_len;
reg   [2:0] cmd_i;
state_t     cmd_ret;
reg         keep_open;

always @(posedge clk) begin
	io_strobe <= 0;
	old_dl <= ioctl_download;
	if (old_dl & ~ioctl_download) dl_end <= 1;

	if (reset) begin
		state      <= S_HALT;
		io_uio     <= 0;
		ioctl_wait <= 0;
		rom_dl     <= 0;
		dl_end     <= 0;
	end
	else case (state)
		// power-on: keep the CPU halted until the ROMs arrive
		S_HALT: begin
			cmd_bytes <= {16'hF1_06, 24'd0};
			cmd_len   <= 2;
			keep_open <= 0;
			cmd_ret   <= S_IDLE;
			cmd_i     <= 0;
			state     <= S_CFG;
		end

		S_IDLE: begin
			if (~old_dl & ioctl_download) begin
				rom_dl <= (ioctl_index == 0);
				if (ioctl_index == 0) begin
					ioctl_wait <= 1; // hold the first byte until the session is open
					cfg_i <= 0;
					state <= S_OPEN;
				end
			end
			else if (dl_end) begin
				dl_end <= 0;
				state <= S_CLOSE;
			end
			else if (ioctl_download & rom_dl & ioctl_wr) begin
				ioctl_wait <= 1;
				state <= S_STREAM;
			end
		end

		// send config pairs, then open a memory write session at $F80000
		S_OPEN: begin
			cmd_i <= 0;
			state <= S_CFG;
			if (cfg_i < NCFG) begin
				cmd_bytes <= {cfg[cfg_i], 24'd0};
				cmd_len   <= 2;
				keep_open <= 0;
				cmd_ret   <= S_OPEN;
				cfg_i     <= cfg_i + 1'd1;
			end
			else begin
				cmd_bytes <= {8'hF0, 8'h00, 8'h00, 8'hF8, 8'h00};
				cmd_len   <= 5;
				keep_open <= 1;
				cmd_ret   <= S_RUN;
			end
		end

		// generic command sender
		S_CFG: begin
			if (!io_uio) io_uio <= 1;
			else if (cmd_i < cmd_len) begin
				io_strobe <= 1;
				io_din    <= {8'h00, cmd_bytes[39:32]};
				cmd_bytes <= cmd_bytes << 8;
				cmd_i     <= cmd_i + 1'd1;
			end
			else begin
				if (!keep_open) io_uio <= 0;
				state <= cmd_ret;
			end
		end

		// a ROM byte is waiting (ioctl_wait held)
		S_STREAM: begin
			if (ioctl_addr == EXT_START) begin
				// re-open the session at $E00000 for the game ROM
				io_uio    <= 0;
				cmd_bytes <= {8'hF0, 8'h00, 8'h00, 8'hE0, 8'h00};
				cmd_len   <= 5;
				cmd_i     <= 0;
				keep_open <= 1;
				cmd_ret   <= S_BYTE;
				state     <= S_CFG;
			end
			else state <= S_BYTE;
		end

		S_BYTE: begin
			io_strobe <= 1;
			io_din    <= {8'h00, ioctl_dout};
			dly       <= 3;
			state     <= ioctl_addr[0] ? S_WAIT : S_RUN;
		end

		// odd byte completes a word: userio raises IO_WAIT until the host write is acked
		S_WAIT: begin
			if (dly) dly <= dly - 1'd1;
			else if (!io_wait) state <= S_RUN;
		end

		S_RUN: begin
			ioctl_wait <= 0;
			state <= S_IDLE;
		end

		// download finished: close the session and pulse a user reset
		S_CLOSE: begin
			io_uio    <= 0;
			cmd_bytes <= {16'hF1_03, 24'd0}; // CPU reset + user reset, halt released
			cmd_len   <= 2;
			cmd_i     <= 0;
			keep_open <= 0;
			cmd_ret   <= S_RESET;
			dly       <= '1;
			state     <= S_CFG;
		end

		S_RESET: begin
			if (dly) dly <= dly - 1'd1;
			else begin
				cmd_bytes <= {16'hF1_00, 24'd0};
				cmd_len   <= 2;
				cmd_i     <= 0;
				keep_open <= 0;
				cmd_ret   <= S_IDLE;
				state     <= S_CFG;
			end
		end

		default: state <= S_IDLE;
	endcase
end

endmodule
