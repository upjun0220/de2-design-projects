/* signature.c - finds one signature in the frame stream and turns it into the
 * fixed 128 x 8 int8 form used by DTW.
 *
 * Start: first frame with the pen down. End: pen up for 1 s, KEY1, or 10 s full.
 * Pen down: estimated height below Z_DOWN (sig_feed), or with the pen switch SW[17] on,
 * the height relative to the contact height z_ref (sig_feed_switch). When the switch ends
 * the signature, the lift at the end is cut off first (sig_trim_tail).
 * Discard: less than 0.5 s pen-down, or more than 20 % frames with sensor errors.
 *
 * Preprocessing (all integer, same as pc/preprocess.py):
 *  1. Resample every channel to 128 points on the time axis (linear).
 *  2. Move the centre of the pen-down points to the origin, scale so the width
 *     of the signature is 100 units. Position no longer depends on where or how
 *     large one signs.
 *  3. Height relative to the lowest pen-down point, 0.4 mm per unit.
 *  4. Speed = central difference of the scaled x, y.
 *  5. Tilt: ux, uy (Q8) scaled to +-100. ux, uy replace theta, phi from the plan
 *     because phi jumps at +-180 degrees, which DTW would see as a huge distance.
 *  6. Pen flag: 64 down, 0 up.
 * Check: nios/test_host.c against pc/preprocess.py.
 */
#include <string.h>
#include "core.h"

void sig_reset(sig_buf *s)
{
    s->n = 0;
    s->active = 0;
    s->is_down = 0;
    s->up_run = 0;
    s->down_total = 0;
    s->lost = 0;
    s->z_ref = 0;
    s->z_acc = 0;
}

/* Common end handling: cut the trailing pen-up frames, then check quality. */
static int sig_close(sig_buf *s)
{
    while (s->n > 0 && !s->pen[s->n - 1]) s->n--;
    s->active = 0;
    if (s->down_total < MIN_DOWN_FRAMES) return SIG_REJECT;
    if (s->lost * 100 > s->n * MAX_LOST_PCT) return SIG_REJECT;
    return SIG_DONE;
}

/* Store one frame with the pen state already decided (s->is_down).
 * up_ends: 1 = END_UP_FRAMES of pen-up end the signature (height mode),
 *          0 = only the switch, KEY1 or a full buffer end it (pen switch mode). */
static int sig_store(sig_buf *s, const pen_pos *p, int lost, int up_ends)
{
    if (!s->active) {
        if (!s->is_down) return SIG_NONE;
        s->active = 1;
        s->n = 0; s->up_run = 0; s->down_total = 0; s->lost = 0;
        s->z_ref = p->z;
        s->z_acc = p->z << 4;
    }
    s->p[s->n] = *p;
    s->pen[s->n] = (uint8_t)s->is_down;
    s->n++;
    if (lost) s->lost++;
    if (s->is_down) { s->down_total++; s->up_run = 0; }
    else s->up_run++;

    if ((up_ends && s->up_run >= END_UP_FRAMES) || s->n >= MAX_FRAMES) return sig_close(s);
    return s->n == 1 ? SIG_STARTED : SIG_NONE;
}

int sig_feed(sig_buf *s, const pen_pos *p, int lost)
{
    /* Hysteresis: between Z_DOWN and Z_UP the state stays what it was. */
    if (p->z < Z_DOWN) s->is_down = 1;
    else if (p->z > Z_UP) s->is_down = 0;
    return sig_store(s, p, lost, 1);
}

/* Pen switch mode (SW[17] on, nios/main.c). The switch marks the whole signature; inside it,
 * pen up/down comes from the height RELATIVE to the contact height z_ref, because the
 * absolute height estimate is offset by several mm. The first frame is always pen down and
 * sets z_ref. While the pen is down, z_ref follows the height: at once when it goes lower,
 * slowly (ZREF_SHIFT) when it goes higher, because the uncalibrated contact height differs
 * by a few mm across the pad. While the pen is up, z_ref is kept.
 * Lifting more than LIFT_UP above z_ref = pen up (no line), coming back below LIFT_DOWN =
 * pen down. LIFT_UP 0 turns this off: always pen down.
 * The switch going off ends the signature (sig_trim_tail, sig_finish in main.c). */
int sig_feed_switch(sig_buf *s, const pen_pos *p, int lost)
{
    if (!s->active) {
        s->is_down = 1;
    } else {
        /* z_acc is z_ref in Q4: without the extra bits a difference below 2^ZREF_SHIFT
         * (3.2 mm for 5) would never move z_ref */
        if (p->z < s->z_ref) { s->z_acc = p->z << 4; s->z_ref = p->z; }
        if (LIFT_UP <= 0) s->is_down = 1;
        else if (p->z > s->z_ref + LIFT_UP) s->is_down = 0;
        else if (p->z < s->z_ref + LIFT_DOWN) s->is_down = 1;
        /* follow upwards only after the decision, so the frame that lifts is judged
         * against the old contact height */
        if (s->is_down) {
            s->z_acc += ((p->z << 4) - s->z_acc) >> ZREF_SHIFT;
            s->z_ref = s->z_acc >> 4;
        }
    }
    return sig_store(s, p, lost, 0);
}

/* The signature ends with: last stroke, pen lifted, hand to the switch, switch off. The
 * movement after the lift is not part of the signature. Find it from the end:
 *  1. zs = height smoothed over +-2 frames (the whole signature is stored, so no lag).
 *  2. j = last frame with zs below z_ref + TRIM_LIFT. If the signature ends higher than that
 *     (and the high part starts within the last TRIM_WINDOW frames), the pen was lifted at
 *     the end and never came back down.
 *  3. Walk back from the first high frame while the height keeps falling: the lowest point
 *     is where the pen left the paper. Cut after it.
 * When no such lift is found nothing is cut: a tail is less harmful than a lost stroke.
 * Check: nios/test_host.c against pc/preprocess.py trim_tail. */
static int32_t z_smooth(const sig_buf *s, int i)
{
    int32_t sum = 0;
    int k, c = 0;
    for (k = i - 2; k <= i + 2; k++)
        if (k >= 0 && k < s->n) { sum += s->p[k].z; c++; }
    return sum / c;
}

void sig_trim_tail(sig_buf *s)
{
    int start = s->n > TRIM_WINDOW ? s->n - TRIM_WINDOW : 0;
    int j, k;
    if (TRIM_LIFT <= 0 || s->n < 2) return;
    for (j = s->n - 1; j >= 0; j--)
        if (z_smooth(s, j) < s->z_ref + TRIM_LIFT) break;
    if (j < 0 || j == s->n - 1 || j + 1 < start) return;   /* always high, ends low, or high too long */
    k = j + 1;
    while (k > start && z_smooth(s, k - 1) <= z_smooth(s, k)) k--;
    s->n = k + 1;
}

int sig_finish(sig_buf *s)
{
    if (!s->active) return SIG_NONE;
    return sig_close(s);
}

static int8_t clamp8(int32_t v)
{
    if (v > 127) return 127;
    if (v < -127) return -127;
    return (int8_t)v;
}

void sig_preprocess(const sig_buf *s, int8_t out[SIG_N][SIG_CH])
{
    static int32_t X[SIG_N], Y[SIG_N], Z[SIG_N], UX[SIG_N], UY[SIG_N];
    int32_t sx = 0, sy = 0, cx, cy, xmin = 32767, xmax = -32768, zmin = 32767, width;
    int i, down = 0;
    int last = s->n - 1;

    for (i = 0; i < s->n; i++) {
        if (!s->pen[i]) continue;
        sx += s->p[i].x;
        sy += s->p[i].y;
        if (s->p[i].x < xmin) xmin = s->p[i].x;
        if (s->p[i].x > xmax) xmax = s->p[i].x;
        if (s->p[i].z < zmin) zmin = s->p[i].z;
        down++;
    }
    cx = sx / down;
    cy = sy / down;
    width = xmax - xmin;
    if (width < 1) width = 1;

    for (i = 0; i < SIG_N; i++) {
        int32_t pos = i * last;
        int a = pos / (SIG_N - 1);
        int32_t f = pos % (SIG_N - 1);
        int b = a < last ? a + 1 : a;
        int32_t g = (SIG_N - 1) - f;
        X[i]  = (s->p[a].x  * g + s->p[b].x  * f) / (SIG_N - 1);
        Y[i]  = (s->p[a].y  * g + s->p[b].y  * f) / (SIG_N - 1);
        Z[i]  = (s->p[a].z  * g + s->p[b].z  * f) / (SIG_N - 1);
        UX[i] = (s->p[a].ux * g + s->p[b].ux * f) / (SIG_N - 1);
        UY[i] = (s->p[a].uy * g + s->p[b].uy * f) / (SIG_N - 1);
        out[i][0] = clamp8((X[i] - cx) * 100 / width);
        out[i][1] = clamp8((Y[i] - cy) * 100 / width);
        out[i][2] = clamp8((Z[i] - zmin) / 4);
        out[i][5] = clamp8(UX[i] * 100 / 256);
        out[i][6] = clamp8(UY[i] * 100 / 256);
        out[i][7] = s->pen[f >= 64 ? b : a] ? 64 : 0;
    }
    for (i = 0; i < SIG_N; i++) {
        int p = i > 0 ? i - 1 : i;
        int q = i < SIG_N - 1 ? i + 1 : i;
        out[i][3] = clamp8((out[q][0] - out[p][0]) * 2);
        out[i][4] = clamp8((out[q][1] - out[p][1]) * 2);
    }
    /* Second loop: the speed above needs x, y even if they are masked out. */
    for (i = 0; i < SIG_N; i++) {
        int c;
        for (c = 0; c < SIG_CH; c++)
            if (!((CHANNEL_MASK >> c) & 1)) out[i][c] = 0;
    }
}
