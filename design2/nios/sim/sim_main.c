/* sim_main.c - firmware for the full-system ModelSim test (quartus/sim_system.sh).
 * The real Nios II core runs this from the SDRAM model. It reports through the
 * LED and HEX PIOs, which the testbench prints: HEX = value, LED = code.
 *
 * It checks what the unit tests cannot: the CPU reaching the reader and the
 * accelerator over the Avalon fabric, and how long the C code really takes.
 * Times come from the reader's microsecond counter. Simulated, not measured
 * on a board; SDRAM is a model with no refresh penalty from the real chip. */
#include "system.h"
#include "io.h"
#include "core.h"
#include "sim_vec.h"

typedef const int8_t (*csig)[SIG_CH];

#define NOW() IORD(MLX_READER_0_BASE, 10)

static void report(uint32_t code, uint32_t value)
{
    IOWR(PIO_HEX_BASE, 0, value);
    IOWR(PIO_LED_BASE, 0, code);
}

static sig_buf s;
static int8_t out[SIG_N][SIG_CH];

int main(void)
{
    int32_t lsb[12], in[12];
    pen_pos p;
    uint32_t t0, t1, d, f;
    int i, k, ok;

    report(1, 0);

    /* ---- sensor reader through Avalon ---- */
    while (IORD(MLX_READER_0_BASE, 0) < 2) ;
    f = IORD(MLX_READER_0_BASE, 0);
    for (k = 0; k < 12; k++) lsb[k] = (int32_t)IORD(MLX_READER_0_BASE, 16 + k);
    ok = 1;
    for (k = 0; k < 4; k++) {
        ok &= (lsb[3*k + 1] == lsb[3*k] + 1) && (lsb[3*k + 2] == lsb[3*k] + 2);
        ok &= ((lsb[3*k] >> 12) & 0xF) == (uint32_t)(k + 1);
    }
    report(2, ok);
    report(3, IORD(MLX_READER_0_BASE, 1));

    /* ---- MLP ---- */
    for (i = 0; i < 2; i++) {        /* second run: caches warm */
        t0 = NOW();
        for (k = 0; k < 12; k++) lsb[k] = vec_lsb[k];
        mount_correct(lsb);
        field_to_input(lsb, in);
        mlp_forward(in, &p);
        t1 = NOW();
        report(4, t1 - t0);
    }
    report(5, p.x == vec_pos[0] && p.y == vec_pos[1] && p.z == vec_pos[2] && p.ux == vec_pos[3] && p.uy == vec_pos[4]);

    /* ---- software DTW ---- */
    for (i = 0; i < 2; i++) {
        t0 = NOW();
        d = dtw_sw(vec_x, vec_y);
        t1 = NOW();
        report(6, t1 - t0);
    }
    report(7, d == vec_expected);

    /* ---- hardware DTW ---- */
    for (i = 0; i < SIG_N; i++) {
        const uint32_t *wx = (const void *)vec_x[i], *wy = (const void *)vec_y[i];
        IOWR(DTW_ACCEL_0_BASE, 0x1000 + 2*i, wx[0]);
        IOWR(DTW_ACCEL_0_BASE, 0x1000 + 2*i + 1, wx[1]);
        IOWR(DTW_ACCEL_0_BASE, 0x2000 + 2*i, wy[0]);
        IOWR(DTW_ACCEL_0_BASE, 0x2000 + 2*i + 1, wy[1]);
    }
    IOWR(DTW_ACCEL_0_BASE, 2, 1);
    t0 = NOW();
    IOWR(DTW_ACCEL_0_BASE, 0, 1);
    while (IORD(DTW_ACCEL_0_BASE, 1) & 1) ;
    t1 = NOW();
    report(8, t1 - t0);
    report(9, IORD(DTW_ACCEL_0_BASE, 5));
    report(10, IORD(DTW_ACCEL_0_BASE, 0x40) == vec_expected);

    /* ---- signature preprocessing ---- */
    sig_reset(&s);
    for (i = 0; i < 150; i++) {
        p.x = (int16_t)(i * 7); p.y = (int16_t)((i * i) % 400); p.z = 90;
        p.ux = (int16_t)i; p.uy = (int16_t)(-i);
        sig_feed(&s, &p, 0);
    }
    t0 = NOW();
    sig_preprocess(&s, out);
    t1 = NOW();
    report(11, t1 - t0);

    report(99, 1);
    while (1) ;
    return 0;
}
