/* position.c - sensor values to pen position with a small integer neural network.
 *
 * Why these steps:
 *  - The field falls with the cube of the distance, so raw values span a range
 *    of thousands. A cube root compresses that range for the network.
 *  - Z axis LSBs are bigger than X/Y LSBs (0.403 vs 0.250 uT), so Z is rescaled.
 *  - Network: 12 inputs, two ReLU hidden layers, 5 outputs. Weights are Q10,
 *    hidden values Q6, outputs Q12. pc/train_mlp.py checks 32-bit sums cannot
 *    overflow on its test data, and writes the weights to mlp_weights.h.
 * Check: nios/test_host.c compares with pc/pen_model.py bit by bit.
 */
#include "core.h"
#include "mlp_weights.h"

/* Integer cube root (floor), one result bit per loop, no division. */
uint32_t icbrt(uint32_t v)
{
    uint32_t r = 0;
    int s;
    for (s = 30; s >= 0; s -= 3) {
        uint32_t b;
        r *= 2;
        b = 3 * r * (r + 1) + 1;
        if ((v >> s) >= b) {
            v -= b << s;
            r++;
        }
    }
    return r;
}

/* Mirrors (MIRROR_XY: swap X and Y), then rotates each sensor's X,Y into board axes,
 * then applies the magnet polarity. Same order as pc/pen_model.py mount_correct. */
void mount_correct(int32_t lsb[12])
{
    static const int rot[4] = MOUNT_ROT;
    int k, q;
    for (k = 0; k < 4; k++) {
        int32_t *v = &lsb[3 * k];
        if (MIRROR_XY) {
            int32_t x = v[0];
            v[0] = v[1];
            v[1] = x;
        }
        for (q = 0; q < rot[k]; q++) {
            int32_t x = v[0];
            v[0] = -v[1];
            v[1] = x;
        }
        v[0] *= FIELD_SIGN;
        v[1] *= FIELD_SIGN;
        v[2] *= FIELD_SIGN * Z_SIGN;
    }
}

/* 1 when the four sensors see nearly the same vector (see UNIFORM_PCT in config.h).
 * Compares each value with the average of the four; 4*(v - mean) avoids a division. */
int field_is_uniform(const int32_t lsb[12])
{
    int32_t v[12], num = 0, den = 0;
    int k, c;
    for (k = 0; k < 12; k++) v[k] = k % 3 == 2 ? lsb[k] * 1612 / 1000 : lsb[k];
    for (c = 0; c < 3; c++) {
        int32_t total = v[c] + v[3 + c] + v[6 + c] + v[9 + c];
        for (k = 0; k < 4; k++) {
            int32_t d = 4 * v[3*k + c] - total, a = v[3*k + c];
            num += d < 0 ? -d : d;
            den += a < 0 ? -a : a;
        }
    }
    /* num is at most about 5e6 for any 16-bit sensor values, so num * 100 fits in 32 bits */
    return num * 100 < 4 * den * UNIFORM_PCT;
}

void field_to_input(const int32_t lsb[12], int32_t in[12])
{
    int k;
    for (k = 0; k < 12; k++) {
        int32_t v = lsb[k];
        uint32_t a, c;
        if (k % 3 == 2) v = v * 1612 / 1000;   /* 0.403/0.250 */
        a = v < 0 ? (uint32_t)(-v) : (uint32_t)v;
        if (a > (1u << 20)) a = 1u << 20;
        c = icbrt(a << 8);
        in[k] = v < 0 ? -(int32_t)c : (int32_t)c;
    }
}

static int32_t clamp_hidden(int32_t v)
{
    if (v < 0) return 0;
    return v > 4095 ? 4095 : v;
}

void mlp_forward(const int32_t in[12], pen_pos *out)
{
    int32_t h1[MLP_H1], h2[MLP_H2], o[MLP_OUT];
    int i, j;
    for (i = 0; i < MLP_H1; i++) {
        int32_t s = mlp_b0[i];
        for (j = 0; j < MLP_IN; j++) s += (int32_t)mlp_w0[i][j] * in[j];
        h1[i] = clamp_hidden(s >> 10);
    }
    for (i = 0; i < MLP_H2; i++) {
        int32_t s = mlp_b1[i];
        for (j = 0; j < MLP_H1; j++) s += (int32_t)mlp_w1[i][j] * h1[j];
        h2[i] = clamp_hidden(s >> 10);
    }
    for (i = 0; i < MLP_OUT; i++) {
        int32_t s = mlp_b2[i];
        for (j = 0; j < MLP_H2; j++) s += (int32_t)mlp_w2[i][j] * h2[j];
        o[i] = s >> 4;
    }
    out->x  = (int16_t)((o[0] * 500) >> 12);
    out->y  = (int16_t)((o[1] * 500) >> 12);
    out->z  = (int16_t)((o[2] * 500) >> 12);
    out->ux = (int16_t)(o[3] >> 4);
    out->uy = (int16_t)(o[4] >> 4);
}

/* ---- Position filter (config.h PF_*, pc/pen_filter.py is the reference) ----
 * Per axis: median of the last 3 inputs removes single-frame spikes (costs one frame of lag),
 * then a One Euro filter: a first-order low-pass x += alpha * (in - x) whose cut-off
 * frequency fc rises with the filtered speed, so a still pen is smoothed hard and a fast
 * stroke lags little. alpha = w / (1 + w), w = 2 pi fc Te, Te = 0.02 s.
 * Units: position Q4 (1/16 of 0.1 mm), alpha Q12, frequency in 0.01 Hz. */
static int32_t alpha_q12(int32_t fc_chz)
{
    int32_t w = fc_chz * 5147 / 1000;          /* 2 pi * 0.02 * 4096 = 514.7 per Hz */
    return (w << 12) / (4096 + w);
}

static int32_t median3(int32_t a, int32_t b, int32_t c)
{
    int32_t lo = a < b ? a : b, hi = a < b ? b : a;
    if (c < lo) return lo;
    return c > hi ? hi : c;
}

void pf_reset(pen_filter *f)
{
    f->valid = 0;
}

void pf_step(pen_filter *f, pen_pos *p)
{
    int16_t *axis[3];
    int k;
    axis[0] = &p->x; axis[1] = &p->y; axis[2] = &p->z;
    for (k = 0; k < 3; k++) {
        int32_t v = *axis[k];
        if (v > PF_CLAMP) v = PF_CLAMP;
        if (v < -PF_CLAMP) v = -PF_CLAMP;
        if (!f->valid) {                       /* first frame: start from the input as it is */
            f->m0[k] = f->m1[k] = v;
            f->x[k] = v << 4;
            f->dx[k] = 0;
            *axis[k] = (int16_t)v;
        } else {
            int32_t med = median3(f->m0[k], f->m1[k], v), xq, speed, fc;
            f->m0[k] = f->m1[k];
            f->m1[k] = v;
            xq = med << 4;
            f->dx[k] += (alpha_q12(PF_DCUT) * (xq - f->x[k] - f->dx[k])) >> 12;
            speed = (f->dx[k] < 0 ? -f->dx[k] : f->dx[k]) * 5 / 16;   /* Q4 0.1 mm/frame -> mm/s */
            fc = PF_MINCUT + PF_BETA * speed;
            if (fc > 5000) fc = 5000;
            f->x[k] += (alpha_q12(fc) * (xq - f->x[k])) >> 12;
            *axis[k] = (int16_t)(f->x[k] >> 4);
        }
    }
    f->valid = 1;
}
