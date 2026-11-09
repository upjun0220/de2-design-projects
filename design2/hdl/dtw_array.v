// dtw_array.v - systolic DTW array: one PE per diagonal offset d = i - j.
//
// Principle. The DP cell (i,j) only needs cells on the two previous anti-diagonals
// (k = i+j-1 and i+j-2), so all cells with the same k can be computed in parallel.
//   (i-1, j)   has d-1 and k-1: value in the lower neighbour PE
//   (i, j-1)   has d+1 and k-1: value in the upper neighbour PE
//   (i-1, j-1) has d   and k-2: value this PE already holds
// The query x moves one PE per clock towards lower d, the template y towards higher
// d. Samples enter every second clock, so x[i] and y[j] meet exactly in the PE with
// d = i-j at time k = i+j, and each PE works every second clock.
// That free clock is used as a pipeline stage: L1 distance on the meeting clock,
// min + add on the next one. Neighbours finish their (k-1) cell on our L1 clock,
// so their values are ready when we add.
//
// Timing: x[0] and y[0] enter the two ends together, 16 clocks before k = 0, so
// the last cell (127,127) reaches the centre PE after 16 + 254 clocks.
// One comparison takes about 275 clocks and uses no multipliers.
//
// Inputs:  clear (sets D to BIG, centre PE to 0), x_in/x_v, y_in/y_v.
// Output:  distance = centre PE value, valid after the last cell.
// Check:   hdl/tb/tb_dtw_accel.v compares against hw/dtw_ref.py.
module dtw_array #(
    parameter BAND = 16,
    parameter CH   = 8,
    parameter DW   = 24
)(
    input              clk,
    input              clear,
    input  [CH*8-1:0]  x_in,
    input              x_v,
    input  [CH*8-1:0]  y_in,
    input              y_v,
    output [DW-1:0]    distance
);
    localparam NPE = 2*BAND + 1;
    localparam [DW-1:0] BIG = {DW{1'b1}};

    wire [CH*8-1:0] x_bus [0:NPE];   // x_bus[p+1] drives PE p
    wire [CH*8-1:0] y_bus [0:NPE];   // y_bus[p]   drives PE p
    wire            xv_bus [0:NPE];
    wire            yv_bus [0:NPE];
    wire [DW-1:0]   d_bus [0:NPE+1]; // d_bus[p+1] is the value of PE p

    assign x_bus[NPE] = x_in;  assign xv_bus[NPE] = x_v;
    assign y_bus[0]   = y_in;  assign yv_bus[0]   = y_v;
    assign d_bus[0]     = BIG;   // nothing below the band
    assign d_bus[NPE+1] = BIG;   // nothing above the band

    genvar p;
    generate for (p = 0; p < NPE; p = p + 1) begin : pe
        dtw_pe #(.CH(CH), .DW(DW), .INIT(p == BAND ? {DW{1'b0}} : BIG)) u (
            .clk(clk), .clear(clear),
            .x_i(x_bus[p+1]), .xv_i(xv_bus[p+1]), .x_o(x_bus[p]),   .xv_o(xv_bus[p]),
            .y_i(y_bus[p]),   .yv_i(yv_bus[p]),   .y_o(y_bus[p+1]), .yv_o(yv_bus[p+1]),
            .d_lo(d_bus[p]), .d_hi(d_bus[p+2]), .d_o(d_bus[p+1])
        );
    end endgenerate

    assign distance = d_bus[BAND+1];
endmodule

// One processing element.
//   D_new = saturate(min(D_lo, D_own, D_hi) + sum over channels |x - y|)
module dtw_pe #(
    parameter CH = 8,
    parameter DW = 24,
    parameter [DW-1:0] INIT = {DW{1'b1}}
)(
    input                  clk,
    input                  clear,
    input      [CH*8-1:0]  x_i,
    input                  xv_i,
    output reg [CH*8-1:0]  x_o,
    output reg             xv_o,
    input      [CH*8-1:0]  y_i,
    input                  yv_i,
    output reg [CH*8-1:0]  y_o,
    output reg             yv_o,
    input      [DW-1:0]    d_lo,
    input      [DW-1:0]    d_hi,
    output reg [DW-1:0]    d_o
);
    localparam [DW-1:0] BIG = {DW{1'b1}};

    // L1 distance of the two samples currently held here (combinational).
    reg [10:0] sum;
    reg signed [8:0] diff;
    reg [8:0] abs_diff;      // 9-bit context: the negation must not see the wider sum
    integer c;
    always @* begin
        sum = 0;
        for (c = 0; c < CH; c = c + 1) begin
            diff = $signed(x_o[8*c +: 8]) - $signed(y_o[8*c +: 8]);
            abs_diff = diff[8] ? -diff : diff;
            sum = sum + abs_diff;
        end
    end

    reg [10:0] l1;
    reg        add_now;

    wire [DW-1:0] m1 = (d_lo < d_hi) ? d_lo : d_hi;
    wire [DW-1:0] m  = (m1 < d_o) ? m1 : d_o;

    always @(posedge clk) begin
        if (clear) begin
            xv_o <= 1'b0; yv_o <= 1'b0; add_now <= 1'b0; d_o <= INIT;
        end else begin
            x_o <= x_i; xv_o <= xv_i;
            y_o <= y_i; yv_o <= yv_i;
            l1 <= sum;
            add_now <= xv_o & yv_o;
            if (add_now) d_o <= (m == BIG) ? BIG : m + l1;
        end
    end
endmodule
