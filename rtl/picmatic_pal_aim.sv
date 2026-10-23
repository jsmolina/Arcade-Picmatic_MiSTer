// SPDX-License-Identifier: GPL-3.0-or-later
// Marbella PAL50: virtual sensor encoding for the displayed 384x288 disc pixel.
// The unchanged ROM subtracts 0x44 CCK / 0x1d lines, doubles X, then subtracts
// signed NVRAM offsets. Kickstart View=(112,32) and the real Denise RGB pipeline
// put screen (0,0) at disc (20,10) with h_off=66,v_off=20. Invert that mapping;
// do not change live DMA/sync beam counters or the game's NVRAM/calibration.
module picmatic_pal_aim (
    input wire [11:0] gun_x, gun_y, // X is hires, Y is disc rows
    input wire signed [15:0] calibration_x, calibration_y,
    input wire [8:0] h_off, v_off,
    output wire [7:0] sensor_h,
    output wire [10:0] sensor_v,
    output wire valid
);
    wire signed [17:0] pixel_x = $signed({7'd0,gun_x[11:1]}) +
        $signed({9'd0,h_off}) + calibration_x + 18'sd50;
    wire signed [17:0] linear_h = pixel_x >>> 1;
    wire signed [17:0] linear_v = $signed({6'd0,gun_y}) +
        $signed({9'd0,v_off}) + calibration_y - 18'sd1;
    // The ROM also decodes CCK 0..39 as the right edge after the 227-CCK wrap.
    wire signed [17:0] wrapped_h = linear_h >= 18'sd227 ? linear_h - 18'sd227 : linear_h;
    assign valid = gun_x < 12'd768 && gun_y < 12'd288 &&
        linear_h >= 18'sd68 && linear_h < 18'sd267 &&
        linear_v >= 18'sd29 && linear_v < 18'sd311;
    assign sensor_h = valid ? wrapped_h[7:0] : 8'd1;
    assign sensor_v = valid ? linear_v[10:0] : 11'd311;
endmodule
