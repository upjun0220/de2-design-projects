// mlx_reader.v - reads NUM_SENSORS MLX90393 sensors in single-measurement mode
// and exposes the latest frame on an Avalon-MM slave. Runs without the CPU.
//
// Sequence (MLX90393 datasheet rev 012, sections 15.1 and 15.4):
//   init : for each sensor EX (0x80), RT (0xF0) + wait, WR reg 0, WR reg 2
//   frame: every 1/FRAME_HZ s
//          for each sensor SM (0x3E = XYZ, no temperature), read status
//          wait CONV_US for the conversion
//          for each sensor RM (0x4E), read status + X,Y,Z (big endian)
//          copy the shadow registers to the output registers in one clock
//
// The CPU can read two frames apart: read FRAME, read the 12 values, read FRAME
// again; if it changed, read again. 4 sensors take about 1.3 ms of bus time
// at 400 kHz, so most of the 20 ms frame is idle.
//
// Avalon registers (word offset, 32-bit, read latency 1):
//   0 FRAME    frame counter (read), write anything: restart init sequence
//   1 ERR      bit k: sensor k failed in the last frame (NACK or status ERROR)
//   2 TIME_US  microsecond counter value latched at the end of the frame
//   3 PROBE    write {bit31=1, addr[6:0], bus in [9:8]}: pause the frame loop
//              and probe one address. Read: bit31 busy, bit0 acked.
//   4..7 CFG[k]  {bus[9:8], addr[6:0]} of sensor k. Write then restart.
//   8 REG0, 9 REG2  values written to MLX90393 registers 0 and 2 at init
//   10 NOW_US  free-running microsecond counter, used to time software
//   16..27 SAMPLE  X,Y,Z of sensor 0, X,Y,Z of sensor 1, ... sign extended
//
// Using one bus per sensor is just a CFG change: four sensors may then keep the
// same I2C address, and no A0/A1 wiring is needed. Only the selected bus is
// driven; there is one I2C master, so this does not make reading parallel.
//
// Check: hdl/tb/tb_mlx_reader.v.
module mlx_reader #(
    parameter CLK_HZ   = 50000000,
    parameter SCL_HZ   = 400000,
    parameter FRAME_HZ = 50,
    parameter CONV_US  = 9000,   // TCONV 7.6 ms (OSR=1, DIG_FILT=4) plus trim and drift margin
    parameter RESET_US = 2000,   // datasheet: wait 1.5 ms after RT
    parameter NUM_BUS  = 4,
    // Default addresses: 0x18..0x1B on bus 0 (Adafruit 4022 with A0/A1 wired)
    parameter [7*4-1:0] DEF_ADDR = {7'h1B, 7'h1A, 7'h19, 7'h18}
)(
    input                    clk,
    input                    reset,
    // Avalon-MM slave
    input      [4:0]         avs_address,
    input                    avs_read,
    input                    avs_write,
    input      [31:0]        avs_writedata,
    output reg [31:0]        avs_readdata,
    // I2C buses (open drain: oe = 1 pulls low)
    output     [NUM_BUS-1:0] sda_oe,
    output     [NUM_BUS-1:0] scl_oe,
    input      [NUM_BUS-1:0] sda_in,
    input      [NUM_BUS-1:0] scl_in
);
    localparam NUM_SENSORS = 4;
    localparam US_DIV = CLK_HZ / 1000000;
    localparam FRAME_US = 1000000 / FRAME_HZ;

    localparam CMD_SM = 8'h3E, CMD_RM = 8'h4E, CMD_EX = 8'h80, CMD_RT = 8'hF0, CMD_WR = 8'h60;

    localparam ST_RESTART = 0, ST_INIT = 1, ST_INIT_WAIT = 2, ST_FRAME_WAIT = 3, ST_SM = 4,
               ST_CONV = 5, ST_RM = 6, ST_DONE = 7, ST_PROBE = 8, ST_GO = 9;

    // ---- registers visible to the CPU ----
    reg [31:0] frame, time_us;
    reg [NUM_SENSORS-1:0] err, err_shadow;
    reg [9:0]  cfg [0:NUM_SENSORS-1];
    reg [15:0] reg0, reg2;
    reg signed [15:0] sample [0:NUM_SENSORS*3-1];
    reg [15:0] shadow [0:NUM_SENSORS*3-1];

    // ---- microsecond time base ----
    reg [7:0]  us_div;
    reg [31:0] now_us;
    wire us_tick = (us_div == US_DIV - 1);
    always @(posedge clk)
        if (reset) begin us_div <= 0; now_us <= 0; end
        else if (us_tick) begin us_div <= 0; now_us <= now_us + 1'b1; end
        else us_div <= us_div + 1'b1;

    // ---- I2C master and bus selection ----
    reg         i2c_start;
    reg  [6:0]  i2c_addr;
    reg  [31:0] i2c_tx;
    reg  [2:0]  i2c_ntx;
    reg  [3:0]  i2c_nrx;
    wire        i2c_busy, i2c_nack, i2c_rxv, m_sda_oe, m_scl_oe;
    wire [7:0]  i2c_rx;
    reg  [1:0]  bus;

    // The pins are asynchronous to clk: two flip-flops before anything uses them.
    reg [1:0] sda_ff, scl_ff;
    always @(posedge clk) begin
        sda_ff <= {sda_ff[0], sda_in[bus]};
        scl_ff <= {scl_ff[0], scl_in[bus]};
    end
    wire sda_sync = sda_ff[1];
    wire scl_sync = scl_ff[1];

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_i2c (
        .clk(clk), .reset(reset), .start(i2c_start), .addr(i2c_addr), .tx_data(i2c_tx),
        .n_tx(i2c_ntx), .n_rx(i2c_nrx), .busy(i2c_busy), .nack(i2c_nack), .rx_byte(i2c_rx),
        .rx_valid(i2c_rxv), .sda_oe(m_sda_oe), .scl_oe(m_scl_oe),
        .sda_in(sda_sync), .scl_in(scl_sync)
    );
    genvar g;
    generate for (g = 0; g < NUM_BUS; g = g + 1) begin : gbus
        assign sda_oe[g] = (bus == g) & m_sda_oe;
        assign scl_oe[g] = (bus == g) & m_scl_oe;
    end endgenerate

    // ---- sequencer ----
    reg [3:0]  state, after;      // `after`: state to enter when the transaction ends
    reg [1:0]  s;                 // sensor index
    reg [2:0]  init_step;
    reg [31:0] wait_until, next_frame;
    reg [3:0]  rx_idx;
    reg [7:0]  hi_byte;
    reg        probe_req, probe_busy, probe_ack;
    reg [9:0]  probe_cfg;
    reg        restart_req;
    integer k;

    wire [1:0] s_next = s + 1'b1;
    wire last_sensor = (s == NUM_SENSORS - 1);

    // Which sample a received byte belongs to: byte 0 = status, then X,Y,Z pairs.
    wire [3:0] pair = (rx_idx - 1'b1) >> 1;
    wire [3:0] samp_idx = s * 3 + pair;

    task begin_xact(input [9:0] c, input [31:0] tx, input [2:0] ntx, input [3:0] nrx, input [3:0] nxt);
        begin
            bus <= c[9:8]; i2c_addr <= c[6:0]; i2c_tx <= tx; i2c_ntx <= ntx; i2c_nrx <= nrx;
            i2c_start <= 1'b1; rx_idx <= 0; after <= nxt; state <= ST_GO;
        end
    endtask

    always @(posedge clk) begin
        i2c_start <= 1'b0;
        if (reset) begin
            state <= ST_RESTART; s <= 0; bus <= 0; frame <= 0; time_us <= 0; err <= 0; err_shadow <= 0;
            reg0 <= 16'h005C;  // GAIN_SEL=5, HALLCONF=0xC: 0.250/0.403 uT per LSB, about +-8 mT
            reg2 <= 16'h0011;  // OSR=1, DIG_FILT=4, RES=0, 2's complement
            for (k = 0; k < NUM_SENSORS; k = k + 1) cfg[k] <= {3'b000, DEF_ADDR[7*k +: 7]};
            probe_req <= 1'b0; probe_busy <= 1'b0; probe_ack <= 1'b0; restart_req <= 1'b0;
            next_frame <= 0; init_step <= 0; wait_until <= 0; rx_idx <= 0; after <= 0;
        end else begin
            // ---- CPU writes ----
            if (avs_write) begin
                if (avs_address == 0) restart_req <= 1'b1;
                if (avs_address == 3 && avs_writedata[31]) begin
                    probe_req <= 1'b1; probe_busy <= 1'b1; probe_ack <= 1'b0;
                    probe_cfg <= avs_writedata[9:0];
                end
                if (avs_address >= 4 && avs_address <= 7) cfg[avs_address[1:0]] <= avs_writedata[9:0];
                if (avs_address == 8) reg0 <= avs_writedata[15:0];
                if (avs_address == 9) reg2 <= avs_writedata[15:0];
            end
            // ---- received bytes ----
            if (i2c_rxv) begin
                rx_idx <= rx_idx + 1'b1;
                if (rx_idx == 0) begin
                    if (i2c_rx[4]) err_shadow[s] <= 1'b1;  // status ERROR bit
                end else if (rx_idx[0]) hi_byte <= i2c_rx;
                else shadow[samp_idx] <= {hi_byte, i2c_rx};
            end
            // ---- sequencer ----
            case (state)
            ST_RESTART: begin
                restart_req <= 1'b0; s <= 0; init_step <= 0; state <= ST_INIT;
            end
            ST_GO: state <= after;   // gives the master one clock to raise busy
            ST_INIT: if (!i2c_busy) begin
                // A sensor that does not answer must not stop the others, so errors are
                // only reported through the frame ERR register.
                case (init_step)
                0: begin_xact(cfg[s], {CMD_EX, 24'h0}, 1, 1, ST_INIT);
                1: begin_xact(cfg[s], {CMD_RT, 24'h0}, 1, 1, ST_INIT);
                2: begin wait_until <= now_us + RESET_US; state <= ST_INIT_WAIT; end
                3: begin_xact(cfg[s], {CMD_WR, reg0, 6'd0, 2'b00}, 4, 1, ST_INIT);
                4: begin_xact(cfg[s], {CMD_WR, reg2, 6'd2, 2'b00}, 4, 1, ST_INIT);
                default: begin
                    if (last_sensor) begin
                        s <= 0; next_frame <= now_us; state <= ST_FRAME_WAIT;
                    end else begin
                        s <= s_next;
                    end
                    init_step <= 0;
                end
                endcase
                if (init_step != 2 && init_step < 5) init_step <= init_step + 1'b1;
            end
            ST_INIT_WAIT: if ((now_us - wait_until) < 32'h80000000) begin
                init_step <= 3; state <= ST_INIT;
            end
            ST_FRAME_WAIT: begin
                if (restart_req) state <= ST_RESTART;
                else if (probe_req) begin
                    probe_req <= 1'b0;
                    begin_xact(probe_cfg, 32'h0, 0, 0, ST_PROBE);
                end else if ((now_us - next_frame) < 32'h80000000) begin
                    next_frame <= next_frame + FRAME_US;
                    s <= 0; err_shadow <= 0;
                    begin_xact(cfg[0], {CMD_SM, 24'h0}, 1, 1, ST_SM);
                end
            end
            ST_PROBE: if (!i2c_busy) begin
                probe_busy <= 1'b0; probe_ack <= !i2c_nack; state <= ST_FRAME_WAIT;
            end
            ST_SM: if (!i2c_busy) begin
                if (i2c_nack) err_shadow[s] <= 1'b1;
                if (last_sensor) begin
                    s <= 0; wait_until <= now_us + CONV_US; state <= ST_CONV;
                end else begin
                    s <= s_next;
                    begin_xact(cfg[s_next], {CMD_SM, 24'h0}, 1, 1, ST_SM);
                end
            end
            ST_CONV: if ((now_us - wait_until) < 32'h80000000)
                begin_xact(cfg[0], {CMD_RM, 24'h0}, 1, 7, ST_RM);
            ST_RM: if (!i2c_busy) begin
                if (i2c_nack) err_shadow[s] <= 1'b1;
                if (last_sensor) state <= ST_DONE;
                else begin
                    s <= s_next;
                    begin_xact(cfg[s_next], {CMD_RM, 24'h0}, 1, 7, ST_RM);
                end
            end
            ST_DONE: begin
                for (k = 0; k < NUM_SENSORS*3; k = k + 1) sample[k] <= shadow[k];
                err <= err_shadow; time_us <= now_us; frame <= frame + 1'b1;
                s <= 0; state <= ST_FRAME_WAIT;
            end
            endcase
        end
    end

    // ---- CPU reads (latency 1) ----
    always @(posedge clk) begin
        avs_readdata <= 32'h0;
        if (avs_address[4]) begin
            avs_readdata <= {{16{sample[avs_address[3:0]][15]}}, sample[avs_address[3:0]]};
        end else case (avs_address[3:0])
            0: avs_readdata <= frame;
            1: avs_readdata <= err;
            2: avs_readdata <= time_us;
            3: avs_readdata <= {probe_busy, 30'h0, probe_ack};
            4, 5, 6, 7: avs_readdata <= cfg[avs_address[1:0]];
            8: avs_readdata <= reg0;
            9: avs_readdata <= reg2;
            10: avs_readdata <= now_us;
            default: ;
        endcase
    end
endmodule
