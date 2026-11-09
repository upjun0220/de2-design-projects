// tb_mlx_reader.v - mlx_reader against four behavioural MLX90393 sensors.
// Checks: register init values, frame period, sample values and ordering, no
// status error (i.e. the conversion wait is long enough), a missing sensor is
// flagged while the others keep working, address probe, one-bus-per-sensor mode.
// Prints "PASS" as the last line when everything holds.
`timescale 1ns/1ps
module tb_mlx_reader;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;   // 50 MHz

    wire [3:0] sda_oe, scl_oe;
    tri1 [3:0] sda, scl;     // pull-ups
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : gb
        assign sda[g] = sda_oe[g] ? 1'b0 : 1'bz;
        assign scl[g] = scl_oe[g] ? 1'b0 : 1'bz;
    end endgenerate

    reg  [4:0]  address = 0;
    reg         rd = 0, wr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;

    mlx_reader #(.DEF_ADDR({7'h1B, 7'h1A, 7'h19, 7'h18})) dut (
        .clk(clk), .reset(reset), .avs_address(address), .avs_read(rd), .avs_write(wr),
        .avs_writedata(wdata), .avs_readdata(rdata),
        .sda_oe(sda_oe), .scl_oe(scl_oe), .sda_in(sda), .scl_in(scl));

    wire [15:0] r0a, r2a, r0b, r2b, r0c, r2c;
    wire rta, rtb, rtc;
    mlx90393_model #(.ADDR(7'h18), .BASE(16'h1000)) s0 (.sda(sda[0]), .scl(scl[0]), .reg0(r0a), .reg2(r2a), .seen_rt(rta));
    mlx90393_model #(.ADDR(7'h19), .BASE(16'hF000)) s1 (.sda(sda[0]), .scl(scl[0]), .reg0(r0b), .reg2(r2b), .seen_rt(rtb));
    mlx90393_model #(.ADDR(7'h1A), .BASE(16'h3000)) s2 (.sda(sda[0]), .scl(scl[0]), .reg0(r0c), .reg2(r2c), .seen_rt(rtc));
    // Sensor 3 (0x1B) is deliberately not on bus 0. It sits on bus 1 with address 0x18.
    wire [15:0] r0d, r2d; wire rtd;
    mlx90393_model #(.ADDR(7'h18), .BASE(16'h4000)) s3 (.sda(sda[1]), .scl(scl[1]), .reg0(r0d), .reg2(r2d), .seen_rt(rtd));

    integer errors = 0;
    reg [31:0] v;

    task rd_reg(input [4:0] a, output [31:0] val);
        begin
            @(negedge clk); address = a; rd = 1;
            @(negedge clk); rd = 0;
            val = rdata;
        end
    endtask
    task wr_reg(input [4:0] a, input [31:0] val);
        begin
            @(negedge clk); address = a; wdata = val; wr = 1;
            @(negedge clk); wr = 0;
        end
    endtask
    task check(input [255:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL %0s got %h want %h", name, got, want);
            end
        end
    endtask
    task wait_frame(output [31:0] f);
        reg [31:0] f0;
        begin
            rd_reg(0, f0); f = f0;
            while (f == f0) begin #100000; rd_reg(0, f); end
        end
    endtask

    reg [31:0] f1, t1, t2, x;
    integer i;
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;

        // ---- 1. missing sensor 3 on bus 0: others work, ERR bit 3 set ----
        wait_frame(f1);
        wait_frame(f1);
        check("reg0 s0", r0a, 16'h005C); check("reg2 s0", r2a, 16'h0011);
        check("reg0 s2", r0c, 16'h005C); check("rt s1", rtb, 1);
        rd_reg(1, v); check("err=s3 only", v, 32'h8);
        rd_reg(16, x);
        if (x[15:12] !== 4'h1) begin errors = errors + 1; $display("FAIL s0 X %h", x); end
        rd_reg(17, v); check("s0 Y = X+1", v, x + 1);
        rd_reg(18, v); check("s0 Z = X+2", v, x + 2);
        rd_reg(19, v);  // BASE 0xF000: must be sign extended
        if (v[31:16] !== 16'hFFFF) begin errors = errors + 1; $display("FAIL sign %h", v); end
        rd_reg(22, v);
        if (v[15:12] !== 4'h3) begin errors = errors + 1; $display("FAIL s2 X %h", v); end

        // ---- 2. frame period 20 ms ----
        wait_frame(f1); rd_reg(2, t1);
        wait_frame(f1); rd_reg(2, t2);
        check("frame us", t2 - t1, 20000);

        // ---- 3. probe ----
        wr_reg(3, 32'h80000000 | 7'h19);
        v = 32'h80000000;
        while (v[31]) begin #100000; rd_reg(3, v); end
        check("probe 0x19 ack", v[0], 1);
        wr_reg(3, 32'h80000000 | 7'h55);
        #1000; v = 32'h80000000;
        while (v[31]) begin #100000; rd_reg(3, v); end
        check("probe 0x55 nack", v[0], 0);

        // ---- 4. move sensor 3 to bus 1 at address 0x18, restart: no errors ----
        wr_reg(7, (1 << 8) | 7'h18);
        wr_reg(0, 0);
        #15000000;
        wait_frame(f1);
        wait_frame(f1);
        rd_reg(1, v); check("err none", v, 0);
        check("reg0 s3", r0d, 16'h005C);
        rd_reg(25, v);
        if (v[15:12] !== 4'h4) begin errors = errors + 1; $display("FAIL s3 X %h", v); end

        if (errors == 0) $display("PASS"); else $display("FAILED errors=%0d", errors);
        $finish;
    end

    initial begin #300000000; $display("FAILED timeout"); $finish; end
endmodule
