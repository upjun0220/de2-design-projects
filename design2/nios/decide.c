/* decide.c - identification rule (README section 6.4), integer version.
 *
 * Person k1 is accepted when d[k1] < tau[k1] and the second best person is at
 * least MARGIN_M further away. Otherwise the answer is "not enrolled".
 * tau = mean + a * standard deviation of each enrolled signature's distance to the
 * nearest of the person's other enrolled signatures (enroll_tau).
 * Check: nios/test_host.c.
 */
#include "core.h"

uint32_t isqrt(uint32_t v)
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

/* tau for one person from the distances among the enrolled signatures (dist[i][j], i != j).
 * A query is scored by its distance to the NEAREST template, so tau is set from the
 * same kind of number: each enrolled signature's distance to the nearest of the other
 * ones (leave one out). The mean of all pairs would be larger and let anything in. */
uint32_t enroll_tau(uint32_t dist[ENROLL_COUNT][ENROLL_COUNT])
{
    uint32_t nearest[ENROLL_COUNT];
    int i, j;
    for (i = 0; i < ENROLL_COUNT; i++) {
        nearest[i] = DTW_BIG;
        for (j = 0; j < ENROLL_COUNT; j++)
            if (j != i && dist[i][j] < nearest[i]) nearest[i] = dist[i][j];
    }
    return enroll_threshold(nearest, ENROLL_COUNT);
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
