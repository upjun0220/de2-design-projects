// vga_trace.v - shows the pen trace on a VGA monitor: 320x240 1-bit frame buffer
// shown at 640x480, with a hardware line drawer. Avalon-MM slave.
//
// Principle: the CPU only gives line end points. A Bresenham FSM writes one pixel
// per clock. Bresenham steps along the line with an error term and needs only
// additions and comparisons, so this uses no multipliers. The frame buffer has
// two ports: the drawer writes, the scan-out reads, and neither has to wait.
//
// Timing: 640x480 at 60 Hz, pixel clock 25 MHz (clk/2): 800 clocks per line, 525
// lines per frame. Each buffer pixel covers 2x2 screen pixels.
//
// Avalon registers (word offset, read latency 1):
//   0 CTRL    write 1: clear the screen (76,800 clocks). Read: bit0 busy.
//   1 FROM    write {y[23:16], x[8:0]}: start point
//   2 TO      write {y[23:16], x[8:0]}: draw a line FROM -> TO; then FROM = TO
//   3 COLOR   write {bg[5:3], fg[2:0]} as RGB bits (default white on black)
// Wait for busy = 0 before writing CTRL or TO.
//
// Check: hdl/tb/tb_vga_trace.v
module vga_trace (
    input             clk,          // 50 MHz
    input             reset,
    input      [1:0]  avs_address,
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
    localparam W = 320, H = 240;

    // ---- frame buffer: one bit per pixel ----
    reg        fb [0:W*H-1];
    wire [16:0] wr_addr;
    wire        wr_en, wr_bit;
    wire [16:0] rd_addr;
    reg         rd_bit;
    always @(posedge clk) begin
        if (wr_en) fb[wr_addr] <= wr_bit;
        rd_bit <= fb[rd_addr];
    end

    // ---- line drawer ----
    localparam IDLE = 0, LINE = 1, CLEAR = 2;
    reg [1:0]  state;
    reg signed [10:0] x, y, x1, y1, dx, dy, err;
    reg signed [1:0]  sx, sy;
    reg [8:0]  from_x;
    reg [7:0]  from_y;
    reg [5:0]  color;
    reg [16:0] clr_addr;

    // y*320 + x = (y<<8) + (y<<6) + x, no multiplier
    wire [16:0] pix_addr = {y[7:0], 8'b0} + {y[7:0], 6'b0} + x[8:0];
    wire in_range = x >= 0 && x < W && y >= 0 && y < H;
    wire signed [11:0] e2 = {err, 1'b0};

    assign wr_en   = (state == CLEAR) || (state == LINE && in_range);
    assign wr_addr = (state == CLEAR) ? clr_addr : pix_addr;
    assign wr_bit  = (state == LINE);

    wire [8:0] to_x = avs_writedata[8:0];
    wire [7:0] to_y = avs_writedata[23:16];
    wire signed [10:0] tx = {2'b00, to_x};
    wire signed [10:0] ty = {3'b000, to_y};
    wire signed [10:0] fx = {2'b00, from_x};
    wire signed [10:0] fy = {3'b000, from_y};
    wire signed [10:0] ddx = tx >= fx ? tx - fx : fx - tx;
    wire signed [10:0] ddy = ty >= fy ? ty - fy : fy - ty;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE; color <= 6'b000_111; from_x <= 0; from_y <= 0; clr_addr <= 0;
        end else begin
            if (avs_write) case (avs_address)
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
                3: color <= avs_writedata[5:0];
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
                if (clr_addr == W*H - 1) state <= IDLE;
            end
            default: ;
            endcase
        end
    end

    always @(posedge clk) avs_readdata <= {31'b0, state != IDLE};

    // ---- scan-out ----
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_TOTAL = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_TOTAL = 525;

    reg        pix_en;       // 25 MHz enable
    reg [9:0]  hc, vc;
    reg        clk25;

    wire visible = hc < H_VIS && vc < V_VIS;
    // Address of the screen pixel at (hc, vc). The RAM answers one clk later, before the next pixel.
    assign rd_addr = {vc[8:1], 8'b0} + {vc[8:1], 6'b0} + hc[9:1];

    assign vga_clk = clk25;

    reg [2:0] rgb;
    always @(posedge clk) begin
        if (reset) begin
            pix_en <= 1'b0; clk25 <= 1'b0; hc <= 0; vc <= 0;
            vga_hs <= 1'b1; vga_vs <= 1'b1; vga_blank_n <= 1'b0; rgb <= 0;
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
                // All outputs are one register after hc, vc. The RAM read happened in the clock before.
                vga_hs <= !(hc >= H_VIS + H_FP && hc < H_VIS + H_FP + H_SYNC);
                vga_vs <= !(vc >= V_VIS + V_FP && vc < V_VIS + V_FP + V_SYNC);
                vga_blank_n <= visible;
                rgb <= !visible ? 3'b000 : (rd_bit ? color[2:0] : color[5:3]);
            end
        end
    end
    assign vga_r = {10{rgb[2]}};
    assign vga_g = {10{rgb[1]}};
    assign vga_b = {10{rgb[0]}};
endmodule
