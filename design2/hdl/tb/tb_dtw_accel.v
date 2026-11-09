// tb_dtw_accel.v - DTW accelerator against the Python reference (hw/dtw_ref.py).
// 100 single comparisons, then one run with 25 templates. Vectors are read from
// the directory given by the plusarg/define VEC. Prints "PASS 100/100" on success.
`timescale 1ns/1ps
module tb_dtw_accel;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg  [14:0] address = 0;
    reg         wr = 0, rd = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    dtw_accel dut (.clk(clk), .reset(reset), .avs_address(address), .avs_read(rd),
                   .avs_write(wr), .avs_writedata(wdata), .avs_readdata(rdata));

    reg [63:0] xv [0:100*128-1];
    reg [63:0] yv [0:100*128-1];
    reg [23:0] exp1 [0:99];
    reg [23:0] expm [0:24];
    integer errors = 0;

    task wr_reg(input [14:0] a, input [31:0] v);
        begin
            @(negedge clk); address = a; wdata = v; wr = 1;
            @(negedge clk); wr = 0;
        end
    endtask
    task rd_reg(input [14:0] a, output [31:0] v);
        begin
            @(negedge clk); address = a; rd = 1;
            @(negedge clk); rd = 0; v = rdata;
        end
    endtask
    task load(input integer base, input [63:0] s, input integer sample);
        begin
            wr_reg(base + 2*sample,     s[31:0]);
            wr_reg(base + 2*sample + 1, s[63:32]);
        end
    endtask
    task run;
        reg [31:0] st;
        begin
            wr_reg(0, 1);
            st = 1;
            while (st[0]) rd_reg(1, st);
            if (!st[1]) begin errors = errors + 1; $display("FAIL done not set"); end
        end
    endtask

    integer good = 0, v, i;
    reg [31:0] r, cyc;
    string vec;
    initial begin
        if (!$value$plusargs("VEC=%s", vec)) vec = "../hw/vectors";
        $readmemh({vec, "/x.hex"}, xv);
        $readmemh({vec, "/y.hex"}, yv);
        $readmemh({vec, "/expected.hex"}, exp1);
        $readmemh({vec, "/expected_multi.hex"}, expm);
        repeat (5) @(negedge clk);
        reset = 0;

        wr_reg(2, 1);
        for (v = 0; v < 100; v = v + 1) begin
            for (i = 0; i < 128; i = i + 1) begin
                load(15'h1000, xv[v*128 + i], i);
                load(15'h2000, yv[v*128 + i], i);
            end
            run;
            rd_reg(15'h40, r);
            if (r === {8'h0, exp1[v]}) good = good + 1;
            else begin errors = errors + 1; $display("FAIL vector %0d got %h want %h", v, r, exp1[v]); end
        end
        rd_reg(5, cyc);
        $display("clocks per comparison: %0d", cyc);
        if (cyc > 280) begin errors = errors + 1; $display("FAIL too slow"); end

        // 25 templates in one run
        for (i = 0; i < 128; i = i + 1) load(15'h1000, xv[i], i);
        for (v = 0; v < 25; v = v + 1)
            for (i = 0; i < 128; i = i + 1) load(15'h2000 + 256*v, yv[v*128 + i], i);
        wr_reg(2, 25);
        run;
        for (v = 0; v < 25; v = v + 1) begin
            rd_reg(15'h40 + v, r);
            if (r !== {8'h0, expm[v]}) begin errors = errors + 1; $display("FAIL multi %0d got %h want %h", v, r, expm[v]); end
        end
        rd_reg(5, cyc);
        $display("clocks for 25 templates: %0d", cyc);

        if (errors == 0) $display("PASS %0d/100", good); else $display("FAILED errors=%0d", errors);
        $finish;
    end
endmodule
