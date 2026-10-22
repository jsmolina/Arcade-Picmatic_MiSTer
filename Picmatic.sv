/********************************************/
/* Picmatic.sv                              */
/* Picmatic LaserDisc arcade (A500 + LDP)   */
/* MiSTer glue, from Minimig.sv             */
/* 2017-2020 Alexey Melnikov                */
/********************************************/

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign USER_OUT = '1;
assign BUTTONS = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign VGA_SCALER = 0;
assign LED_DISK = 0;
assign LED_POWER = 0;

// O[x] bit map: 1 gun side, 6:3 LD H pos, 10:7 LD V pos, 14:11 gun X adj, 18:15 gun Y adj,
//               19 crosshair, 22:20 scandoubler fx, 23 audio filter, 24 debug squares
`include "build_id.v"
localparam CONF_STR = {
	"Picmatic;;",
	"S0,DLV,Mount LaserDisc;",
	"-;",
	"O[1],Mouse/Joy 1 plays,Left,Right;",
	"O[19],Crosshair,On,Off;",
	"O[14:11],Gun X adjust,0,+4,+8,+12,+16,+20,+24,+28,-32,-28,-24,-20,-16,-12,-8,-4;",
	"O[18:15],Gun Y adjust,0,+2,+4,+6,+8,+10,+12,+14,-16,-14,-12,-10,-8,-6,-4,-2;",
	"-;",
	"O[6:3],Disc H position,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"O[10:7],Disc V position,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"O[22:20],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[23],Audio filter,On,Off;",
	"O[24],Debug squares,Off,On;",
	"-;",
	"R0,Reset;",
	"J1,Trigger,Holster,Coin,Start,Service;",
	"jn,A,B,Select,Start,X;",
	"V,v",`BUILD_DATE
};

////////////////////////////  HPS  ////////////////////////////////////

wire [31:0] joy0, joy1;
wire  [1:0] buttons;
wire [127:0] status;
wire        forced_scandoubler;
wire [24:0] ps2_mouse;
wire [21:0] gamma_bus;

wire        ioctl_download, ioctl_upload, ioctl_wr;
wire  [7:0] ioctl_index, ioctl_dout;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_din;
wire        ioctl_wait;

wire        img_mounted;
wire [63:0] img_size;
wire [31:0] sd_lba[1];
wire  [5:0] sd_blk_cnt[1];
wire        sd_rd, sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.joystick_0(joy0),
	.joystick_1(joy1),
	.buttons(buttons),
	.status(status),
	.status_menumask(0),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(0),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_wait(ioctl_wait | nv_wait),

	.img_mounted(img_mounted),
	.img_readonly(),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(1'b0),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{8'h00}),
	.sd_buff_wr(sd_buff_wr)
);

////////////////////////////  CLOCKS / RESET  ////////////////////////////////////

wire clk_114;
wire clk_sys;
wire locked;

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_114),
	.outclk_1(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

// PAL only: the reconfiguration port stays idle (Minimig uses it to switch to NTSC)
pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(0),
	.mgmt_address(0),
	.mgmt_writedata(0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

wire reset = ~locked | buttons[1] | RESET | status[0];

reg reset_d;
always @(posedge clk_sys, posedge reset) begin
	reg [7:0] reset_s;
	reg rs;

	if(reset) reset_s <= '1;
	else begin
		reset_s <= reset_s << 1;
		rs <= reset_s[7];
		reset_d <= rs;
	end
end

wire       clk7_en;
wire       clk7n_en;
wire       c1;
wire       c3;
wire       cck;
wire [9:0] eclk;

amiga_clk amiga_clk
(
	.clk_28   ( clk_sys    ),
	.clk7_en  ( clk7_en    ),
	.clk7n_en ( clk7n_en   ),
	.c1       ( c1         ),
	.c3       ( c3         ),
	.cck      ( cck        ),
	.eclk     ( eclk       ),
	.reset_n  ( ~reset     )
);

////////////////////////////  BOOT (MRA -> minimig)  ////////////////////////////////////

wire        io_uio, io_strobe, io_wait;
wire [15:0] io_din;

// power-on only: an OSD reset restarts the Amiga through rst_ext, the ROMs stay loaded
uio_boot uio_boot
(
	.clk(clk_sys),
	.reset(~locked),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_wait(ioctl_wait),
	.io_uio(io_uio),
	.io_strobe(io_strobe),
	.io_din(io_din),
	.io_wait(io_wait)
);

// NVRAM: MRA <nvram index="4" size="4096"/>
wire        nv_sel  = (ioctl_index == 4);
wire        nv_wait = 0;
wire  [7:0] nv_dout;
assign ioctl_din = nv_dout;

////////////////////////////  CPU  ////////////////////////////////////

wire cpu_type = cpucfg[1];
reg  cpu_ph1;
reg  cpu_ph2;
reg  ram_cs;
reg  cyc;

always @(posedge clk_114) begin
	reg [3:0] div;
	reg       c1d;

	div <= div + 1'd1;

	c1d <= c1;
	if (~c1d & c1) div <= 3;

	if (~cpu_rst) begin
		cyc <= 0;
		cpu_ph1 <= 0;
		cpu_ph2 <= 0;
	end
	else begin
		cyc <= !div[1:0];
		if (div[1] & ~div[0]) begin
			cpu_ph1 <= 0;
			cpu_ph2 <= 0;
			case (div[3:2])
				0: cpu_ph2 <= 1;
				2: cpu_ph1 <= 1;
			endcase
		end
	end

	ram_cs <= ~(ram_ready & cyc & cpu_type) & ram_sel;
end

wire  [1:0] cpu_state;
wire        cpu_nrst_out;
wire  [3:0] cpu_cacr;
wire [31:0] cpu_nmi_addr;
wire        cpu_rst;

wire  [2:0] chip_ipl;
wire        chip_dtack;
wire        chip_as;
wire        chip_uds;
wire        chip_lds;
wire        chip_rw;
wire [15:0] chip_dout;
wire [15:0] chip_din;
wire [23:1] chip_addr;
wire        chip32_en;
wire        chip_long;
wire [15:0] chip_din2;
wire [15:0] chip_rd2;
wire        ram_long;

wire [28:1] ram_addr;
wire        ram_sel;
wire        ram_lds;
wire        ram_uds;
wire [15:0] ram_din;
wire [15:0] ram_dout;
wire        ram_ready;

wire  [7:0] toccata_base, a2065_base, cdtv_base;
wire        toccata_ena, a2065_ena;
wire [15:0] cdtv_din;
wire        cdtv_selack;

wire        z2ram_ena;
wire  [4:0] z3ram_base0;
wire        z3ram_ena0;
wire  [3:0] z3ram_base1;
wire        z3ram_ena1;

cpu_wrapper #(.BOARDS(0)) cpu_wrapper
(
	.reset        (cpu_rst         ),
	.reset_out    (cpu_nrst_out    ),

	.clk          (clk_sys         ),
	.ph1          (cpu_ph1         ),
	.ph2          (cpu_ph2         ),

	.chip_addr    (chip_addr       ),
	.chip_dout    (chip_dout       ),
	.chip_din     (chip_din        ),
	.chip_as      (chip_as         ),
	.chip_uds     (chip_uds        ),
	.chip_lds     (chip_lds        ),
	.chip_rw      (chip_rw         ),
	.chip_dtack   (chip_dtack      ),
	.chip_ipl     (chip_ipl        ),
	.chip32_en    (chip32_en       ),
	.chip_long    (chip_long       ),
	.chip_din2    (chip_din2       ),
	.chip_dout2   (chip_rd2        ),

	.fastchip_dout   (16'h0000        ),
	.fastchip_sel    (                ),
	.fastchip_lds    (                ),
	.fastchip_uds    (                ),
	.fastchip_rnw    (                ),
	.fastchip_selack (1'b0            ),
	.fastchip_ready  (1'b0            ),
	.fastchip_lw     (                ),

	.cpucfg       (cpucfg          ),
	.ntsc         (ntsc            ),
	.cachecfg     (cachecfg        ),
	.fastramcfg   (memcfg[6:4]     ),
	.bootrom      (bootrom         ),

	.toccata_ena  (toccata_ena     ),
	.a2065_ena    (a2065_ena       ),
	.a2065_base   (a2065_base      ),
	.toccata_base (toccata_base    ),
	.cdtv_base    (cdtv_base       ),
	.cdtv_mode    (1'b0            ),

	.cdtv_din     (cdtv_din        ),
	.cdtv_selack  (cdtv_selack     ),

	.ramsel       (ram_sel         ),
	.ramaddr      (ram_addr        ),
	.ramlds       (ram_lds         ),
	.ramuds       (ram_uds         ),
	.ramdout      (ram_dout        ),
	.ramdin       (ram_din         ),
	.ramready     (ram_ready       ),
	.ramshared    (                ),
	.ramlong1     (                ),
	.ramdin_lo    (                ),
	.ramdout_hi   (16'h0000        ),
	.ramready_l   (1'b0            ),

	.cpustate     (cpu_state       ),
	.cacr         (cpu_cacr        ),
	.nmi_addr     (cpu_nmi_addr    ),

	.z2ram_ena    (z2ram_ena       ),
	.z3ram_base0  (z3ram_base0     ),
	.z3ram_ena0   (z3ram_ena0      ),
	.z3ram_base1  (z3ram_base1     ),
	.z3ram_ena1   (z3ram_ena1      ),
	.dcache_sw_en (dcache_sw_en    )
);

wire        dcache_sw_en;

////////////////////////////  SDRAM  ////////////////////////////////////

wire [24:1] arb_chip_addr;
wire        arb_chip_l;
wire        arb_chip_u;
wire        arb_chip_rw;
wire        arb_chip_dma;
wire [15:0] arb_chip_wr;
wire        arb_chip_long;
wire [15:0] arb_chip_wr2;

sdram_ctrl ram1
(
	.sysclk       (clk_114         ),
	.reset_n      (~reset_d        ),
	.c_7m         (c1              ),

	.cache_rst    (cpu_rst         ),
	.cpu_cache_ctrl(cpu_cacr       ),
	.dcache_sw_en (dcache_sw_en    ),

	.sd_data      (SDRAM_DQ        ),
	.sd_addr      (SDRAM_A         ),
	.sd_dqm       ({SDRAM_DQMH, SDRAM_DQML}),
	.sd_cs        (SDRAM_nCS       ),
	.sd_ba        (SDRAM_BA        ),
	.sd_we        (SDRAM_nWE       ),
	.sd_ras       (SDRAM_nRAS      ),
	.sd_cas       (SDRAM_nCAS      ),
	.sd_cke       (SDRAM_CKE       ),
	.sd_clk       (SDRAM_CLK       ),

	.cpuWR        (ram_din         ),
	.cpuAddr      (ram_addr[22:1]  ),
	.cpuU         (ram_uds         ),
	.cpuL         (ram_lds         ),
	.cpustate     (cpu_state       ),
	.cpuCS        (ram_cs          ),
	.cpuRD        (ram_dout        ),
	.ramready     (ram_ready       ),

	.chipWR       (arb_chip_wr     ),
	.chipAddr     (arb_chip_addr   ),
	.chipU        (arb_chip_u      ),
	.chipL        (arb_chip_l      ),
	.chipRW       (arb_chip_rw     ),
	.chipDMA      (arb_chip_dma    ),
	.chipRD       (ramdata_in      ),
	.chip48       (chip48          ),
	.chip32       (arb_chip_long   ),
	.chipWR2      (arb_chip_wr2    ),
	.chipRD2      (chip_rd2        )
);

chipdma_arb chipdma_arb
(
	.clk             (clk_sys              ),
	.reset           (reset_d              ),
	.c_7m            (c1                   ),

	.chip_in_addr    ({1'b0, ram_address}  ),
	.chip_in_l       (_ram_ble             ),
	.chip_in_u       (_ram_bhe             ),
	.chip_in_rw      (_ram_we              ),
	.chip_in_dma     (_ram_oe              ),
	.chip_in_wr      (ram_data             ),
	.chip_in_long    (ram_long             ),
	.chip_in_wr2     (chip_din2            ),

	.akiko_dma_req   (1'b0                 ),
	.akiko_dma_we    (1'b0                 ),
	.akiko_dma_baddr (24'd0                ),
	.akiko_dma_wbyte (8'd0                 ),
	.akiko_dma_rbyte (                     ),
	.akiko_dma_ack   (                     ),
	.akiko_arm       (                     ),

	.cdtv_dma_req    (1'b0                 ),
	.cdtv_dma_we     (1'b0                 ),
	.cdtv_dma_baddr  (32'd0                ),
	.cdtv_dma_wbyte  (8'd0                 ),
	.cdtv_dma_rbyte  (                     ),
	.cdtv_dma_ack    (                     ),

	.chip_out_addr   (arb_chip_addr        ),
	.chip_out_l      (arb_chip_l           ),
	.chip_out_u      (arb_chip_u           ),
	.chip_out_rw     (arb_chip_rw          ),
	.chip_out_dma    (arb_chip_dma         ),
	.chip_out_wr     (arb_chip_wr          ),
	.chip_out_long   (arb_chip_long        ),
	.chip_out_wr2    (arb_chip_wr2         ),
	.chip_in_rd      (ramdata_in           ),

	.z2ram_ena       (z2ram_ena            ),
	.z3ram_base0     (z3ram_base0          ),
	.z3ram_ena0      (z3ram_ena0           ),
	.z3ram_base1     (z3ram_base1          ),
	.z3ram_ena1      (z3ram_ena1           ),

	.ddr_out_addr    (                     ),
	.ddr_out_l       (                     ),
	.ddr_out_u       (                     ),
	.ddr_out_we      (                     ),
	.ddr_out_cs      (                     ),
	.ddr_out_wr      (                     ),
	.ddr_in_ack      (1'b0                 ),
	.ddr_in_rd       (16'h0000             )
);

////////////////////////////  CABINET  ////////////////////////////////////

// one player on mouse + joystick 1, the other side's coin/start/trigger on joystick 2
wire       side = status[1];          // 0 = left player, 1 = right player
wire [4:0] p_me  = {joy0[8], joy0[7], joy0[6], joy0[5] | ps2_mouse[1], joy0[4] | ps2_mouse[0]};
wire [4:0] p_oth = {1'b0,    joy1[7], joy1[6], joy1[5],                joy1[4]};
wire [4:0] p_l   = side ? p_oth : p_me;   // {service, start, coin, holster, trigger}
wire [4:0] p_r   = side ? p_me  : p_oth;

// WinUAE alg_flag bits 9..1: rholster lholster rtrig ltrig rcoin lcoin rstart lstart service
wire [9:1] pm_flag = {p_r[1], p_l[1], p_r[0], p_l[0], p_r[2], p_l[2], p_r[3], p_l[3], p_l[4] | p_r[4]};

// mouse gun: hires pixels across the disc picture, lines down it
reg  [9:0] gun_x = 384;
reg  [8:0] gun_y = 144;
always @(posedge clk_sys) begin
	reg old_stb;
	reg [10:0] nx;
	reg  [9:0] ny;

	old_stb <= ps2_mouse[24];
	if (old_stb != ps2_mouse[24]) begin
		nx = {1'b0, gun_x} + {{3{ps2_mouse[4]}}, ps2_mouse[15:8]};
		ny = {1'b0, gun_y} - {{2{ps2_mouse[5]}}, ps2_mouse[23:16]};
		gun_x <= nx[10] ? 10'd0 : (nx > 767) ? 10'd767 : nx[9:0];
		gun_y <= ny[9]  ?  9'd0 : (ny > 287) ?  9'd287 : ny[8:0];
	end
end

// gun registers: picture position plus the calibration knobs
wire [11:0] gun_x_reg = {2'b00, gun_x} + {{6{status[14]}}, status[14:11], 2'b00};
wire [11:0] gun_y_reg = {3'b000, gun_y} + {{7{status[18]}}, status[18:15], 1'b0};

////////////////////////////  LASERDISC  ////////////////////////////////////

wire        pm_txd, pm_rxd;
wire [15:0] pm_serper;
wire [16:0] ld_frame;
wire        ld_playing, ld_video_on, ld_seek;
wire  [1:0] ld_ch_en;

ld_player ld_player
(
	.clk(clk_sys),
	.clk7_en(clk7_en),
	.reset(reset_d),
	.hs_pulse(hs_fall),
	.vs_pulse(vs_fall),
	.serper(pm_serper),
	.txd(pm_txd),
	.rxd(pm_rxd),
	.disc_frames(17'd0),
	.frame(ld_frame),
	.playing(ld_playing),
	.ch_en(ld_ch_en),
	.video_on(ld_video_on),
	.seek(ld_seek)
);

wire signed [15:0] ld_pcm_l, ld_pcm_r;
wire  [8:0] fb_col;
wire  [9:0] fb_row;
wire  [7:0] ld_r, ld_g, ld_b;
wire        ld_valid;

// framebuffer column 0 / row 0 relative to the Amiga hsync / vsync, plus the OSD knobs
wire  [8:0] ld_h_off = 9'd66 + {{5{status[6]}}, status[6:3]};
wire  [8:0] ld_v_off = 9'd20 + {{5{status[10]}}, status[10:7]};

ld_video #(.CLK_HZ(28_375_160)) ld_video
(
	.clk(clk_sys),
	.reset(reset_d),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.sd_lba(sd_lba[0]),
	.sd_blk_cnt(sd_blk_cnt[0]),
	.sd_rd(sd_rd),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),

	.ld_frame(ld_frame),
	.ld_playing(ld_playing),
	.ld_ch_en(ld_ch_en),
	.ld_seek(ld_seek),

	.pcm_l(ld_pcm_l),
	.pcm_r(ld_pcm_r),

	.clk7_en(clk7_en),
	.hs_n(hs),
	.vs_n(vs),
	.h_off(ld_h_off),
	.v_off(ld_v_off),
	.ld_r(ld_r),
	.ld_g(ld_g),
	.ld_b(ld_b),
	.ld_valid(ld_valid),
	.beam_col(fb_col),
	.beam_row(fb_row),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

assign DDRAM_CLK = clk_sys;
assign LED_USER  = ld_playing;

////////////////////////////  MINIMIG  ////////////////////////////////////

wire  [4:0] cpucfg;
wire  [2:0] cachecfg;
wire  [6:0] memcfg;
wire        bootrom;
wire [15:0] ram_data;
wire [15:0] ramdata_in;
wire [47:0] chip48;
wire [23:1] ram_address;
wire        _ram_bhe;
wire        _ram_ble;
wire        _ram_we;
wire        _ram_oe;
wire [14:0] ldata;
wire [14:0] rdata;
wire        vs;
wire        hs;
wire        ntsc;
wire        zd;

minimig minimig
(
	//m68k pins
	.cpu_address  (chip_addr        ),
	.cpu_data     (chip_dout        ),
	.cpudata_in   (chip_din         ),
	._cpu_ipl     (chip_ipl         ),
	._cpu_as      (chip_as          ),
	._cpu_uds     (chip_uds         ),
	._cpu_lds     (chip_lds         ),
	.cpu_r_w      (chip_rw          ),
	.cpu_long     (chip_long        ),
	.chip32_en    (chip32_en        ),
	.ram_long     (ram_long         ),
	._cpu_dtack   (chip_dtack       ),
	._cpu_reset   (cpu_rst          ),
	._cpu_reset_in(cpu_nrst_out     ),
	.nmi_addr     (cpu_nmi_addr     ),

	//sram pins
	.ram_data     (ram_data         ),
	.ramdata_in   (ramdata_in       ),
	.ram_address  (ram_address      ),
	._ram_bhe     (_ram_bhe         ),
	._ram_ble     (_ram_ble         ),
	._ram_we      (_ram_we          ),
	._ram_oe      (_ram_oe          ),
	.chip48       (chip48           ),

	//system  pins
	.rst_ext      (reset_d          ),
	.rst_out      (                 ),
	.clk          (clk_sys          ),
	.clk7_en      (clk7_en          ),
	.clk7n_en     (clk7n_en         ),
	.c1           (c1               ),
	.c3           (c3               ),
	.cck          (cck              ),
	.eclk         (eclk             ),

	//rs232 pins: the LaserDisc player
	.rxd          (pm_rxd           ),
	.txd          (pm_txd           ),
	.cts          (1'b0             ),
	.rts          (                 ),
	.dtr          (                 ),
	.dsr          (1'b0             ),
	.cd           (1'b0             ),
	.ri           (1'b1             ),

	//I/O: cabinet inputs come in through picmatic.v, the game ports idle
	._joy1        (16'hFFFF         ),
	._joy2        (16'hFFFF         ),
	._joy3        (16'hFFFF         ),
	._joy4        (16'hFFFF         ),
	.joya1        (16'h0000         ),
	.joya2        (16'h0000         ),
	.mouse_btn    (3'b000           ),
	.kbd_mouse_data (8'h00          ),
	.kbd_mouse_type (2'b00          ),
	.kms_level    (1'b0             ),
	.pwr_led      (                 ),
	.fdd_led      (                 ),
	.hdd_led      (                 ),
	.rtc          (65'd0            ),

	//host controller interface
	.IO_UIO       (io_uio           ),
	.IO_FPGA      (1'b0             ),
	.IO_STROBE    (io_strobe        ),
	.IO_WAIT      (io_wait          ),
	.IO_DIN       (io_din           ),
	.IO_DOUT      (                 ),

	//video
	._hsync       (hs               ),
	._vsync       (vs               ),
	._csync       (                 ),
	.field1       (field1           ),
	.lace         (lace             ),
	.red          (r                ),
	.green        (g                ),
	.blue         (b                ),
	.hblank       (hblank           ),
	.vblank       (vbl              ),
	.ar           (                 ),
	.scanline     (                 ),
	.ce_pix       (                 ),
	.res          (res              ),
	.ntsc         (ntsc             ),
	.zd           (zd               ),

	//audio
	.ldata        (ldata            ),
	.rdata        (rdata            ),
	.ldata_okk    (                 ),
	.rdata_okk    (                 ),
	.aud_mix      (                 ),

	.toccata_ena  (toccata_ena      ),
	.toccata_base (toccata_base     ),
	.cdtv_base    (cdtv_base        ),
	.a2065_ena    (a2065_ena        ),
	.a2065_base   (a2065_base       ),
	.toccata_aud_left (             ),
	.toccata_aud_right(             ),

	.cdtv_mode           (                 ),
	.cdtv_din            (cdtv_din         ),
	.cdtv_selack         (cdtv_selack      ),
	.cdtv_cs             (1'b0             ),
	.cdtv_cs_sec         (1'b0             ),
	.cdtv_cs_stch        (1'b0             ),
	.cdtv_cs_nvr         (1'b0             ),
	.cdtv_cs_card        (1'b0             ),
	.cdtv_wr             (1'b0             ),
	.cdtv_rd             (1'b0             ),
	.cdtv_uio_din        (16'h0000         ),
	.cdtv_uio_dout       (                 ),
	.cdtv_req            (                 ),
	.cdtv_subq_push      (1'b0             ),
	.cdtv_subq_byte      (8'h00            ),
	.cdtv_sten_pulse     (1'b0             ),
	.cdtv_scor_pulse     (1'b0             ),
	.cdtv_sbcp_pulse     (1'b0             ),
	.cdtv_dma_req        (                 ),
	.cdtv_dma_we         (                 ),
	.cdtv_dma_baddr      (                 ),
	.cdtv_dma_wbyte      (                 ),
	.cdtv_dma_ack        (1'b0             ),
	.cdtv_nvr_dirty      (                 ),
	.cdtv_card_dirty     (                 ),
	.cdtv_cdda_volume    (                 ),
	.cdtv_cdda_volume_valid(               ),

	//Picmatic board
	.picmatic     (1'b1             ),
	.pm_flag      (pm_flag          ),
	.pm_gun_x     (gun_x_reg        ),
	.pm_gun_y     (gun_y_reg        ),
	.pm_serper    (pm_serper        ),
	.pm_nv_addr   (ioctl_addr[11:0] ),
	.pm_nv_din    (ioctl_dout       ),
	.pm_nv_we     (ioctl_download & ioctl_wr & nv_sel),
	.pm_nv_dout   (nv_dout          ),

	//user i/o
	.cachecfg     (cachecfg         ),
	.cpucfg       (cpucfg           ),
	.memcfg       (memcfg           ),
	.bootrom      (bootrom          ),

	.ide_fast     (                 ),
	.ide_ext_irq  (1'b0             ),
	.akiko_irq    (1'b0             ),
	.ide_ena      (                 ),
	.ide_req      (                 ),
	.ide_address  (5'd0             ),
	.ide_write    (1'b0             ),
	.ide_writedata(16'h0000         ),
	.ide_read     (1'b0             ),
	.ide_readdata (                 ),

	.a2065_clk_ddr(clk_sys          ),
	.a2065_mem_address(             ),
	.a2065_mem_burstcount(          ),
	.a2065_mem_read(                ),
	.a2065_mem_readdata(64'd0       ),
	.a2065_mem_readdatavalid(1'b0   ),
	.a2065_mem_writedata(           ),
	.a2065_mem_byteenable(          ),
	.a2065_mem_write(               ),
	.a2065_mem_waitrequest(1'b0     ),

	.USER_IN      (7'h7F            ),
	.USER_OUT     (                 ),
	.user_port_mode(                ),
	.mister_floppy_status(          ),
	.drive_snd    (                 )
);

////////////////////////////  VIDEO  ////////////////////////////////////

reg hs_d, vs_d;
always @(posedge clk_sys) begin
	hs_d <= hs;
	vs_d <= vs;
end
wire hs_fall = hs_d & ~hs;
wire vs_fall = vs_d & ~vs;

// genlock: Amiga colour 0 shows the disc. ld_valid is pipelined to match Denise's output.
// Crosshair: a cross at the mouse gun, one disc pixel = two hires pixels.
wire       xhair  = ~status[19] &&
                    (((fb_col == gun_x[9:1]) && (fb_row + 4'd6 >= gun_y) && (fb_row <= gun_y + 4'd6)) ||
                     ((fb_row == gun_y) && (fb_col + 4'd6 >= gun_x[9:1]) && (fb_col <= gun_x[9:1] + 4'd6)));
reg  [1:0] xhair_d;
always @(posedge clk_sys) xhair_d <= {xhair_d[0], xhair};

// Debug overlay (OSD): four squares top left, lit as the boot gets further.
// red: CPU touched the game ROM, yellow: game set the LD serial rate, cyan: game sent a search, green: disc playing
reg [2:0] dbg_seen;
always @(posedge clk_sys) begin
	if (reset_d) dbg_seen <= 0;
	else dbg_seen <= dbg_seen | {ld_seek, |pm_serper, chip_addr[23:18] == 6'b111100};
end
wire [3:0] dbg_on  = {ld_playing, dbg_seen[2], dbg_seen[1], dbg_seen[0]};
wire [1:0] dbg_idx = fb_col[5:4];
wire       dbg_px  = status[24] && fb_row >= 4 && fb_row < 12 && fb_col < 64 && fb_col[3:0] >= 4 && fb_col[3:0] < 12;
reg  [1:0] dbg_d;
reg  [1:0] dbg_idx_d0, dbg_idx_d1;
always @(posedge clk_sys) begin
	dbg_d      <= {dbg_d[0], dbg_px};
	dbg_idx_d0 <= dbg_idx;
	dbg_idx_d1 <= dbg_idx_d0;
end
wire [23:0] dbg_rgb = !dbg_on[dbg_idx_d1]  ? 24'h404040 :
                      dbg_idx_d1 == 0      ? 24'hFF0000 :
                      dbg_idx_d1 == 1      ? 24'hFFFF00 :
                      dbg_idx_d1 == 2      ? 24'h00FFFF : 24'h00FF00;

wire       show_ld = zd & ld_valid & ld_video_on;
wire [7:0] mr = xhair_d[1] ? 8'hFF : dbg_d[1] ? dbg_rgb[23:16] : show_ld ? ld_r : r;
wire [7:0] mg = xhair_d[1] ? 8'h00 : dbg_d[1] ? dbg_rgb[15:8]  : show_ld ? ld_g : g;
wire [7:0] mb = xhair_d[1] ? 8'h00 : dbg_d[1] ? dbg_rgb[7:0]   : show_ld ? ld_b : b;

reg ce_out = 0;
always @(posedge CLK_VIDEO) begin
	reg [3:0] div;
	reg [3:0] add;
	reg [1:0] fs_res;
	reg old_vs;

	div <= div + add;
	if(~hblank & ~vblank) fs_res <= fs_res | res;

	old_vs <= vs;
	if(old_vs & ~vs) begin
		fs_res <= 0;
		div <= 0;
		add <= 1; // 7MHz
		if(fs_res[0]) add <= 2; // 14MHz
		if(fs_res[1] | ~scandoubler) add <= 4; // 28MHz
	end

	ce_out <= div[3] & !div[2:0];
end

wire [2:0] fx = status[22:20];
wire       scandoubler = (fx || forced_scandoubler) & ~lace;

video_mixer #(.LINE_LENGTH(2000), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
	.*,
	.hq2x(fx==1),
	.ce_pix(ce_out),
	.freeze_sync(),

	.R(mr),
	.G(mg),
	.B(mb),
	.HSync(~hs),
	.VSync(~vs),
	.HBlank(~hde),
	.VBlank(~vde)
);

assign CLK_VIDEO = clk_114;
assign VGA_F1    = field1;

video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),
	.ARX(12'd4),
	.ARY(12'd3),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(0)
);

wire [2:0] sl = fx ? fx - 1'd1 : 3'd0;
assign VGA_SL = sl[1:0];

reg  hde;
wire vde = ~(fvbl | svbl);

wire [7:0] r,g,b;
wire lace, field1;
wire hblank, vbl;
wire vblank = vbl | ~vs;
reg  fhbl, fvbl, shbl, svbl;
wire hbl = fhbl | shbl | ~hs;

wire  [1:0] res;

reg  [11:0] hsta, hend, hmax, hcnt;
always @(posedge clk_sys) begin
	reg old_hs;
	reg old_hblank;

	old_hs <= hs;
	old_hblank <= hblank;

	hcnt <= hcnt + 1'd1;
	if(~hs) hcnt <= 0;

	if(old_hblank & ~hblank) hend <= hcnt;
	if(~old_hblank & hblank) hsta <= hcnt;
	if(old_hs & ~hs)         hmax <= hcnt;

	if(hcnt == hend-2'd2) shbl <= 0;
	if(hcnt == hsta-2'd2) shbl <= 1;

	//force hblank
	if(hcnt == 8)         fhbl <= 0;
	if(hcnt == hmax-4'd8) fhbl <= 1;
end

reg [11:0] vend, vmax, vcnt, vs_end;
always @(posedge clk_sys) begin
	reg old_vs;
	reg old_vblank, old_hs, old_hbl;

	old_vs <= vs;
	old_hs <= hs;
	old_vblank <= vblank;

	if(old_hs & ~hs) vcnt <= vcnt + 1'd1;
	if(~old_vblank & vblank) vcnt <= 0;

	if(~lace | ~field1) begin
		if(old_vblank & ~vblank) vend <= vcnt;
		if(~old_vs & vs)         vs_end <= vcnt;
		if(~old_vblank & vblank) vmax <= vcnt;
	end

	old_hbl <= hbl;
	if((old_hbl & ~hbl) | !vcnt) begin
		if(vcnt == vend) svbl <= 0;
		if(vcnt == vmax) svbl <= 1;

		//force vblank
		if(vcnt == vmax-1)    fvbl <= 1;
		if(vcnt == vs_end+2)  fvbl <= 0;
	end

	hde <= ~hbl;
end

////////////////////////////  AUDIO  ////////////////////////////////////

wire [15:0] paula_smp_l = {ldata[14:0], 1'b0};
wire [15:0] paula_smp_r = {rdata[14:0], 1'b0};

// LPF 4400Hz, 1st order, 6db/oct
wire [15:0] lpf4400_l, lpf4400_r;
IIR_filter #(0) lpf4400
(
	.clk(clk_sys),
	.reset(reset),

	.ce(clk7_en | clk7n_en),
	.sample_ce(1),

	.cx (40'd4304835800),
	.cx0(1),
	.cy0(-2088941),

	.input_l(paula_smp_l),
	.input_r(paula_smp_r),
	.output_l(lpf4400_l),
	.output_r(lpf4400_r)
);

wire [15:0] audm_l = status[23] ? paula_smp_l : lpf4400_l;
wire [15:0] audm_r = status[23] ? paula_smp_r : lpf4400_r;

reg [15:0] aud_l, aud_r, ld_l, ld_r16;
always @(posedge CLK_AUDIO) begin
	reg [15:0] old_l0, old_l1, old_r0, old_r1;
	reg [31:0] old_d0, old_d1;

	old_l0 <= audm_l;
	old_l1 <= old_l0;
	if(old_l0 == old_l1) aud_l <= old_l1;

	old_r0 <= audm_r;
	old_r1 <= old_r0;
	if(old_r0 == old_r1) aud_r <= old_r1;

	old_d0 <= {ld_pcm_l, ld_pcm_r};
	old_d1 <= old_d0;
	if(old_d0 == old_d1) {ld_l, ld_r16} <= old_d1;
end

reg [15:0] out_l, out_r;
always @(posedge CLK_AUDIO) begin
	reg [16:0] tmp_l, tmp_r;

	tmp_l <= {aud_l[15], aud_l} + {ld_l[15], ld_l};
	tmp_r <= {aud_r[15], aud_r} + {ld_r16[15], ld_r16};

	// clamp the output
	out_l <= (tmp_l[16] == tmp_l[15]) ? tmp_l[15:0] : {tmp_l[16], {15{~tmp_l[16]}}};
	out_r <= (tmp_r[16] == tmp_r[15]) ? tmp_r[15:0] : {tmp_r[16], {15{~tmp_r[16]}}};
end

assign AUDIO_S = 1;
assign AUDIO_L = out_l;
assign AUDIO_R = out_r;
assign AUDIO_MIX = 0;

endmodule
