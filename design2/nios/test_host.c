/* test_host.c - runs the board-independent C code on the PC and compares it
 * bit by bit with the Python reference (golden file from pc/gen_golden.py).
 * Usage: test_host golden.txt. Prints "C core OK" and returns 0 on success. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core.h"

static FILE *g;
static int fails = 0;

static long rd(void)
{
    long v;
    if (fscanf(g, "%ld", &v) != 1) { printf("golden file ended early\n"); exit(2); }
    return v;
}

static void check(const char *name, long got, long want)
{
    if (got != want && fails++ < 10) printf("FAIL %s got %ld want %ld\n", name, got, want);
}
#define CHECK(name, got, want) check(name, (long)(got), (long)(want))

static void test_icbrt(void)
{
    long n = rd(), i;
    for (i = 0; i < n; i++) {
        uint32_t v = (uint32_t)rd();
        long want = rd();
        CHECK("icbrt", icbrt(v), want);
    }
}

static void test_mlp(void)
{
    long n = rd(), i;
    int k;
    for (i = 0; i < n; i++) {
        int32_t lsb[12], in[12];
        pen_pos p;
        for (k = 0; k < 12; k++) lsb[k] = (int32_t)rd();
        field_to_input(lsb, in);
        for (k = 0; k < 12; k++) CHECK("input", in[k], rd());
        mlp_forward(in, &p);
        CHECK("x", p.x, rd()); CHECK("y", p.y, rd()); CHECK("z", p.z, rd());
        CHECK("ux", p.ux, rd()); CHECK("uy", p.uy, rd());
    }
}

static sig_buf s;

static void test_signature(void)
{
    long ncase = rd(), c;
    static int8_t out[SIG_N][SIG_CH];
    for (c = 0; c < ncase; c++) {
        long nf = rd(), i;
        static long stream[1000][6];
        long nsig, j;
        int done = 0, a, b;
        for (i = 0; i < nf; i++)
            for (a = 0; a < 6; a++) stream[i][a] = rd();
        nsig = rd();
        sig_reset(&s);
        for (i = 0; i < nf; i++) {
            pen_pos p;
            int ev;
            p.x = (int16_t)stream[i][0]; p.y = (int16_t)stream[i][1]; p.z = (int16_t)stream[i][2];
            p.ux = (int16_t)stream[i][3]; p.uy = (int16_t)stream[i][4];
            ev = sig_feed(&s, &p, (int)stream[i][5]);
            if (ev == SIG_DONE) {
                long n;
                done++;
                if (done > nsig) { CHECK("extra signature", done, nsig); continue; }
                n = rd();
                CHECK("frames", s.n, n);
                sig_preprocess(&s, out);
                for (a = 0; a < SIG_N; a++)
                    for (b = 0; b < SIG_CH; b++) CHECK("preprocess", out[a][b], rd());
            }
        }
        CHECK("signatures", done, nsig);
        for (j = done; j < nsig; j++) { /* keep the file position sane after a failure */
            rd();
            for (a = 0; a < SIG_N * SIG_CH; a++) rd();
        }
    }
}

static void test_dtw(void)
{
    long n = rd(), i;
    static int8_t x[SIG_N][SIG_CH], y[SIG_N][SIG_CH];
    int a, b;
    for (i = 0; i < n; i++) {
        for (a = 0; a < SIG_N; a++) for (b = 0; b < SIG_CH; b++) x[a][b] = (int8_t)rd();
        for (a = 0; a < SIG_N; a++) for (b = 0; b < SIG_CH; b++) y[a][b] = (int8_t)rd();
        CHECK("dtw", dtw_sw((const int8_t (*)[SIG_CH])x, (const int8_t (*)[SIG_CH])y), rd());
    }
}

static void test_decide(void)
{
    person p[3];
    uint32_t d[3];
    uint32_t same[4] = { 1000, 1000, 1000, 1000 }, spread[4] = { 900, 1100, 900, 1100 };
    memset(p, 0, sizeof(p));

    CHECK("no spread: tau = mean", enroll_threshold(same, 4), 1000);
    CHECK("tau = mean + 2*sigma", enroll_threshold(spread, 4), 1192);  /* isqrt scaled by 16 */

    d[0] = 1000; d[1] = 5000; d[2] = 9000;
    CHECK("nobody enrolled", decide(d, p, 3), -1);
    p[0].count = ENROLL_COUNT; p[0].tau = 2000;
    p[1].count = ENROLL_COUNT; p[1].tau = 2000;
    CHECK("clear match", decide(d, p, 3), 0);
    CHECK("partly enrolled ignored", (p[2].count = 2, decide(d, p, 3)), 0);
    d[0] = 3000;
    CHECK("over threshold", decide(d, p, 3), -1);
    d[0] = 1000; d[1] = 1000 + MARGIN_M - 1;
    CHECK("second too close", decide(d, p, 3), -1);
    d[0] = 1000 + MARGIN_M; d[1] = 1000;
    CHECK("best is person 1", decide(d, p, 3), 1);
}

static void test_screen(void)
{
    pen_pos p = { 0, 0, 0, 0, 0 };
    int x, y;
    screen_xy(&p, &x, &y);
    CHECK("centre x", x, 160); CHECK("centre y", y, 120);
    p.x = 4 * 100; p.y = 4 * 50;     /* right and up on the board */
    screen_xy(&p, &x, &y);
    CHECK("right", x, 260); CHECK("up is smaller y", y, 70);
    p.x = 30000; p.y = -30000;
    screen_xy(&p, &x, &y);
    CHECK("clamp x", x, 319); CHECK("clamp y", y, 239);
}

/* Compiled twice by run_checks.sh; the second time with -DTEST_MOUNT (see config.h) */
static void test_mount(void)
{
#ifdef TEST_MOUNT
    static const int32_t want[12] = { 2, -1, 3, 4, 5, 6, -8, 7, 9, -10, -11, 12 };
#else
    static const int32_t want[12] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
#endif
    int32_t v[12];
    int k;
    for (k = 0; k < 12; k++) v[k] = k + 1;
    mount_correct(v);
    for (k = 0; k < 12; k++) CHECK("mount", v[k], want[k]);
}

int main(int argc, char **argv)
{
    test_mount();
#ifdef TEST_MOUNT
    if (fails) { printf("FAILED mount\n"); return 1; }
    printf("mount OK\n");
    return 0;
#endif
    g = argc > 1 ? fopen(argv[1], "r") : NULL;
    if (!g) { printf("cannot open golden file\n"); return 2; }
    test_icbrt();
    test_mlp();
    test_signature();
    test_dtw();
    test_decide();
    test_screen();
    if (fails) { printf("FAILED %d checks\n", fails); return 1; }
    printf("C core OK\n");
    return 0;
}
