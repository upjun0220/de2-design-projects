// tb_system.v - full system: real Nios II core and Qsys fabric, SDRAM model, and
// behavioural sensors on bus 0. Prints each report from nios/sim/sim_main.c.
// The reader is sped up (defparam) so simulation does not wait for real sensor time.
`timescale 1ns/1ps
module tb_system;
    reg clk = 0, reset_n = 0;
    always #10 clk = ~clk;

    wire [11:0] addr;
    wire [1:0]  ba, dqm;
    wire        cas_n, cke, cs_n, ras_n, we_n;
    wire [15:0] dq;
    wire [3:0]  sda_oe, scl_oe;
    tri1 [3:0]  sda, scl;
    wire [26:0] led;
    wire [31:0] hex;
    tri0 [7:0]  lcd_data;     // LCD model: never busy
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : gb
        assign sda[g] = sda_oe[g] ? 1'b0 : 1'bz;
        assign scl[g] = scl_oe[g] ? 1'b0 : 1'bz;
    end endgenerate

    magic_pen_sys u_sys (
        .clk_clk(clk), .reset_reset_n(reset_n),
        .sdram_wire_addr(addr), .sdram_wire_ba(ba), .sdram_wire_cas_n(cas_n), .sdram_wire_cke(cke),
        .sdram_wire_cs_n(cs_n), .sdram_wire_dq(dq), .sdram_wire_dqm(dqm), .sdram_wire_ras_n(ras_n),
        .sdram_wire_we_n(we_n),
        .lcd_RS(), .lcd_RW(), .lcd_data(lcd_data), .lcd_E(),
        .pio_in_export(22'h3FFFFF), .pio_led_export(led), .pio_hex_export(hex),
        .vga_clk(), .vga_hs(), .vga_vs(), .vga_blank_n(), .vga_r(), .vga_g(), .vga_b(),
        .i2c_sda_oe(sda_oe), .i2c_scl_oe(scl_oe), .i2c_sda_in(sda), .i2c_scl_in(scl)
    );
    defparam u_sys.mlx_reader_0.FRAME_HZ = 2000;
    defparam u_sys.mlx_reader_0.CONV_US  = 20;
    defparam u_sys.mlx_reader_0.RESET_US = 10;
    defparam u_sys.mlx_reader_0.SCL_HZ   = 2000000;

    magic_pen_sys_sdram_test_component u_sdram (
        .clk(clk), .zs_addr(addr), .zs_ba(ba), .zs_cas_n(cas_n), .zs_cke(cke), .zs_cs_n(cs_n),
        .zs_dq(dq), .zs_dqm(dqm), .zs_ras_n(ras_n), .zs_we_n(we_n)
    );

    wire [15:0] r0, r2; wire rt;
    mlx90393_model #(.ADDR(7'h18), .BASE(16'h1000), .CONV_NS(10000), .CHECK_TIMING(0)) s0 (.sda(sda[0]), .scl(scl[0]), .reg0(r0), .reg2(r2), .seen_rt(rt));
    mlx90393_model #(.ADDR(7'h19), .BASE(16'h2000), .CONV_NS(10000), .CHECK_TIMING(0)) s1 (.sda(sda[0]), .scl(scl[0]), .reg0(), .reg2(), .seen_rt());
    mlx90393_model #(.ADDR(7'h1A), .BASE(16'h3000), .CONV_NS(10000), .CHECK_TIMING(0)) s2 (.sda(sda[0]), .scl(scl[0]), .reg0(), .reg2(), .seen_rt());
    mlx90393_model #(.ADDR(7'h1B), .BASE(16'h4000), .CONV_NS(10000), .CHECK_TIMING(0)) s3 (.sda(sda[0]), .scl(scl[0]), .reg0(), .reg2(), .seen_rt());

    integer errors = 0;
    always @(led) if (reset_n && led !== 27'b0) begin
        $display("[%0d us] report %0d = %0d", $time/1000, led, hex);
        case (led)
            2, 5, 7, 10: if (hex !== 32'd1) begin errors = errors + 1; $display("FAIL: check %0d", led); end
            3: if (hex !== 32'd0) begin errors = errors + 1; $display("FAIL: sensor error flags %h", hex); end
            default: ;
        endcase
        if (led == 99) begin
            if (errors == 0) $display("SYSTEM PASS"); else $display("SYSTEM FAILED %0d", errors);
            $finish;
        end
    end

    initial begin
        #1000 reset_n = 1;
        #400000000 $display("SYSTEM FAILED timeout, last report %0d", led);
        $finish;
    end
endmodule
