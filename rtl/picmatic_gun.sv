module picmatic_gun
(
	input             clk,
	input      [24:0] ps2_mouse,
	input       [3:0] x_adjust,
	input       [3:0] y_adjust,
	output reg  [9:0] picture_x = 10'd384,
	output reg  [8:0] picture_y = 9'd144,
	output     [11:0] gun_x,
	output     [11:0] gun_y
);

always @(posedge clk) begin
	reg old_stb = 0;
	reg signed [11:0] nx;
	reg signed [10:0] ny;

	old_stb <= ps2_mouse[24];
	if (old_stb != ps2_mouse[24]) begin
		nx = $signed({1'b0, picture_x}) +
		     $signed({{4{ps2_mouse[4]}}, ps2_mouse[15:8]});
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
