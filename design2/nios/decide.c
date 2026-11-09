/* decide.c - identification rule (README section 6.4), integer version.
 *
 * Person k1 is accepted when d[k1] < tau[k1] and the second best person is at
 * least MARGIN_M further away. Otherwise the answer is "not enrolled".
 * tau = mean + a * standard deviation of the distances between the person's own
 * enrolled signatures.
 * Check: nios/test_host.c.
 */
#include "core.h"

static uint32_t isqrt(uint32_t v)
{
    uint32_t r = 0, bit = 1u << 30;
    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; }
        else r >>= 1;
        bit >>= 2;
    }
    return r;
}

uint32_t enroll_threshold(const uint32_t *pairwise, int n)
{
    uint32_t sum = 0, mean, var = 0;
    int i;
    for (i = 0; i < n; i++) sum += pairwise[i];
    mean = sum / n;
    for (i = 0; i < n; i++) {
        /* distances are about 2^20 at most: scale down so the square fits 32 bits */
        int32_t e = ((int32_t)pairwise[i] - (int32_t)mean) >> 4;
        var += (uint32_t)(e * e) / n;
    }
    return mean + ((isqrt(var) << 4) * TAU_A_Q8 >> 8);
}

int decide(const uint32_t *d, const person *people, int n_people)
{
    int k, k1 = -1, k2 = -1;
    for (k = 0; k < n_people; k++) {
        if (people[k].count != ENROLL_COUNT) continue;
        if (k1 < 0 || d[k] < d[k1]) { k2 = k1; k1 = k; }
        else if (k2 < 0 || d[k] < d[k2]) k2 = k;
    }
    if (k1 < 0 || d[k1] >= people[k1].tau) return -1;
    if (k2 >= 0 && d[k2] - d[k1] < MARGIN_M) return -1;
    return k1;
}
