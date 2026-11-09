/* dtw.c - software DTW, bit-exact with hdl/dtw_accel.v and hw/dtw_ref.py.
 *
 * D[i][j] = L1(x[i], y[j]) + min(D[i-1][j], D[i][j-1], D[i-1][j-1]), |i-j| <= 16.
 * Only the previous row is needed, stored by offset d = j - i + 16:
 *   D[i-1][j]   is prev[d + 1]
 *   D[i-1][j-1] is prev[d]
 *   D[i][j-1]   is cur[d - 1]
 */
#include "core.h"

#define BAND 16

static uint32_t local_l1(const int8_t *a, const int8_t *b)
{
    uint32_t sum = 0;
    int c;
    for (c = 0; c < SIG_CH; c++) {
        int d = (int)a[c] - (int)b[c];
        sum += d < 0 ? -d : d;
    }
    return sum;
}

uint32_t dtw_sw(const int8_t x[SIG_N][SIG_CH], const int8_t y[SIG_N][SIG_CH])
{
    uint32_t a[2*BAND + 3], b[2*BAND + 3];
    uint32_t *prev = a, *cur = b, *tmp;
    int i, j, d;

    for (d = 0; d < 2*BAND + 3; d++) prev[d] = DTW_BIG;
    for (i = 0; i < SIG_N; i++) {
        for (d = 0; d < 2*BAND + 3; d++) cur[d] = DTW_BIG;
        for (j = i - BAND; j <= i + BAND; j++) {
            uint32_t m;
            if (j < 0 || j >= SIG_N) continue;
            d = j - i + BAND + 1;                /* index 0 and last stay BIG */
            if (i == 0 && j == 0) {
                m = 0;
            } else {
                m = prev[d + 1];
                if (prev[d] < m) m = prev[d];
                if (cur[d - 1] < m) m = cur[d - 1];
            }
            cur[d] = m == DTW_BIG ? DTW_BIG : m + local_l1(x[i], y[j]);
        }
        tmp = prev; prev = cur; cur = tmp;
    }
    return prev[BAND + 1];
}
