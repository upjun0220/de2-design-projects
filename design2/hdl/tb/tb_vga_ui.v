// tb_vga_ui.v - vga_ui against a model written here from the rules of the mockup.
// Fills every text cell with random characters and colours, draws lines, places the
// cursor, then captures one whole frame from the pins and compares all 307,200 pixels.
// Also checks the line drawer against a software Bresenham, the clear, the line and
// frame periods, and that pixel data is stable when vga_clk rises. Prints "PASS".
`timescale 1ns/1ps
module tb_vga_ui;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg  [12:0] address = 0;
    reg         wr = 0, rd = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire vclk, hs, vs, blank_n;
    wire [9:0] r, g, b;
    vga_ui dut (.clk(clk), .reset(reset), .avs_address(address), .avs_read(rd), .avs_write(wr),
                .avs_writedata(wdata), .avs_readdata(rdata), .vga_clk(vclk), .vga_hs(hs), .vga_vs(vs),
                .vga_blank_n(blank_n), .vga_r(r), .vga_g(g), .vga_b(b));

    integer errors = 0;
    reg        want [0:192*192-1];     // expected bitmap
    reg [15:0] cells [0:2399];         // expected text cells
    reg [11:0] got [0:640*480-1];      // pixels seen on the pins
    integer cur_on = 0, cur_x = 0, cur_y = 0;
    reg [3:0] cur_color = 0, ink = 6;

    task wr_reg(input [12:0] a, input [31:0] v);
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
            x = x0; y = y0;
            dx = x1 > x0 ? x1 - x0 : x0 - x1;
            dy = y1 > y0 ? y0 - y1 : y1 - y0;
            sx = x1 >= x0 ? 1 : -1;
            sy = y1 >= y0 ? 1 : -1;
            e = dx + dy;
            forever begin
                want[y*192 + x] = 1;
                if (x == x1 && y == y1) break;
                e2 = 2*e;
                if (e2 >= dy && e2 <= dx) begin e = e + dy + dx; x = x + sx; y = y + sy; end
                else if (e2 >= dy) begin e = e + dy; x = x + sx; end
                else begin e = e + dx; y = y + sy; end
            end
        end
    endtask
    task compare_bitmap(input [255:0] name);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < 192*192; i = i + 1) if (dut.bm[i] !== want[i]) bad = bad + 1;
            if (bad != 0) begin errors = errors + 1; $display("FAIL %0s: %0d bitmap pixels differ", name, bad); end
        end
    endtask

    // ---- capture: count visible pixels and lines from the pins only ----
    integer cx = 0, cy = 0;
    always @(posedge vclk) if (blank_n) begin
        if (cx < 640 && cy < 480) got[cy*640 + cx] = {r[9:6], g[9:6], b[9:6]};
        cx = cx + 1;
    end
    // Sync position relative to the picture: front porch 16 pixels, then 10 lines.
    time t_blank = 0;
    always @(negedge blank_n) t_blank = $time;
    always @(negedge hs) begin
        if (cx != 0 && cx != 640) begin errors = errors + 1; if (errors < 5) $display("FAIL line has %0d visible pixels", cx); end
        if (cx != 0 && $time - t_blank != 16*40) begin errors = errors + 1; if (errors < 5) $display("FAIL hsync %0d ns after the picture", $time - t_blank); end
        if (cx != 0) cy = cy + 1;
        cx = 0;
    end
    always @(negedge vs) begin
        if (cy != 0 && cy != 480) begin errors = errors + 1; $display("FAIL frame has %0d visible lines", cy); end
        if (cy != 0 && $time - t_blank != (160 + 10*800)*40) begin errors = errors + 1; $display("FAIL vsync %0d ns after the picture", $time - t_blank); end
        cy = 0;
    end

    // ---- model of one pixel ----
    function arm(input integer d);
        arm = (d >= -8 && d <= -2) || (d >= 3 && d <= 9);
    endfunction
    function [11:0] model(input integer px, input integer py);
        reg [15:0] c;
        reg [7:0] fr;
        integer dx, dy;
        reg glyph, bit_on, cur;
        begin
            c = cells[(py/16)*80 + px/8];
            fr = dut.u_font.rom[{c[6:0], py[3:0]}];
            glyph = fr[7 - (px % 8)];
            bit_on = px >= 8 && px < 392 && py >= 32 && py < 416 && want[((py - 32)/2)*192 + (px - 8)/2];
            dx = px - (8 + 2*cur_x);
            dy = py - (32 + 2*cur_y);
            cur = cur_on != 0 && ((arm(dx) && (dy == 0 || dy == 1)) || (arm(dy) && (dx == 0 || dx == 1)));
            model = dut.palette(cur ? cur_color : glyph ? c[11:8] : bit_on ? ink : c[15:12]);
        end
    endfunction
    task compare_frame(input [255:0] name);
        integer px, py, bad;
        begin
            @(negedge vs); @(negedge vs);      // one complete frame with nothing changing
            bad = 0;
            for (py = 0; py < 480; py = py + 1)
                for (px = 0; px < 640; px = px + 1)
                    if (got[py*640 + px] !== model(px, py)) begin
                        if (bad < 3) $display("FAIL %0s: pixel (%0d,%0d) got %h want %h", name, px, py, got[py*640 + px], model(px, py));
                        bad = bad + 1;
                    end
            if (bad != 0) begin errors = errors + 1; $display("FAIL %0s: %0d pixels differ", name, bad); end
        end
    endtask
    task set_cursor(input integer on, input integer x, input integer y, input [3:0] col);
        begin
            cur_on = on; cur_x = x; cur_y = y; cur_color = col;
            wr_reg(3, (on << 31) | (col << 24) | (y << 16) | x);
        end
    endtask

    // ---- pin timing ----
    time t_data = 0;
    always @(r or g or b or blank_n or hs or vs) t_data = $time;
    always @(posedge vclk) if ($time - t_data < 15) begin
        errors = errors + 1;
        if (errors < 5) $display("FAIL data changed %0d ns before vga_clk rises", $time - t_data);
    end

    time t0, t1;
    integer i, seed = 7;
    initial begin
        for (i = 0; i < 192*192; i = i + 1) want[i] = 0;
        repeat (5) @(negedge clk);
        reset = 0;

        wr_reg(0, 1); wait_idle;
        compare_bitmap("clear");

        // every cell: random character (all 128 glyphs appear) and colours
        for (i = 0; i < 2400; i = i + 1) begin
            cells[i] = $random(seed);
            cells[i][7] = 1'b0;
            wr_reg(13'h1000 + i, cells[i]);
        end
        line(0, 0, 191, 191);      // corner to corner
        line(191, 0, 0, 191);      // falling x
        line(10, 150, 180, 155);   // shallow
        line(100, 10, 103, 180);   // steep
        line(50, 50, 50, 50);      // one pixel
        line(0, 96, 191, 96);      // horizontal, edge to edge
        line(96, 191, 96, 0);      // vertical, upwards
        compare_bitmap("lines");
        ink = 12; wr_reg(4, 12);
        set_cursor(1, 96, 96, 8);  // on top of crossing lines
        compare_frame("frame 1");

        set_cursor(1, 0, 191, 10); // at the corner: arms reach outside the bitmap window
        compare_frame("frame 2");

        wr_reg(0, 1); wait_idle;   // clear keeps the text and the cursor
        for (i = 0; i < 192*192; i = i + 1) want[i] = 0;
        set_cursor(0, 30, 30, 8);
        compare_frame("frame 3");

        @(negedge hs); t0 = $time; @(negedge hs); t1 = $time;
        if (t1 - t0 != 800*40) begin errors = errors + 1; $display("FAIL line period %0t", t1 - t0); end
        @(negedge vs); t0 = $time; @(negedge vs); t1 = $time;
        if (t1 - t0 != 800*525*40) begin errors = errors + 1; $display("FAIL frame period %0t", t1 - t0); end

        if (errors == 0) $display("PASS"); else $display("FAILED errors=%0d", errors);
        $finish;
    end

    initial begin #900000000; $display("FAILED timeout (errors so far %0d)", errors); $finish; end
endmodule
