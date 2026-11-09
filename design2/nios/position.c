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

/* Rotates each sensor's X,Y into board axes and applies the magnet polarity. */
void mount_correct(int32_t lsb[12])
{
    static const int rot[4] = MOUNT_ROT;
    int k, q;
    for (k = 0; k < 4; k++) {
        int32_t *v = &lsb[3 * k];
        for (q = 0; q < rot[k]; q++) {
            int32_t x = v[0];
            v[0] = -v[1];
            v[1] = x;
        }
        v[0] *= FIELD_SIGN;
        v[1] *= FIELD_SIGN;
        v[2] *= FIELD_SIGN;
    }
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
