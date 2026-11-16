// vga_ui.v - the monitor screen: a text layer, a small bitmap for the pen trace, and
// a pen cursor. 640x480 at 60 Hz. Avalon-MM slave. Layout: docs/vga-ui-mockup.html.
//
// Why three layers: a full-colour 640x480 picture needs far more memory than the FPGA
// has left. Text needs 16 bits per 8x16 cell, so the whole screen is 2,400 words. Only
// the signing pad needs single pixels, and one bit each is enough there.
//
//   Text    80x30 cells. Each cell: character (7 bits), text colour and background
//           colour (4 bits each, 16-colour palette). The font ROM gives the 8 pixels of
//           one row of a character. Bars are drawn with "partly filled" characters.
//   Bitmap  192x192 pixels, 1 bit, shown at twice the size (384x384) with its corner at
//           screen pixel (8, 32). A Bresenham line drawer writes it: one pixel per
//           clock, additions and comparisons only, no multipliers.
//   Cursor  a cross at one bitmap coordinate. It is compared with the beam position,
//           so it needs no memory and moving it never damages the trace.
// Priority per pixel: cursor, character pixel, bitmap pixel, cell background.
//
// Timing: pixel clock 25 MHz (clk/2), 800 clocks per line, 525 lines per frame. The
// text RAM and the font ROM each take one clk, so a pixel leaves two pixel clocks
// after its position is counted; sync and blank are delayed by the same amount.
//
// Avalon registers (word offset, read latency 1):
//   0 CTRL    write 1: clear the bitmap (36,864 clocks). Read: bit0 busy.
//   1 FROM    write {y[23:16], x[7:0]}: line start, bitmap coordinates 0..191
//   2 TO      write {y[23:16], x[7:0]}: draw a line FROM -> TO; then FROM = TO
//   3 CURSOR  write {on[31], colour[27:24], y[23:16], x[7:0]}
//   4 INK     write the palette index of bitmap pixels (default 6, white)
//   4096 + row*80 + col   write {background[15:12], colour[11:8], character[7:0]}
// Wait for busy = 0 before writing CTRL or TO.
//
// Check: hdl/tb/tb_vga_ui.v compares every pixel of a frame with a model.
module vga_ui (
    input             clk,          // 50 MHz
    input             reset,
    input      [12:0] avs_address,
    input             avs_read,
    input             avs_write,
    input      [31:0] avs_writedata,
    output reg [31:0] avs_readdata,
    output            vga_clk,
    output reg        vga_hs,
    output reg        vga_vs,
    output reg        vga_blank_n,
    output     [9:0]  vga_r,
    output     [9:0]  vga_g,
    output     [9:0]  vga_b
);
    localparam BM = 192;                 // bitmap is BM x BM
    localparam BM_X0 = 8, BM_Y0 = 32;    // its top left corner on the screen

    // ---- beam position ----
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_TOTAL = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_TOTAL = 525;
    reg        pix_en;       // 25 MHz enable
    reg        clk25;
    reg [9:0]  hc, vc;

    // ---- text layer ----
    reg [15:0] text [0:2399];
    reg [15:0] tcell;
    // row*80 + col = row*64 + row*16 + col
    wire [11:0] cell_addr = {vc[8:4], 6'b0} + {vc[8:4], 4'b0} + hc[9:3];
    wire text_we = avs_write && avs_address[12];
    always @(posedge clk) begin
        if (text_we) text[avs_address[11:0]] <= avs_writedata[15:0];
        tcell <= text[cell_addr];
    end
    wire [7:0] font_row;
    font8x16 u_font (.clk(clk), .addr({tcell[6:0], vc[3:0]}), .q(font_row));

    // ---- bitmap ----
    reg         bm [0:BM*BM-1];
    wire [15:0] wr_addr;
    wire        wr_en, wr_bit;
    reg         bm_q;
    wire [9:0]  bx = hc - BM_X0;
    wire [9:0]  by = vc - BM_Y0;
    // y*192 + x = y*128 + y*64 + x
    wire [15:0] rd_addr = {by[8:1], 7'b0} + {by[8:1], 6'b0} + bx[8:1];
    always @(posedge clk) begin
        if (wr_en) bm[wr_addr] <= wr_bit;
        bm_q <= bm[rd_addr];
    end

    // ---- line drawer ----
    localparam IDLE = 0, LINE = 1, CLEAR = 2;
    reg [1:0]  state;
    reg signed [9:0] x, y, x1, y1, dx, dy, err;
    reg signed [1:0] sx, sy;
    reg [7:0]  from_x, from_y;
    reg [15:0] clr_addr;
    reg        cur_on;
    reg [3:0]  cur_color, ink;
    reg [7:0]  cur_x, cur_y;

    wire [15:0] pix_addr = {y[7:0], 7'b0} + {y[7:0], 6'b0} + x[7:0];
    wire in_range = x >= 0 && x < BM && y >= 0 && y < BM;
    wire signed [10:0] e2 = {err, 1'b0};

    assign wr_en   = (state == CLEAR) || (state == LINE && in_range);
    assign wr_addr = (state == CLEAR) ? clr_addr : pix_addr;
    assign wr_bit  = (state == LINE);

    wire [7:0] to_x = avs_writedata[7:0];
    wire [7:0] to_y = avs_writedata[23:16];
    wire signed [9:0] tx = {2'b00, to_x};
    wire signed [9:0] ty = {2'b00, to_y};
    wire signed [9:0] fx = {2'b00, from_x};
    wire signed [9:0] fy = {2'b00, from_y};
    wire signed [9:0] ddx = tx >= fx ? tx - fx : fx - tx;
    wire signed [9:0] ddy = ty >= fy ? ty - fy : fy - ty;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE; from_x <= 0; from_y <= 0; clr_addr <= 0;
            cur_on <= 1'b0; cur_color <= 4'd8; cur_x <= 0; cur_y <= 0; ink <= 4'd6;
        end else begin
            if (avs_write && !avs_address[12]) case (avs_address[2:0])
                0: if (state == IDLE && avs_writedata[0]) begin state <= CLEAR; clr_addr <= 0; end
                1: begin from_x <= to_x; from_y <= to_y; end
                2: if (state == IDLE) begin
                    x <= fx; y <= fy; x1 <= tx; y1 <= ty;
                    dx <= ddx; dy <= -ddy;
                    sx <= tx >= fx ? 2'sd1 : -2'sd1;
                    sy <= ty >= fy ? 2'sd1 : -2'sd1;
                    err <= ddx - ddy;
                    state <= LINE;
                    from_x <= to_x; from_y <= to_y;
                end
                3: begin
                    cur_on <= avs_writedata[31]; cur_color <= avs_writedata[27:24];
                    cur_x <= to_x; cur_y <= to_y;
                end
                4: ink <= avs_writedata[3:0];
                default: ;
            endcase
            case (state)
            LINE: begin
                if (x == x1 && y == y1) state <= IDLE;
                else begin
                    // Bresenham: move in x, in y, or both, whichever keeps the error small.
                    if (e2 >= dy && e2 <= dx) begin err <= err + dy + dx; x <= x + sx; y <= y + sy; end
                    else if (e2 >= dy)        begin err <= err + dy;      x <= x + sx; end
                    else                      begin err <= err + dx;      y <= y + sy; end
                end
            end
            CLEAR: begin
                clr_addr <= clr_addr + 1'b1;
                if (clr_addr == BM*BM - 1) state <= IDLE;
            end
            default: ;
            endcase
        end
    end

    always @(posedge clk) avs_readdata <= {31'b0, state != IDLE};

    // ---- cursor: a cross, arms 7 pixels long, 2 wide, with a gap in the middle ----
    wire signed [10:0] cdx = $signed({1'b0, hc}) - $signed({2'b0, cur_x, 1'b0}) - BM_X0;
    wire signed [10:0] cdy = $signed({1'b0, vc}) - $signed({2'b0, cur_y, 1'b0}) - BM_Y0;
    wire arm_x = (cdx >= -8 && cdx <= -2) || (cdx >= 3 && cdx <= 9);
    wire arm_y = (cdy >= -8 && cdy <= -2) || (cdy >= 3 && cdy <= 9);
    wire on_cursor = cur_on && ((arm_x && (cdy == 0 || cdy == 1)) || (arm_y && (cdx == 0 || cdx == 1)));

    wire visible   = hc < H_VIS && vc < V_VIS;
    wire in_bitmap = hc >= BM_X0 && hc < BM_X0 + 2*BM && vc >= BM_Y0 && vc < BM_Y0 + 2*BM;

    // ---- palette: index -> 4 bits each of red, green, blue ----
    function [11:0] palette(input [3:0] i);
        case (i)
            4'd0:  palette = 12'h000;   // black
            4'd1:  palette = 12'h112;   // screen background
            4'd2:  palette = 12'h123;   // panel
            4'd3:  palette = 12'h345;   // frame lines
            4'd4:  palette = 12'h679;   // dim text
            4'd5:  palette = 12'hCDE;   // text
            4'd6:  palette = 12'hFFF;   // white
            4'd7:  palette = 12'h5CF;   // cyan
            4'd8:  palette = 12'h4D8;   // green
            4'd9:  palette = 12'h143;   // dark green
            4'd10: palette = 12'hF66;   // red
            4'd11: palette = 12'h511;   // dark red
            4'd12: palette = 12'hFC5;   // amber
            4'd13: palette = 12'h48F;   // blue
            4'd14: palette = 12'h235;   // title bar
            default: palette = 12'h224; // bar track
        endcase
    endfunction

    // ---- pixel pipeline. Stage 1 lines up with the font ROM output. ----
    reg [2:0] px1;                    // which of the 8 pixels of the font row
    reg [7:0] attr1;
    reg       bm1, cur1, vis1, hs1, vs1;
    wire      glyph_on = font_row[3'd7 - px1];
    wire [3:0] index = cur1 ? cur_color : glyph_on ? attr1[3:0] : bm1 ? ink : attr1[7:4];
    reg [11:0] rgb;

    assign vga_clk = clk25;
    always @(posedge clk) begin
        if (reset) begin
            pix_en <= 1'b0; clk25 <= 1'b0; hc <= 0; vc <= 0;
            vga_hs <= 1'b1; vga_vs <= 1'b1; vga_blank_n <= 1'b0; rgb <= 0;
            px1 <= 0; attr1 <= 0; bm1 <= 0; cur1 <= 0; vis1 <= 0; hs1 <= 1'b1; vs1 <= 1'b1;
        end else begin
            pix_en <= ~pix_en;
            // Outputs change on the clock where pix_en = 1. vga_clk falls there and rises
            // 20 ns later, so the DAC latches in the middle of a stable pixel.
            clk25 <= ~pix_en;
            if (pix_en) begin
                if (hc == H_TOTAL - 1) begin
                    hc <= 0;
                    vc <= (vc == V_TOTAL - 1) ? 10'd0 : vc + 1'b1;
                end else hc <= hc + 1'b1;
                // stage 1: the RAMs were read with this hc one clk ago; the font ROM answers now
                px1 <= hc[2:0]; attr1 <= tcell[15:8];
                bm1 <= bm_q && in_bitmap; cur1 <= on_cursor; vis1 <= visible;
                hs1 <= !(hc >= H_VIS + H_FP && hc < H_VIS + H_FP + H_SYNC);
                vs1 <= !(vc >= V_VIS + V_FP && vc < V_VIS + V_FP + V_SYNC);
                // stage 2: output registers
                vga_hs <= hs1; vga_vs <= vs1; vga_blank_n <= vis1;
                rgb <= vis1 ? palette(index) : 12'h000;
            end
        end
    end
    // 4 bits to the 10 bits of the DAC: repeat the bits so that F becomes full scale
    assign vga_r = {rgb[11:8], rgb[11:8], rgb[11:10]};
    assign vga_g = {rgb[7:4],  rgb[7:4],  rgb[7:6]};
    assign vga_b = {rgb[3:0],  rgb[3:0],  rgb[3:2]};
endmodule
