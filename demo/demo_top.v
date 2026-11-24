// demo_top.v - presentation image: Design 1 and Design 2 in one FPGA, SW[9] picks
// which one owns the keys, switches, LEDs and 7-segment displays.
//
//   SW[9] = 1  Design 1 (design1/src/DE2_Project1.vhd, unchanged)
//   SW[9] = 0  Design 2 (design2/quartus/de2_top.v, unchanged)
// SW[9] is used by neither design.
//
// Both designs run all the time. Only the inputs and outputs are switched:
//  - Design 2 keeps its enrolled signatures while Design 1 is shown: its keys read
//    "not pressed" (so KEY3 does not reset the Nios and KEY0 does not take a baseline)
//    and its switches stay at the last value seen before SW[9] went up. Only SW[9] itself
//    reaches Design 2 live: the Nios turns the LCD text off while it is up (main.c).
//  - Design 1 sees no key presses while Design 2 is shown, so the counter keeps its value.
//  - LCD, VGA, SDRAM and the sensor header always belong to Design 2 (Design 1 uses none).
//    LCD_ON stays 1: it is the LCD power, and power off would lose the LCD setup.
module demo_top (
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
    inout  [35:0] GPIO_0,
    output        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK, VGA_SYNC,
    output [9:0]  VGA_R, VGA_G, VGA_B
);
    wire d1 = SW[9];

    reg [17:0] sw2 = 18'd0;                 // Design 2 switches, frozen while Design 1 is shown
    always @(posedge CLOCK_50) if (!d1) sw2 <= SW;

    wire [17:0] r1, r2;
    wire [7:0]  g1;
    wire [8:0]  g2;
    wire [55:0] h1, h2;                      // HEX7..HEX0, 7 segments each

    DE2_Project1 u_design1 (
        .CLOCK_50(CLOCK_50), .KEY(d1 ? KEY : 4'hF), .SW(SW), .LEDR(r1), .LEDG(g1),
        .HEX0(h1[6:0]),   .HEX1(h1[13:7]),  .HEX2(h1[20:14]), .HEX3(h1[27:21]),
        .HEX4(h1[34:28]), .HEX5(h1[41:35]), .HEX6(h1[48:42]), .HEX7(h1[55:49])
    );

    de2_top u_design2 (
        .CLOCK_50(CLOCK_50), .KEY(d1 ? 4'hF : KEY), .SW({sw2[17:10], d1, sw2[8:0]}), .LEDR(r2), .LEDG(g2),
        .HEX0(h2[6:0]),   .HEX1(h2[13:7]),  .HEX2(h2[20:14]), .HEX3(h2[27:21]),
        .HEX4(h2[34:28]), .HEX5(h2[41:35]), .HEX6(h2[48:42]), .HEX7(h2[55:49]),
        .LCD_ON(LCD_ON), .LCD_BLON(LCD_BLON), .LCD_RS(LCD_RS), .LCD_RW(LCD_RW), .LCD_EN(LCD_EN),
        .LCD_DATA(LCD_DATA),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_DQ(DRAM_DQ), .DRAM_BA_0(DRAM_BA_0), .DRAM_BA_1(DRAM_BA_1),
        .DRAM_LDQM(DRAM_LDQM), .DRAM_UDQM(DRAM_UDQM), .DRAM_RAS_N(DRAM_RAS_N), .DRAM_CAS_N(DRAM_CAS_N),
        .DRAM_WE_N(DRAM_WE_N), .DRAM_CS_N(DRAM_CS_N), .DRAM_CLK(DRAM_CLK), .DRAM_CKE(DRAM_CKE),
        .GPIO_0(GPIO_0),
        .VGA_CLK(VGA_CLK), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_BLANK(VGA_BLANK), .VGA_SYNC(VGA_SYNC),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B)
    );

    assign LEDR = d1 ? r1 : r2;
    assign LEDG = d1 ? {1'b0, g1} : g2;
    assign {HEX7, HEX6, HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = d1 ? h1 : h2;
endmodule
