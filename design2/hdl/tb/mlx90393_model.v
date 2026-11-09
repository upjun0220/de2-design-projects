// mlx90393_model.v - behavioural MLX90393 I2C slave for simulation only.
// Implements the commands the reader uses (EX, RT, WR, SM, RM) as documented in
// datasheet rev 012 section 15.4. An RM before the conversion has finished sets
// the status ERROR bit, which lets the testbench catch a too-short wait.
// Field values are X = BASE + n, Y = BASE + n + 1, Z = BASE + n + 2 where n
// counts measurements.
`timescale 1ns/1ps
module mlx90393_model #(
    parameter [6:0] ADDR = 7'h18,
    parameter [15:0] BASE = 16'h1000,
    parameter CONV_NS = 7600000
)(
    inout  sda,
    input  scl,
    output reg [15:0] reg0,
    output reg [15:0] reg2,
    output reg        seen_rt
);
    localparam IDLE = 0, RX = 1, ACK_TX = 2, TX = 3, ACK_RX = 4;

    reg sda_low = 0;
    assign sda = sda_low ? 1'b0 : 1'bz;

    integer state = IDLE, bits = 0, nbytes = 0, idx = 0;
    reg [7:0] rxb = 0;
    reg [7:0] cmd = 0;
    reg [7:0] wbuf [0:3];
    reg [7:0] txb [0:6];
    reg [15:0] n = 0;
    reg is_read = 0, is_addr = 0, master_ack = 0;
    time conv_done = 0;
    reg [15:0] vx, vy, vz;

    initial begin reg0 = 16'hFFFF; reg2 = 16'hFFFF; seen_rt = 0; end

    // START (or repeated START): SDA falls while SCL is high. STOP: SDA rises.
    always @(negedge sda) if (scl === 1'b1) begin
        state = RX; bits = 0; is_addr = 1; sda_low = 0;
    end
    always @(posedge sda) if (scl === 1'b1) begin
        state = IDLE; sda_low = 0;
    end

    always @(posedge scl) begin
        if (state == RX) begin rxb = {rxb[6:0], sda}; bits = bits + 1; end
        else if (state == ACK_RX) master_ack = (sda === 1'b0);
    end

    task load_reply;
        begin
            txb[0] = 8'h00;
            if (cmd[7:4] == 4'h3) txb[0][5] = 1'b1;   // SM_MODE
            if (cmd[7:4] == 4'h4) begin
                if ($time < conv_done) txb[0][4] = 1'b1;  // ERROR: read too early
                txb[0][1:0] = 2'd2;                       // 6 data bytes follow
                vx = BASE + n; vy = BASE + n + 16'd1; vz = BASE + n + 16'd2;
                txb[1] = vx[15:8]; txb[2] = vx[7:0];
                txb[3] = vy[15:8]; txb[4] = vy[7:0];
                txb[5] = vz[15:8]; txb[6] = vz[7:0];
                n = n + 1;
            end
        end
    endtask

    always @(negedge scl) begin
        case (state)
        RX: if (bits == 8) begin
            bits = 0;
            if (is_addr) begin
                is_addr = 0;
                if (rxb[7:1] == ADDR) begin
                    is_read = rxb[0]; nbytes = 0; state = ACK_TX; sda_low = 1;
                end else state = IDLE;
            end else begin
                if (nbytes == 0) cmd = rxb;
                wbuf[nbytes % 4] = rxb;
                nbytes = nbytes + 1;
                if (nbytes == 1 && cmd == 8'hF0) begin seen_rt = 1; reg0 = 16'h007C; reg2 = 16'h0000; end
                if (nbytes == 1 && cmd[7:4] == 4'h3) conv_done = $time + CONV_NS;
                if (nbytes == 4 && cmd == 8'h60) begin
                    if (rxb[7:2] == 6'd0) reg0 = {wbuf[1], wbuf[2]};
                    if (rxb[7:2] == 6'd2) reg2 = {wbuf[1], wbuf[2]};
                end
                state = ACK_TX; sda_low = 1;
            end
        end
        ACK_TX: begin
            sda_low = 0; bits = 0;
            if (is_read) begin
                load_reply; idx = 0; state = TX; sda_low = !txb[0][7];
            end else state = RX;
        end
        TX: begin
            bits = bits + 1;
            if (bits == 8) begin sda_low = 0; state = ACK_RX; end
            else sda_low = !txb[idx][7 - bits];
        end
        ACK_RX: begin
            if (master_ack) begin
                idx = idx + 1; bits = 0; state = TX; sda_low = !txb[idx][7];
            end else begin
                sda_low = 0; state = IDLE;
            end
        end
        default: ;
        endcase
    end
endmodule
