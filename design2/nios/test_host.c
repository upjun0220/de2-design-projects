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
        CHECK("uniform", field_is_uniform(lsb), rd());
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

/* pf_step against pc/pen_filter.py: reset flag, input x y z, expected x y z per row */
static void test_filter(void)
{
    long ns = rd(), c, i;
    pen_filter f;
    for (c = 0; c < ns; c++) {
        long n = rd();
        for (i = 0; i < n; i++) {
            pen_pos p;
            if (rd()) pf_reset(&f);
            p.x = (int16_t)rd(); p.y = (int16_t)rd(); p.z = (int16_t)rd(); p.ux = p.uy = 0;
            pf_step(&f, &p);
            CHECK("filter x", p.x, rd()); CHECK("filter y", p.y, rd()); CHECK("filter z", p.z, rd());
        }
    }
}

/* sig_trim_tail against pc/preprocess.py trim_tail: n, z_ref, heights, expected n */
static void test_trim(void)
{
    long nc = rd(), c, i;
    for (c = 0; c < nc; c++) {
        long n = rd();
        sig_reset(&s);
        s.z_ref = (int)rd();
        for (i = 0; i < n; i++) { memset(&s.p[i], 0, sizeof(s.p[i])); s.p[i].z = (int16_t)rd(); s.pen[i] = 1; }
        s.n = (int)n;
        sig_trim_tail(&s);
        CHECK("trim", s.n, rd());
    }
}

/* z_ref in pen switch mode: follows a rising contact height slowly, a lower one at once,
 * and is kept while the pen is up. */
static void test_zref(void)
{
    pen_pos p;
    int i;
    memset(&p, 0, sizeof(p));
    sig_reset(&s);
    p.z = 100; sig_feed_switch(&s, &p, 0);
    CHECK("zref start", s.z_ref, 100);
    for (i = 0; i < 200; i++) { p.z = 130; sig_feed_switch(&s, &p, 0); }   /* 3 mm higher, still down */
    CHECK("zref follows up", s.z_ref > 120 && s.z_ref <= 130, 1);
    CHECK("still down", s.is_down, 1);
    p.z = 90; sig_feed_switch(&s, &p, 0);
    CHECK("zref down at once", s.z_ref, 90);
    p.z = 90 + LIFT_UP + 1; sig_feed_switch(&s, &p, 0);
    CHECK("lift = up", s.is_down, 0);
    for (i = 0; i < 50; i++) sig_feed_switch(&s, &p, 0);
    CHECK("zref kept while up", s.z_ref, 90);
    p.z = 90 + LIFT_DOWN - 1; sig_feed_switch(&s, &p, 0);
    CHECK("back down", s.is_down, 1);
}

static void test_decide(void)
{
    person p[3];
    uint32_t d[3];
    uint32_t same[4] = { 1000, 1000, 1000, 1000 }, spread[4] = { 900, 1100, 900, 1100 };
    memset(p, 0, sizeof(p));

    CHECK("no spread: tau = mean", enroll_threshold(same, 4), 1000);
    CHECK("tau = mean + 2*sigma", enroll_threshold(spread, 4), 1192);  /* isqrt scaled by 16 */
    {   /* nearest other signature: 1000, 1000, 1000, 1000, 3000 -> mean 1400, sigma 800 */
        uint32_t m[ENROLL_COUNT][ENROLL_COUNT];
        int i, j;
        for (i = 0; i < ENROLL_COUNT; i++)
            for (j = 0; j < ENROLL_COUNT; j++) m[i][j] = 9000;
        m[0][1] = m[1][0] = 1000;
        m[2][3] = m[3][2] = 1000;
        m[4][0] = m[0][4] = 3000;
        CHECK("tau from nearest, not from all pairs", enroll_tau(m), 1400 + 2*800);
    }

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
    CHECK("centre x", x, 96); CHECK("centre y", y, 96);
    p.x = 5 * 60; p.y = 5 * 30;      /* right and up on the board */
    screen_xy(&p, &x, &y);
    CHECK("right", x, 156); CHECK("up is smaller y", y, 66);
    p.x = 30000; p.y = -30000;
    screen_xy(&p, &x, &y);
    CHECK("clamp x", x, 191); CHECK("clamp y", y, 191);
}

/* ---- ui.c: the screen is kept in arrays here ---- */
static uint8_t scr_ch[UI_ROWS][UI_COLS], scr_attr[UI_ROWS][UI_COLS];
static int scr_bad = 0;

static FILE *relay_file;

void relay_out(const char *s)
{
    if (relay_file) fputs(s, relay_file);
}

void ui_cell(int col, int row, uint8_t ch, uint8_t attr)
{
    relay_cell(col, row, ch, attr);
    if (col < 0 || col >= UI_COLS || row < 0 || row >= UI_ROWS || ch == 0 || ch > 127) { scr_bad++; return; }
    scr_ch[row][col] = ch;
    scr_attr[row][col] = attr;
}

/* Cells as text: bar pieces become '1'..'8', the vertical line '|', other specials '~' */
static void check_row(const char *name, int row, int col, const char *want)
{
    char got[UI_COLS + 1];
    int i;
    for (i = 0; want[i] && col + i < UI_COLS; i++) {
        uint8_t c = scr_ch[row][col + i];
        got[i] = c >= 0x20 ? (char)c : c <= 8 ? (char)('0' + c) : c == 0x11 ? '|' : '~';
    }
    got[i] = 0;
    if (strcmp(got, want) != 0 && fails++ < 10) printf("FAIL ui %s\n  got  \"%s\"\n  want \"%s\"\n", name, got, want);
}

static const char *dump_path;      /* argv[2]: where to write the screen for pc/render_screen.py */

static void test_ui(void)
{
    /* Same values as the "match" screen of docs/vga-ui-mockup.html; expected rows are its output. */
    static const uint32_t d[MAX_SLOTS] = { 9120, 2412, 12740, 0, 0 };
    person p[MAX_SLOTS];
    pen_pos pen = { 124, -81, 88, 128, 0 };
    int32_t lsb[12] = { 400, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    uint32_t big[MAX_SLOTS] = { 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF };
    int k;
    memset(p, 0, sizeof(p));
    p[0].count = p[1].count = p[2].count = ENROLL_COUNT;
    p[0].tau = 3466; p[1].tau = 3881; p[2].tau = 4544;
    p[3].count = 2;

    ui_frame();
    ui_title(0, 1, 4);
    ui_pen(&pen, 1, 1);
    ui_sensors(lsb, 4);
    ui_match(d, p, 1);
    ui_banner(BANNER_OK, "IDENTIFIED AS", "PERSON 2", "d 2412 < tau 3881");
    ui_time(138, 310400);
    ui_status("ready");

    if (dump_path) {
        /* the same screen as relay lines, with lines and a cursor, for pc/screen.py --check */
        char rp[256];
        snprintf(rp, sizeof(rp), "%s.relay", dump_path);
        relay_file = fopen(rp, "w");
        relay_flush();
        relay_clear();
        relay_line(10, 20, 150, 40);
        relay_line(150, 40, 60, 170);
        relay_cursor(1, C_GREEN, 60, 170);
        relay_cursor(1, C_GREEN, 60, 170);      /* unchanged: must not be sent again */
        relay_refresh_row();                    /* row 0 again, unchanged content */
        relay_flush();
        fclose(relay_file);
        relay_file = NULL;
    }
    if (dump_path) {
        FILE *f = fopen(dump_path, "w");
        int r, c;
        for (r = 0; r < UI_ROWS; r++)
            for (c = 0; c < UI_COLS; c++) fprintf(f, "%d %d\n", scr_ch[r][c], scr_attr[r][c]);
        fclose(f);
    }
    check_row("title", 0, 0, " DE2 MAGIC PEN  signature identification     MODE IDENTIFY  DTW HW  50Hz  S 4/4 ");
    check_row("frame", 1, 0, "~~ PAD 96 x 96 mm ~");
    check_row("state", 2, 51, "state  DOWN");
    check_row("xy", 3, 51, "x +12.4 mm    y  -8.1 mm");
    check_row("z", 4, 51, "z   8.8 mm  88883 || ");       /* 8.8 mm = 35 steps = 4 cells + 3/8; marks at 12 and 15 mm */
    check_row("tilt", 5, 51, "tilt 30 deg   toward ~");
    check_row("sensor 0", 9, 51, "S0 84    100");           /* 400 LSB = 100 uT: 12 steps = 1 cell + 4/8 */
    check_row("sensor 2", 9, 66, "S2 NO ANSWER");
    check_row("P1", 12, 51, "P1 888|888881        9120  ");
    check_row("P2", 13, 51, "P2 883|              2412 <");
    check_row("P3", 14, 51, "P3 8888|88888886    12740  ");
    check_row("P4", 15, 51, "P4 enrolling");
    check_row("P5", 16, 51, "P5 empty slot");
    check_row("banner 1", 19, 51, "        IDENTIFIED AS        ");
    check_row("banner 2", 20, 51, "          PERSON 2           ");
    check_row("banner 3", 21, 51, "      d 2412 < tau 3881      ");
    check_row("HW", 24, 51, "HW 8882              138 us");
    check_row("SW", 25, 51, "SW 8888888888885  310400 us");
    check_row("ratio", 26, 51, "SW / HW = x2249  (log scale)");
    check_row("status", 29, 0, " ready ");
    CHECK("banner colour", scr_attr[20][62], C_DGREEN << 4 | C_WHITE);
    /* row 13 is person 2 (under tau): the bar takes the person's colour; the tau mark is white */
    CHECK("bar colour under threshold", scr_attr[13][54], C_TRACK << 4 | ui_person_colour[1]);
    CHECK("bar colour over threshold", scr_attr[12][54], C_TRACK << 4 | C_DIM);
    CHECK("mark on a filled bar", scr_attr[12][57], C_DIM << 4 | C_WHITE);
    CHECK("mark past the bar", scr_attr[13][57], C_TRACK << 4 | C_WHITE);
    ui_banner_person(2, "IDENTIFIED AS", "PERSON 3", "d 1 < tau 2");
    check_row("person banner", 20, 51, "          PERSON 3           ");
    CHECK("person banner colour", scr_attr[20][62], C_PANEL << 4 | ui_person_colour[2]);

    CHECK("tilt 30", ui_tilt_deg(128, 0), 30);
    CHECK("tilt 0", ui_tilt_deg(0, 0), 0);
    CHECK("tilt 90", ui_tilt_deg(256, 0), 90);
    CHECK("east", ui_octant(128, 0), 0);
    CHECK("north-east", ui_octant(90, 90), 1);
    CHECK("north-west", ui_octant(-91, 91), 3);
    CHECK("south", ui_octant(10, -128), 6);

    /* extreme values must stay inside their fields and inside the screen */
    pen.x = -32768; pen.y = 32767; pen.z = 32767; pen.ux = 32767; pen.uy = -32768;
    for (k = 0; k < 12; k++) lsb[k] = k & 1 ? 32767 : -32768;
    for (k = 0; k < MAX_SLOTS; k++) { p[k].count = ENROLL_COUNT; p[k].tau = 0xFFFFFF; }
    ui_pen(&pen, 0, 1);
    ui_pen(&pen, 0, 0);
    ui_sensors(lsb, 0);
    ui_match(big, p, 4);
    ui_match(0, p, -1);
    ui_enroll(4, 5, 0xFFFFFF);
    ui_collect(1000, 1000, 1000);
    ui_time(0xFFFFFFFF, 1);
    ui_time(0, 0);
    ui_banner(BANNER_BAD, "a top line that is much longer than the banner", "", "x");
    ui_status("a status line that is longer than the whole screen is wide, so it has to be cut off at the edge");
    ui_title(3, 0, 0);
    CHECK("writes outside the screen", scr_bad, 0);
    check_row("frame intact", 1, 49, "~ PEN ~");
    check_row("help intact", 27, 0, " SW1-0 mode");
    check_row("overflowing number", 13, 69, "999 ");
}

/* Compiled twice by run_checks.sh; the second time with -DTEST_MOUNT (see config.h) */
static void test_mount(void)
{
#ifdef TEST_MOUNT
    /* rot {1,2,3,0}, FIELD_SIGN -1, Z_SIGN -1, MIRROR_XY 1: same numbers as pc/gate1.py check() */
    static const int32_t want[12] = { 1, -2, 3, 5, 4, 6, -7, 8, 9, -11, -10, 12 };
#else
    /* The real mount values in config.h: expected result from the rule in pc/pen_model.py
     * (MIRROR_XY swaps x and y, quarter turn = (x, y) -> (-y, x), then FIELD_SIGN on all,
     * Z_SIGN on z). */
    static const int rot[4] = MOUNT_ROT;
    int32_t want[12];
    int r;
#endif
    int32_t v[12];
    int k;
#ifndef TEST_MOUNT
    for (k = 0; k < 4; k++) {
        int32_t x = 3*k + 1, y = 3*k + 2, t;
        if (MIRROR_XY) { t = x; x = y; y = t; }
        for (r = 0; r < rot[k]; r++) { t = x; x = -y; y = t; }
        want[3*k] = FIELD_SIGN * x; want[3*k + 1] = FIELD_SIGN * y; want[3*k + 2] = FIELD_SIGN * Z_SIGN * (3*k + 3);
    }
#endif
    for (k = 0; k < 12; k++) v[k] = k + 1;
    mount_correct(v);
    for (k = 0; k < 12; k++) CHECK("mount", v[k], want[k]);
}

int main(int argc, char **argv)
{
    relay_init();
    test_mount();
#ifdef TEST_MOUNT
    if (fails) { printf("FAILED mount\n"); return 1; }
    printf("mount OK\n");
    return 0;
#endif
    dump_path = argc > 2 ? argv[2] : NULL;
    g = argc > 1 ? fopen(argv[1], "r") : NULL;
    if (!g) { printf("cannot open golden file\n"); return 2; }
    test_icbrt();
    test_mlp();
    test_signature();
    test_dtw();
    test_filter();
    test_trim();
    test_zref();
    test_decide();
    test_screen();
    test_ui();
    if (fails) { printf("FAILED %d checks\n", fails); return 1; }
    printf("C core OK\n");
    return 0;
}
