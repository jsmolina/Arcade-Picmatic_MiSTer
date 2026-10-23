module picmatic_gun
(
	input             clk,
	input      [24:0] ps2_mouse,
	input      [15:0] joystick_analog,
	input       [3:0] x_adjust,
	input       [3:0] y_adjust,
	output reg  [9:0] picture_x = 10'd384,
	output reg  [8:0] picture_y = 9'd144,
	output     [11:0] gun_x,
	output     [11:0] gun_y
);

// MiSTer Main sends calibrated lightgun ABS_X/ABS_Y as signed analog joystick
// coordinates. Its normalization is -127 at the calibrated minimum and +127
// at the maximum. Convert these values into the Picmatic board's 768x288
// coordinate space. Ordinary mice do not update this port and use the relative
// PS/2 path below.
function automatic [9:0] analog_x_to_picture(input signed [7:0] axis);
	reg [8:0] offset;
	reg [18:0] scaled;
	begin
		if (axis <= -8'sd127) analog_x_to_picture = 10'd0;
		else begin
			offset = axis + 9'sd127;
			scaled = (offset * 10'd767) + 19'd127;
			analog_x_to_picture = scaled / 19'd254;
		end
	end
endfunction

function automatic [8:0] analog_y_to_picture(input signed [7:0] axis);
	reg [8:0] offset;
	reg [16:0] scaled;
	begin
		if (axis <= -8'sd127) analog_y_to_picture = 9'd0;
		else begin
			offset = axis + 9'sd127;
			scaled = (offset * 9'd287) + 17'd127;
			analog_y_to_picture = scaled / 17'd254;
		end
	end
endfunction

always @(posedge clk) begin
	reg old_stb = 0;
	reg [15:0] old_analog = 0;
	reg signed [11:0] nx;
	reg signed [10:0] ny;

	old_stb <= ps2_mouse[24];
	old_analog <= joystick_analog;
	if (old_analog != joystick_analog) begin
		picture_x <= analog_x_to_picture($signed(joystick_analog[7:0]));
		picture_y <= analog_y_to_picture($signed(joystick_analog[15:8]));
	end else if (old_stb != ps2_mouse[24]) begin
		// WinUAE converts the lightpen X input from lores pixels to hires coordinates.
		nx = $signed({1'b0, picture_x}) +
		     ($signed({{4{ps2_mouse[4]}}, ps2_mouse[15:8]}) <<< 1);
		ny = $signed({1'b0, picture_y}) -
		     $signed({{3{ps2_mouse[5]}}, ps2_mouse[23:16]});
		picture_x <= (nx < 0) ? 10'd0 : (nx > 767) ? 10'd767 : nx[9:0];
		picture_y <= (ny < 0) ?  9'd0 : (ny > 287) ?  9'd287 : ny[8:0];
	end
end

wire signed [5:0] x_adjust_pixels = $signed({{2{x_adjust[3]}}, x_adjust}) <<< 2;
wire signed [4:0] y_adjust_pixels = $signed({y_adjust[3], y_adjust}) <<< 1;

assign gun_x = {2'b00, picture_x} + {{6{x_adjust_pixels[5]}}, x_adjust_pixels};
assign gun_y = {3'b000, picture_y} + {{7{y_adjust_pixels[4]}}, y_adjust_pixels};

endmodule
