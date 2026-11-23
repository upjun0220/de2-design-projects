// tb_demo_top.v - checks the SW[9] switching of demo_top.v. Both designs are replaced by
// stubs that show their KEY/SW inputs on their outputs, so only the switching is tested.
// Run: sh demo/sim.sh   Last line "# PASS" when everything holds.
`timescale 1ns/1ns
module DE2_Project1 (input CLOCK_50, input [3:0] KEY, input [17:0] SW, output [17:0] LEDR,
                     output [7:0] LEDG, output [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7);
    assign LEDR = {10'h0, KEY, 4'h1};        // marker 1 = Design 1
    assign LEDG = 8'hA1;
    assign {HEX7, HEX6, HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {8{7'h11}};
endmodule

module de2_top (input CLOCK_50, input [3:0] KEY, input [17:0] SW, output [17:0] LEDR, output [8:0] LEDG,
                output [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7,
                output LCD_ON, LCD_BLON, LCD_RS, LCD_RW, LCD_EN, inout [7:0] LCD_DATA,
                output [11:0] DRAM_ADDR, inout [15:0] DRAM_DQ,
                output DRAM_BA_0, DRAM_BA_1, DRAM_LDQM, DRAM_UDQM,
                output DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CLK, DRAM_CKE,
                inout [35:0] GPIO_0, output VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK, VGA_SYNC,
                output [9:0] VGA_R, VGA_G, VGA_B);
    assign LEDR = SW;                        // Design 2 shows the switches it sees
    assign LEDG = {KEY, 5'h02};              // and its keys; marker 2 = Design 2
    assign {HEX7, HEX6, HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {8{7'h22}};
endmodule

module tb_demo_top;
    reg clk = 0;
    reg [3:0] key = 4'hF;
    reg [17:0] sw = 0;
    wire [17:0] ledr;
    wire [8:0] ledg;
    wire [6:0] hex0;
    integer errors = 0;
    always #10 clk = ~clk;

    demo_top dut (.CLOCK_50(clk), .KEY(key), .SW(sw), .LEDR(ledr), .LEDG(ledg), .HEX0(hex0));

    task check(input c, input [8*40-1:0] what);
        if (!c) begin errors = errors + 1; $display("FAIL %0s: ledr %h ledg %h hex0 %h", what, ledr, ledg, hex0); end
    endtask

    initial begin
        sw = 18'h20023; @(posedge clk); #1;                      // SW9 down: Design 2
        check(ledg[4:0] == 2 && hex0 == 7'h22, "design 2 shown");
        check(ledr == 18'h20023, "design 2 sees the switches");
        key = 4'h6; #1;
        check(ledg[8:5] == 4'h6, "design 2 sees the keys");
        check(dut.u_design1.KEY == 4'hF, "design 1 sees no keys");

        key = 4'hF; sw = 18'h20223; @(posedge clk); #1;         // SW9 up: Design 1
        check(ledr[3:0] == 1 && ledg == 9'h0A1 && hex0 == 7'h11, "design 1 shown");
        sw = 18'h3C201; key = 4'h7; @(posedge clk); @(posedge clk); #1;   // KEY3 and SW changed in Design 1
        check(ledr[7:4] == 4'h7, "design 1 sees the keys");
        check(dut.u_design2.KEY == 4'hF, "design 2: no keys, no reset");
        check(dut.u_design2.SW == 18'h20023, "design 2 switches frozen");

        key = 4'hF; sw = 18'h00003; @(posedge clk); @(posedge clk); #1;   // back to Design 2
        check(ledr == 18'h00003 && hex0 == 7'h22, "design 2 again, new switches");
        if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
        $finish;
    end
endmodule
