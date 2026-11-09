// i2c_master.v - single-transaction I2C master (open drain, 7-bit address).
//
// One transaction, started by a one-clock `start` pulse:
//   START, addr+W, n_tx bytes, [repeated START, addr+R, n_rx bytes], STOP
// With n_tx = 0 and n_rx = 0 it is an address probe: START, addr+W, STOP.
// Bytes are sent from tx_data, most significant byte first. The last byte
// read gets a NACK, every other byte an ACK (I2C rule). Received bytes come
// out one at a time on rx_byte with a one-clock rx_valid pulse.
//
// Principle: one SCL period is split into 4 quarter steps of CLK_HZ/(4*SCL_HZ)
// clocks. SDA changes only while SCL is low (steps 0), and is sampled while SCL
// is high (step 2). START and STOP are the only SDA changes while SCL is high.
// The pins are open drain: *_oe = 1 pulls the line low, 0 releases it and the
// pull-up resistor raises it. If SCL stays low after release (slow rise or
// clock stretching), the step counter waits, up to STUCK_LIMIT clocks. After that
// the transaction is abandoned and reported as a NACK, so a shorted line cannot
// stop the rest of the system.
//
// Check: hdl/tb/tb_mlx_reader.v runs this against a behavioural MLX90393.
module i2c_master #(
    parameter CLK_HZ = 50000000,
    parameter SCL_HZ = 350000,
    parameter STUCK_LIMIT = 50000     // 1 ms at 50 MHz
)(
    input             clk,
    input             reset,
    input             start,
    input      [6:0]  addr,
    input      [31:0] tx_data,     // up to 4 bytes, MSB first
    input      [2:0]  n_tx,
    input      [3:0]  n_rx,
    output reg        busy,
    output reg        nack,        // some byte we sent was not acknowledged
    output reg  [7:0] rx_byte,
    output reg        rx_valid,
    output reg        sda_oe,
    output reg        scl_oe,
    input             sda_in,
    input             scl_in
);
    localparam QUARTER = CLK_HZ / (4 * SCL_HZ);

    localparam S_IDLE = 0, S_START = 1, S_BYTE = 2, S_RSTART = 3, S_STOP = 4;

    reg [2:0]  state;
    reg [15:0] div;
    reg [1:0]  step;     // quarter step inside the current bit
    reg [3:0]  bit_cnt;  // 8..1 = data bits, 0 = ack bit
    reg [7:0]  shift;
    reg        reading;  // current byte is a read
    reg [2:0]  tx_left;
    reg [3:0]  rx_left;
    reg [31:0] tx_reg;
    reg        addr_phase_r; // current byte is the addr+R byte
    reg [16:0] stuck;

    wire tick = (div == 0);
    // SCL is released in steps 1 and 2. Do not advance until it is really high.
    wire stretched = scl_oe == 1'b0 && scl_in == 1'b0;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        if (reset) begin
            state <= S_IDLE; busy <= 1'b0; nack <= 1'b0;
            sda_oe <= 1'b0; scl_oe <= 1'b0; div <= 0; step <= 0;
            bit_cnt <= 0; reading <= 1'b0; addr_phase_r <= 1'b0; stuck <= 0;
        end else if (state == S_IDLE) begin
            busy <= 1'b0;
            sda_oe <= 1'b0; scl_oe <= 1'b0;
            if (start) begin
                busy <= 1'b1; nack <= 1'b0;
                tx_reg <= tx_data; tx_left <= n_tx; rx_left <= n_rx;
                state <= S_START; div <= QUARTER - 1; step <= 0; stuck <= 0;
            end
        end else if (!tick) begin
            div <= div - 1'b1;
        end else if (stretched) begin
            stuck <= stuck + 1'b1;
            if (stuck == STUCK_LIMIT) begin nack <= 1'b1; state <= S_IDLE; end
        end else begin
            stuck <= 0;
            div <= QUARTER - 1;
            step <= step + 1'b1;
            case (state)
            S_START, S_RSTART: begin
                // step 0: SDA released. 1: SCL rises. 2: SDA falls. 3: SCL falls.
                // For a repeated START, SCL stays low through step 0 so its low time meets 1.3 us.
                case (step)
                0: sda_oe <= 1'b0;
                1: scl_oe <= 1'b0;
                2: sda_oe <= 1'b1;
                3: begin
                    scl_oe <= 1'b1;
                    state <= S_BYTE; bit_cnt <= 4'd8; reading <= 1'b0;
                    shift <= {addr, (state == S_RSTART)};
                    addr_phase_r <= (state == S_RSTART);
                end
                endcase
            end
            S_BYTE: begin
                case (step)
                0: begin // SCL low: put data on SDA
                    scl_oe <= 1'b1;
                    if (bit_cnt != 0)
                        sda_oe <= reading ? 1'b0 : ~shift[7];
                    else
                        sda_oe <= reading ? (rx_left != 1) : 1'b0; // our ACK/NACK or release
                end
                1: scl_oe <= 1'b0;
                2: begin // SCL high: sample
                    if (bit_cnt != 0) begin
                        if (reading) shift <= {shift[6:0], sda_in};
                    end else if (!reading && sda_in) begin
                        nack <= 1'b1;
                    end
                end
                3: begin
                    scl_oe <= 1'b1;
                    if (bit_cnt != 0) begin
                        if (!reading) shift <= {shift[6:0], 1'b0};
                        bit_cnt <= bit_cnt - 1'b1;
                    end else begin
                        // byte finished: decide what comes next
                        bit_cnt <= 4'd8;
                        if (reading) begin
                            rx_byte <= shift; rx_valid <= 1'b1;
                            rx_left <= rx_left - 1'b1;
                            if (rx_left == 1) state <= S_STOP;
                        end else if (nack) begin
                            state <= S_STOP;
                        end else if (addr_phase_r) begin
                            addr_phase_r <= 1'b0;
                            reading <= 1'b1;
                            if (rx_left == 0) state <= S_STOP;
                        end else if (tx_left != 0) begin
                            shift <= tx_reg[31:24];
                            tx_reg <= {tx_reg[23:0], 8'h00};
                            tx_left <= tx_left - 1'b1;
                        end else if (rx_left != 0) begin
                            state <= S_RSTART;
                        end else begin
                            state <= S_STOP;
                        end
                    end
                end
                endcase
            end
            S_STOP: begin
                // step 0: SCL low, SDA low. 1: SCL rises. 2: SDA rises. 3: done (bus free).
                case (step)
                0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end
                1: scl_oe <= 1'b0;
                2: sda_oe <= 1'b0;
                3: state <= S_IDLE;
                endcase
            end
            endcase
        end
    end
endmodule
