// de2_top.v - board top level: connects the Qsys system to the DE2 pins.
//
// KEY[3] is the reset. KEY[2:0] and SW go to the CPU through one input PIO.
// SDRAM clock: 50 MHz shifted by -3 ns so data settles before the chip samples it
// (same as Altera's DE2 SDRAM tutorial).
//
// Sensors (3.3 V only, header pin numbers in brackets):
//   bus 0: SDA GPIO_0[0]  (1),  SCL GPIO_0[2]  (3)
//   bus 1: SDA GPIO_0[4]  (5),  SCL GPIO_0[6]  (7)
//   bus 2: SDA GPIO_0[10] (13), SCL GPIO_0[12] (15)
//   bus 3: SDA GPIO_0[14] (17), SCL GPIO_0[16] (19)
//   Power: 3.3 V from header pin 29, ground pin 30 or 12.
//   Header pin 11 carries 5 V: never connect it to a sensor.
module de2_top (
    input         CLOCK_50,
    input  [3:0]  KEY,
    input  [17:0] SW,
    output [17:0] LEDR,
    output [8:0]  LEDG,
    output [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7,
    output        LCD_ON, LCD_BLON, LCD_RS, LCD_RW, LCD_EN,
    inout  [7:0]  LCD_DATA,
    output [11:0] DRAM_ADDR,
    inout  [15:0] DRAM_DQ,
    output        DRAM_BA_0, DRAM_BA_1, DRAM_LDQM, DRAM_UDQM,
    output        DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CLK, DRAM_CKE,
    inout  [35:0] GPIO_0
);
    wire [3:0] sda_oe, scl_oe;
    wire [1:0] ba, dqm;
    wire [26:0] leds;
    wire [31:0] bcd;

    assign {DRAM_BA_1, DRAM_BA_0} = ba;
    assign {DRAM_UDQM, DRAM_LDQM} = dqm;
    assign {LEDG, LEDR} = leds;
    assign LCD_ON = 1'b1;
    assign LCD_BLON = 1'b1;

    // Open drain: drive low or release. Pull-ups are on the sensor modules.
    assign GPIO_0[0]  = sda_oe[0] ? 1'b0 : 1'bz;
    assign GPIO_0[2]  = scl_oe[0] ? 1'b0 : 1'bz;
    assign GPIO_0[4]  = sda_oe[1] ? 1'b0 : 1'bz;
    assign GPIO_0[6]  = scl_oe[1] ? 1'b0 : 1'bz;
    assign GPIO_0[10] = sda_oe[2] ? 1'b0 : 1'bz;
    assign GPIO_0[12] = scl_oe[2] ? 1'b0 : 1'bz;
    assign GPIO_0[14] = sda_oe[3] ? 1'b0 : 1'bz;
    assign GPIO_0[16] = scl_oe[3] ? 1'b0 : 1'bz;

    magic_pen_sys u_sys (
        .clk_clk         (CLOCK_50),
        .reset_reset_n   (KEY[3]),
        .sdram_wire_addr (DRAM_ADDR),
        .sdram_wire_ba   (ba),
        .sdram_wire_cas_n(DRAM_CAS_N),
        .sdram_wire_cke  (DRAM_CKE),
        .sdram_wire_cs_n (DRAM_CS_N),
        .sdram_wire_dq   (DRAM_DQ),
        .sdram_wire_dqm  (dqm),
        .sdram_wire_ras_n(DRAM_RAS_N),
        .sdram_wire_we_n (DRAM_WE_N),
        .lcd_RS          (LCD_RS),
        .lcd_RW          (LCD_RW),
        .lcd_data        (LCD_DATA),
        .lcd_E           (LCD_EN),
        .pio_in_export   ({KEY, SW}),
        .pio_led_export  (leds),
        .pio_hex_export  (bcd),
        .i2c_sda_oe      (sda_oe),
        .i2c_scl_oe      (scl_oe),
        .i2c_sda_in      ({GPIO_0[14], GPIO_0[10], GPIO_0[4], GPIO_0[0]}),
        .i2c_scl_in      ({GPIO_0[16], GPIO_0[12], GPIO_0[6], GPIO_0[2]})
    );

    wire [5:0] pll_clk;
    assign DRAM_CLK = pll_clk[0];
    altpll #(
        .intended_device_family("Cyclone II"),
        .operation_mode("NORMAL"),
        .inclk0_input_frequency(20000),
        .clk0_multiply_by(1),
        .clk0_divide_by(1),
        .clk0_phase_shift("-3000"),
        .clk0_duty_cycle(50),
        .port_clk0("PORT_USED")
    ) u_sdram_pll (
        .inclk({1'b0, CLOCK_50}),
        .clk(pll_clk)
    );

    hex7seg h0 (bcd[3:0],   HEX0);
    hex7seg h1 (bcd[7:4],   HEX1);
    hex7seg h2 (bcd[11:8],  HEX2);
    hex7seg h3 (bcd[15:12], HEX3);
    hex7seg h4 (bcd[19:16], HEX4);
    hex7seg h5 (bcd[23:20], HEX5);
    hex7seg h6 (bcd[27:24], HEX6);
    hex7seg h7 (bcd[31:28], HEX7);
endmodule

// 7-segment decoder, segments active low (DE2).
module hex7seg (input [3:0] d, output reg [6:0] seg);
    always @* case (d)
        4'h0: seg = 7'b1000000;
        4'h1: seg = 7'b1111001;
        4'h2: seg = 7'b0100100;
        4'h3: seg = 7'b0110000;
        4'h4: seg = 7'b0011001;
        4'h5: seg = 7'b0010010;
        4'h6: seg = 7'b0000010;
        4'h7: seg = 7'b1111000;
        4'h8: seg = 7'b0000000;
        4'h9: seg = 7'b0010000;
        default: seg = 7'b1111111;
    endcase
endmodule
