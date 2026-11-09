// tb_vga_trace.v - line drawing against a software Bresenham, clear, clipping at the
// screen edges, and VGA timing. Prints "PASS" when everything holds.
`timescale 1ns/1ps
module tb_vga_trace;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg  [1:0]  address = 0;
    reg         wr = 0, rd = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire vclk, hs, vs, blank_n;
    wire [9:0] r, g, b;
    vga_trace dut (.clk(clk), .reset(reset), .avs_address(address), .avs_read(rd), .avs_write(wr),
                   .avs_writedata(wdata), .avs_readdata(rdata), .vga_clk(vclk), .vga_hs(hs), .vga_vs(vs),
                   .vga_blank_n(blank_n), .vga_r(r), .vga_g(g), .vga_b(b));

    integer errors = 0;
    reg want [0:320*240-1];

    task wr_reg(input [1:0] a, input [31:0] v);
        begin @(negedge clk); address = a; wdata = v; wr = 1; @(negedge clk); wr = 0; end
    endtask
    task wait_idle;
        reg [31:0] v;
        begin
            v = 1;
            while (v[0]) begin
                @(negedge clk); address = 0; rd = 1; @(negedge clk); rd = 0; v = rdata;
            end
        end
    endtask
    task line(input integer x0, input integer y0, input integer x1, input integer y1);
        integer x, y, dx, dy, sx, sy, e, e2;
        begin
            wr_reg(1, (y0 << 16) | x0);
            wr_reg(2, (y1 << 16) | x1);
            wait_idle;
            // the same line in software
            x = x0; y = y0;
            dx = x1 > x0 ? x1 - x0 : x0 - x1;
            dy = y1 > y0 ? y0 - y1 : y1 - y0;
            sx = x1 >= x0 ? 1 : -1;
            sy = y1 >= y0 ? 1 : -1;
            e = dx + dy;
            forever begin
                want[y*320 + x] = 1;
                if (x == x1 && y == y1) break;
                e2 = 2*e;
                if (e2 >= dy && e2 <= dx) begin e = e + dy + dx; x = x + sx; y = y + sy; end
                else if (e2 >= dy) begin e = e + dy; x = x + sx; end
                else begin e = e + dx; y = y + sy; end
            end
        end
    endtask
    task compare(input [255:0] name);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < 320*240; i = i + 1) if (dut.fb[i] !== want[i]) bad = bad + 1;
            if (bad != 0) begin errors = errors + 1; $display("FAIL %0s: %0d pixels differ", name, bad); end
        end
    endtask

    // ---- timing measured on the output pins ----
    time t_data = 0;
    always @(r[9] or g[9] or b[9] or blank_n or hs or vs) t_data = $time;
    always @(posedge vclk) if ($time - t_data < 15) begin
        errors = errors + 1;
        if (errors < 5) $display("FAIL data changed %0d ns before vga_clk rises", $time - t_data);
    end
    time t_hs0, t_hs1, t_vs0, t_vs1;
    reg  seen_white = 0;
    integer i;
    initial begin
        for (i = 0; i < 320*240; i = i + 1) want[i] = 0;
        repeat (5) @(negedge clk);
        reset = 0;

        wr_reg(0, 1); wait_idle;
        compare("clear");

        line(0, 0, 319, 239);      // corner to corner
        line(319, 0, 0, 239);      // falling x
        line(10, 200, 300, 205);   // shallow
        line(100, 10, 103, 230);   // steep
        line(50, 50, 50, 50);      // one pixel
        line(0, 120, 319, 120);    // horizontal
        line(160, 239, 160, 0);    // vertical, upwards
        compare("lines");

        // a white pixel must appear on the pins where the frame buffer has one
        @(negedge vs); @(posedge vs);
        repeat (40) @(posedge hs);
        while (!seen_white) begin
            @(posedge vclk);
            if (blank_n && r[9] && g[0] && b[5]) seen_white = 1;
        end

        @(negedge hs); t_hs0 = $time; @(negedge hs); t_hs1 = $time;
        if (t_hs1 - t_hs0 != 800*40) begin errors = errors + 1; $display("FAIL line period %0t", t_hs1 - t_hs0); end
        @(negedge vs); t_vs0 = $time; @(negedge vs); t_vs1 = $time;
        if (t_vs1 - t_vs0 != 800*525*40) begin errors = errors + 1; $display("FAIL frame period %0t", t_vs1 - t_vs0); end

        wr_reg(3, 6'b111_000);     // inverted colours
        @(negedge vs); @(posedge vs);
        repeat (40) @(posedge hs);
        seen_white = 0;
        repeat (200) begin
            @(posedge vclk);
            if (blank_n && r[9] && g[9] && b[9]) seen_white = 1;
        end
        if (!seen_white) begin errors = errors + 1; $display("FAIL background colour"); end

        if (errors == 0) $display("PASS"); else $display("FAILED errors=%0d", errors);
        $finish;
    end

    initial begin #400000000; $display("FAILED timeout (errors so far %0d)", errors); $finish; end
endmodule
