// dtw_accel.v - DTW accelerator with an Avalon-MM slave: compares one query
// signature against N_TEMPL stored templates, one after another.
//
// The CPU writes the query and templates into on-chip RAM here, writes N_TEMPL and
// starts. Each comparison feeds both signatures into dtw_array (a sample every
// second clock) and stores the distance in the result RAM.
//
// Avalon registers (32-bit words, read latency 1):
//   word 0x00 CTRL     write bit0=1: start
//   word 0x01 STATUS   bit0 busy, bit1 done
//   word 0x02 N_TEMPL  number of templates (1..MAX_TEMPL)
//   word 0x05 CYCLES   clocks taken by the last run
//   word 0x40.. RESULT[k]   distance of template k (read only)
//   word 0x1000 + n    query RAM, n = 2*sample + (0: channels 3..0, 1: channels 7..4)
//   word 0x2000 + n    template RAM, n = 256*template + 2*sample + (0 or 1)
// Channel 0 is the least significant byte, so a C array int8_t s[128][8] can be
// copied word by word. Query and template RAM are write only.
//
// Check: hdl/tb/tb_dtw_accel.v (100 test vectors from hw/dtw_ref.py).
module dtw_accel #(
    parameter N         = 128,
    parameter BAND      = 16,
    parameter CH        = 8,
    parameter DW        = 24,
    parameter MAX_TEMPL = 25
)(
    input             clk,
    input             reset,
    input      [14:0] avs_address,
    input             avs_read,
    input             avs_write,
    input      [31:0] avs_writedata,
    output     [31:0] avs_readdata
);
    // Timing of one comparison, cnt = 0 is the first RAM read:
    //   cnt 2                  x[0], y[0] are in the two end PEs
    //   cnt 2 + BAND + 2(N-1)  x[N-1], y[N-1] meet in the centre PE (L1 clock)
    //   one clock later        min + add
    //   FINISH + 1             the distance is visible at the array output
    localparam FINISH = 2*(N - 1) + BAND + 3;

    // ---- on-chip memories (one M4K set per 32-bit half) ----
    reg [31:0] q_lo [0:N-1], q_hi [0:N-1];
    reg [31:0] t_lo [0:MAX_TEMPL*N-1], t_hi [0:MAX_TEMPL*N-1];
    reg [DW-1:0] res [0:31];

    wire is_q = avs_address[14:12] == 3'b001;
    wire is_t = avs_address[14:13] == 2'b01;
    wire is_r = avs_address[14:6]  == 9'b000000001;

    reg  [6:0]  rd_sample;       // sample index being read (i = j, both fed together)
    reg  [4:0]  templ;
    wire [12:0] t_rd_addr = {templ, 7'b0} + rd_sample;

    reg [31:0] q_lo_d, q_hi_d, t_lo_d, t_hi_d;
    always @(posedge clk) begin
        if (avs_write && is_q && !avs_address[0]) q_lo[avs_address[7:1]] <= avs_writedata;
        q_lo_d <= q_lo[rd_sample];
    end
    always @(posedge clk) begin
        if (avs_write && is_q && avs_address[0]) q_hi[avs_address[7:1]] <= avs_writedata;
        q_hi_d <= q_hi[rd_sample];
    end
    always @(posedge clk) begin
        if (avs_write && is_t && !avs_address[0]) t_lo[avs_address[12:1]] <= avs_writedata;
        t_lo_d <= t_lo[t_rd_addr];
    end
    always @(posedge clk) begin
        if (avs_write && is_t && avs_address[0]) t_hi[avs_address[12:1]] <= avs_writedata;
        t_hi_d <= t_hi[t_rd_addr];
    end

    // ---- control ----
    reg        busy, done;
    reg [5:0]  n_templ;
    reg [31:0] cycles;
    reg [9:0]  cnt;              // clock inside one comparison
    reg        clear, feed_d;
    wire [DW-1:0] distance;

    wire feed = busy && !clear && !cnt[0] && (cnt < 2*N);   // even clocks: read one sample
    wire finish = busy && (cnt == FINISH);

    reg res_we;
    always @(posedge clk) begin
        if (res_we) res[templ] <= distance;
    end

    dtw_array #(.BAND(BAND), .CH(CH), .DW(DW)) u_array (
        .clk(clk), .clear(clear),
        .x_in({q_hi_d, q_lo_d}), .x_v(feed_d),
        .y_in({t_hi_d, t_lo_d}), .y_v(feed_d),
        .distance(distance)
    );

    always @(posedge clk) begin
        clear <= 1'b0; res_we <= 1'b0;
        if (reset) begin
            busy <= 1'b0; done <= 1'b0; n_templ <= 1; cycles <= 0; cnt <= 0;
            rd_sample <= 0; templ <= 0; feed_d <= 1'b0;
        end else begin
            feed_d <= feed;
            if (avs_write && avs_address == 15'h2) n_templ <= avs_writedata[5:0];
            if (avs_write && avs_address == 15'h0 && avs_writedata[0] && !busy) begin
                busy <= 1'b1; done <= 1'b0; cycles <= 0; templ <= 0;
                cnt <= 0; rd_sample <= 0; clear <= 1'b1;
            end
            if (busy) begin
                cycles <= cycles + 1'b1;
                if (!clear) begin
                    cnt <= cnt + 1'b1;
                    if (feed) rd_sample <= rd_sample + 1'b1;
                    if (finish) res_we <= 1'b1;
                    if (res_we) begin
                        cnt <= 0; rd_sample <= 0;
                        if (templ + 1'b1 == n_templ) begin busy <= 1'b0; done <= 1'b1; end
                        else begin templ <= templ + 1'b1; clear <= 1'b1; end
                    end
                end
            end
        end
    end

    // ---- CPU reads ----
    reg [31:0] csr_d;
    reg [DW-1:0] res_d;
    reg sel_res;
    always @(posedge clk) begin
        res_d <= res[avs_address[4:0]];
        sel_res <= is_r;
        case (avs_address)
            15'h1:   csr_d <= {30'h0, done, busy};
            15'h2:   csr_d <= n_templ;
            15'h5:   csr_d <= cycles;
            default: csr_d <= 32'h0;
        endcase
    end
    assign avs_readdata = sel_res ? {{(32-DW){1'b0}}, res_d} : csr_d;
endmodule
