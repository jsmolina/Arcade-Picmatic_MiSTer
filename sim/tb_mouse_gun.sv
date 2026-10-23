`timescale 1ns/1ps
module tb_mouse_gun;

reg clk = 0;
always #5 clk = ~clk;

reg [24:0] ps2_mouse = 0;
reg [15:0] joystick_analog = 0;
reg [3:0] x_adjust = 0;
reg [3:0] y_adjust = 0;
wire [9:0] picture_x;
wire [8:0] picture_y;
wire [11:0] gun_x;
wire [11:0] gun_y;
reg sel_io = 0, hwr = 0, lwr = 0;
reg [23:1] addr = 0;
reg [15:0] din = 0;
wire [15:0] dout;
wire [9:1] flag = {3'b000, ps2_mouse[0], 5'b00000};
wire joy_sel;
wire [15:0] joy_dout, serper;
wire [7:0] nv_dout;

picmatic_gun dut
(
	.clk(clk),
	.ps2_mouse(ps2_mouse),
	.joystick_analog(joystick_analog),
	.x_adjust(x_adjust),
	.y_adjust(y_adjust),
	.picture_x(picture_x),
	.picture_y(picture_y),
	.gun_x(gun_x),
	.gun_y(gun_y)
);

picmatic board
(
	.clk(clk), .clk7_en(1'b1), .reset(1'b0),
	.sel_nvram(1'b0), .sel_io(sel_io), .addr(addr), .din(din), .dout(dout), .hwr(hwr), .lwr(lwr),
	.reg_address(8'd0), .reg_din(16'd0), .joy_sel(joy_sel), .joy_dout(joy_dout), .serper(serper),
	.flag(flag), .gun_x0(gun_x), .gun_y0(gun_y), .gun_x1(gun_x), .gun_y1(gun_y),
	.nv_addr(12'd0), .nv_din(8'd0), .nv_we(1'b0), .nv_dout(nv_dout)
);

task check_gun(input [11:0] expected_x, input [11:0] expected_y);
	begin
		#1;
		if (gun_x !== expected_x || gun_y !== expected_y)
			$fatal(1, "gun latch (%0d,%0d), expected (%0d,%0d)",
			       gun_x, gun_y, expected_x, expected_y);
	end
endtask

task check_board_coordinates;
	reg [7:0] y_low, x_low, high;
	reg [11:0] read_x, read_y;
	begin
		@(negedge clk); sel_io = 1; addr = {8'hF6, 4'd0, 11'h000};
		@(negedge clk); y_low = dout[7:0];
		addr = {8'hF6, 4'd1, 11'h000};
		@(negedge clk); x_low = dout[7:0];
		addr = {8'hF6, 4'd2, 11'h000};
		@(negedge clk); high = dout[7:0];
		@(negedge clk); sel_io = 0;
		read_x = {high[7:4], x_low};
		read_y = {high[3:0], y_low};
		if (read_x !== gun_x || read_y !== gun_y)
			$fatal(1, "F6 read (%0d,%0d) differs from shot target (%0d,%0d)",
			       read_x, read_y, gun_x, gun_y);
	end
endtask

task check_board_trigger(input [7:0] expected);
	begin
		@(negedge clk); sel_io = 1; addr = {8'hF6, 4'd3, 11'h000};
		@(negedge clk); @(negedge clk);
		if (dout[7:0] !== expected)
			$fatal(1, "F6 trigger value %02h, expected %02h", dout[7:0], expected);
		sel_io = 0;
	end
endtask

task check_target_alignment;
	begin
		if (gun_x != picture_x || gun_y != picture_y)
			$fatal(1, "shot target (%0d,%0d) differs from cursor target (%0d,%0d)",
			       gun_x, gun_y, picture_x, picture_y);
	end
endtask

task mouse_packet(input [7:0] dx, input x_sign, input [7:0] dy, input y_sign);
	begin
		@(negedge clk);
		ps2_mouse[4] = x_sign;
		ps2_mouse[15:8] = dx;
		ps2_mouse[5] = y_sign;
		ps2_mouse[23:16] = dy;
		ps2_mouse[24] = ~ps2_mouse[24];
		@(negedge clk);
		ps2_mouse[15:8] = 0;
		ps2_mouse[23:16] = 0;
	end
endtask

initial begin
	// Game shot coordinates match the cursor's position within the disc picture.
	check_gun(12'd384, 12'd144);
	check_target_alignment();
	check_board_coordinates();

	// A left mouse click reaches the trigger bit while preserving the aimed point.
	ps2_mouse[0] = 1;
	check_board_trigger(8'hDF);
	check_board_coordinates();
	ps2_mouse[0] = 0;
	check_board_trigger(8'hFF);

	// WinUAE reports horizontal lightpen position in hires units: each lores X step is two.
	mouse_packet(8'd20, 0, 8'd10, 0);
	check_gun(12'd424, 12'd134);
	check_target_alignment();
	check_board_coordinates();

	// Verify the OSD calibration uses signed quarter-/half-steps as advertised.
	x_adjust = 4'd8;  // -32
	y_adjust = 4'd8;  // -16
	check_gun(12'd392, 12'd118);
	check_board_coordinates();

	// Both lower and upper mouse bounds clamp instead of wrapping.
	x_adjust = 0;
	y_adjust = 0;
	repeat (4) mouse_packet(8'd128, 1, 8'd127, 0);
	check_gun(12'd0, 12'd0);
	repeat (7) mouse_packet(8'd127, 0, 8'd128, 1);
	check_gun(12'd767, 12'd287);

	// MiSTer Main calibrated lightguns arrive as signed absolute analog axes.
	joystick_analog = {8'h81, 8'h81}; // (-127,-127) -> top left
	@(negedge clk);
	check_gun(12'd0, 12'd0);
	check_board_coordinates();
	joystick_analog = {8'h7F, 8'h7F}; // (+127,+127) -> bottom right
	@(negedge clk);
	check_gun(12'd767, 12'd287);
	check_board_coordinates();
	joystick_analog = 16'h0000; // center -> center
	@(negedge clk);
	check_gun(12'd384, 12'd144);
	check_board_coordinates();

	$display("PASS tb_mouse_gun");
	$finish;
end

endmodule
