/* ui.c - what the monitor shows. Layout and reasons: docs/vga-ui-mockup.html.
 *
 * The screen is 80 x 30 character cells (hdl/vga_ui.v). Everything here ends in
 * ui_cell(col, row, character, colours), which main.c sends to the hardware and
 * nios/test_host.c stores in an array. So this file runs and is tested on a PC.
 *
 * Bars: a bar of n cells has n*8 steps. Full cells use glyph G_BAR8, the last cell
 * uses G_BAR1..G_BAR8 (1/8 to 8/8 filled), so a bar moves one pixel at a time.
 * Numbers: no printf, because it is large and slow on the Nios II. Division by 10
 * is the only arithmetic needed.
 * Check: nios/test_host.c compares rows with the mockup for the same input values.
 */
#include "core.h"
#include "glyphs.h"

#define RX 51            /* first column of the right-hand panel (51..79) */
#define RW 29

static void put(int col, int row, const char *s, int fg, int bg)
{
    for (; *s && col < UI_COLS; s++, col++) ui_cell(col, row, (uint8_t)*s, (uint8_t)(bg << 4 | fg));
}

static void fill(int col, int row, int n, int bg)
{
    for (; n > 0 && col < UI_COLS; n--, col++) ui_cell(col, row, ' ', (uint8_t)(bg << 4 | C_TEXT));
}

/* Right-aligned unsigned number in `width` characters. Too big: all 9s. */
static void put_num(int col, int row, uint32_t v, int width, int fg, int bg)
{
    char buf[12];
    uint32_t limit = 1;
    int i;
    for (i = 0; i < width; i++) limit *= 10;
    if (v >= limit) v = limit - 1;
    buf[width] = 0;
    for (i = width - 1; i >= 0; i--) {
        buf[i] = (v || i == width - 1) ? (char)('0' + v % 10) : ' ';
        v /= 10;
    }
    put(col, row, buf, fg, bg);
}

/* Tenths with one decimal in 5 characters, e.g. -123 -> "-12.3". plus: show '+'. */
static void put_tenths(int col, int row, int v, int plus, int fg, int bg)
{
    char buf[6] = "     ";
    int a = v < 0 ? -v : v, i = 2;
    if (a > 999) a = 999;
    buf[4] = (char)('0' + a % 10);
    buf[3] = '.';
    a /= 10;
    do { buf[i--] = (char)('0' + a % 10); a /= 10; } while (a && i >= 1);
    if (v < 0) buf[i] = '-';
    else if (plus) buf[i] = '+';
    put(col, row, buf, fg, bg);
}

/* Bar of `len` cells filled to `eighths` (0..len*8). */
static void bar(int col, int row, int len, int eighths, int fg)
{
    int i;
    if (eighths < 0) eighths = 0;
    if (eighths > len * 8) eighths = len * 8;
    for (i = 0; i < len; i++) {
        int e = eighths - i * 8;
        ui_cell(col + i, row, e <= 0 ? ' ' : (uint8_t)(G_BAR1 - 1 + (e > 8 ? 8 : e)), (uint8_t)(C_TRACK << 4 | fg));
    }
}

/* A mark inside a bar. It replaces the bar glyph of one cell, and takes the bar
 * colour as its background where the bar has passed it. */
static void tick(int col, int row, int len, int cell, int eighths, int fg, int bar_fg)
{
    if (cell >= len) cell = len - 1;
    ui_cell(col + cell, row, G_VLINE, (uint8_t)((eighths >= (cell + 1) * 8 ? bar_fg : C_TRACK) << 4 | fg));
}

static void header(int row, const char *s)
{
    int c = RX;
    put(RX, row, s, C_CYAN, C_BG);
    while (s[c - RX]) c++;
    ui_cell(c++, row, ' ', C_BG << 4 | C_TEXT);
    for (; c < UI_COLS; c++) ui_cell(c, row, G_HLINE, C_BG << 4 | C_RULE);
}

/* log2(v) * 256 for v >= 1. The whole part is the position of the top bit. Each
 * fraction bit comes from squaring the mantissa: if the square reaches 2, the bit is 1. */
static uint32_t log2_q8(uint32_t v)
{
    uint32_t e = 0, m, r;
    int i;
    while ((v >> e) > 1) e++;
    m = e <= 15 ? v << (15 - e) : v >> (e - 15);     /* 1.0 <= m < 2.0, 15 fraction bits */
    r = e;
    for (i = 0; i < 8; i++) {
        m = (m * m) >> 15;
        r <<= 1;
        if (m >= (2u << 15)) { m >>= 1; r |= 1; }
    }
    return r;
}

/* ---- static parts ---- */

void ui_put(int col, int row, const char *s, int fg) { put(col, row, s, fg, C_BG); }
void ui_bar(int col, int row, int len, int eighths, int fg) { bar(col, row, len, eighths, fg); }

void ui_pad_clear(void)
{
    int r;
    for (r = 2; r <= 25; r++) fill(1, r, 48, C_BG);
}

void ui_frame(void)
{
    int r, c;
    for (r = 0; r < UI_ROWS; r++) fill(0, r, UI_COLS, r == 0 ? C_TITLE : r == 29 ? C_PANEL : C_BG);
    put(1, 0, "DE2 MAGIC PEN", C_WHITE, C_TITLE);
    put(16, 0, "signature identification", C_TEXT, C_TITLE);
    put(45, 0, "MODE", C_DIM, C_TITLE);
    put(60, 0, "DTW", C_DIM, C_TITLE);
    put(68, 0, "50Hz", C_TEXT, C_TITLE);
    for (c = 1; c < 49; c++) {
        ui_cell(c, 1, G_HLINE, C_BG << 4 | C_RULE);
        ui_cell(c, 26, G_HLINE, C_BG << 4 | C_RULE);
    }
    for (r = 2; r < 26; r++) {
        ui_cell(0, r, G_VLINE, C_BG << 4 | C_RULE);
        ui_cell(49, r, G_VLINE, C_BG << 4 | C_RULE);
    }
    ui_cell(0, 1, G_TL, C_BG << 4 | C_RULE);
    ui_cell(49, 1, G_TR, C_BG << 4 | C_RULE);
    ui_cell(0, 26, G_BL, C_BG << 4 | C_RULE);
    ui_cell(49, 26, G_BR, C_BG << 4 | C_RULE);
    put(2, 1, " PAD 96 x 96 mm ", C_DIM, C_BG);
    put(31, 1, " paper 80 x 80 mm ", C_DIM, C_BG);
    put(1, 27, "SW1-0 mode 00 identify 01 enroll 10 collect   SW4-2 slot   SW5 DTW SW/HW", C_DIM, C_BG);
    put(1, 28, "KEY0 baseline   KEY1 end signature   KEY2 cancel last   KEY3 reset   SW7 LEDs", C_DIM, C_BG);
}

void ui_title(int mode, int use_hw, int sensors_ok)
{
    static const char *const names[4] = { "IDENTIFY", "ENROLL  ", "COLLECT ", "-       " };
    put(50, 0, names[mode & 3], C_AMBER, C_TITLE);
    put(64, 0, use_hw ? "HW" : "SW", C_AMBER, C_TITLE);
    put(74, 0, "S ", sensors_ok == 4 ? C_GREEN : C_RED, C_TITLE);
    put_num(76, 0, (uint32_t)sensors_ok, 1, sensors_ok == 4 ? C_GREEN : C_RED, C_TITLE);
    put(77, 0, "/4", sensors_ok == 4 ? C_GREEN : C_RED, C_TITLE);
}

void ui_status(const char *s)
{
    int c = 1;
    for (; *s && c < UI_COLS - 1; s++, c++) ui_cell(c, 29, (uint8_t)*s, C_PANEL << 4 | C_TEXT);
    fill(c, 29, UI_COLS - c, C_PANEL);
}

/* ---- PEN panel, rows 1..5 ---- */

/* sin^2(angle) * 65536 for 0..90 degrees: the tilt angle without a square root or asin */
static const uint16_t sin2_table[91] = {
    0, 20, 80, 180, 319, 498, 716, 973, 1269, 1604, 1976, 2386, 2833,
    3316, 3836, 4390, 4979, 5602, 6258, 6946, 7666, 8417, 9197, 10005, 10842, 11705,
    12594, 13507, 14444, 15404, 16384, 17384, 18403, 19440, 20493, 21561, 22642, 23736, 24841,
    25955, 27078, 28208, 29343, 30482, 31624, 32768, 33912, 35054, 36193, 37328, 38458, 39581,
    40695, 41800, 42894, 43975, 45043, 46096, 47133, 48152, 49152, 50132, 51092, 52029, 52942,
    53831, 54694, 55531, 56339, 57119, 57870, 58590, 59278, 59934, 60557, 61146, 61700, 62220,
    62703, 63150, 63560, 63932, 64267, 64563, 64820, 65038, 65217, 65356, 65456, 65516, 65535,
};

/* Tilt from vertical in degrees. ux, uy are the horizontal part of the pen axis in Q8. */
int ui_tilt_deg(int ux, int uy)
{
    uint32_t s2 = (uint32_t)(ux * ux + uy * uy);     /* sin^2 in Q16 */
    int deg = 0;
    while (deg < 90 && sin2_table[deg + 1] <= s2) deg++;
    return deg;
}

/* Which of 8 directions the pen leans to: 0 = +x (east), then counter-clockwise.
 * 414/1000 is tan(22.5 degrees), the border between "east" and "north-east". */
int ui_octant(int ux, int uy)
{
    int ax = ux < 0 ? -ux : ux, ay = uy < 0 ? -uy : uy;
    if (ay * 1000 < ax * 414) return ux > 0 ? 0 : 4;
    if (ax * 1000 < ay * 414) return uy > 0 ? 2 : 6;
    return ux > 0 ? (uy > 0 ? 1 : 7) : (uy > 0 ? 3 : 5);
}

void ui_pen(const pen_pos *p, int down, int present)
{
    int z_eighths, col = down ? C_GREEN : C_AMBER;
    header(1, "PEN");
    put(RX, 2, "state", C_DIM, C_BG);
    put(RX, 3, "x", C_DIM, C_BG);
    put(RX + 14, 3, "y", C_DIM, C_BG);
    put(RX, 4, "z", C_DIM, C_BG);
    put(RX, 5, "tilt", C_DIM, C_BG);
    put(RX + 14, 5, "toward", C_DIM, C_BG);
    if (!present) {
        put(RX + 7, 2, "AWAY", C_DIM, C_BG);
        put(RX + 2, 3, " --.- mm", C_DIM, C_BG);
        put(RX + 16, 3, " --.- mm", C_DIM, C_BG);
        put(RX + 2, 4, " --.- mm", C_DIM, C_BG);
        bar(RX + 12, 4, 16, 0, C_DIM);
        put(RX + 5, 5, "-- deg", C_DIM, C_BG);
        put(RX + 21, 5, " ", C_DIM, C_BG);
        return;
    }
    put(RX + 7, 2, down ? "DOWN" : "UP  ", col, C_BG);
    put_tenths(RX + 2, 3, p->x, 1, C_TEXT, C_BG);
    put(RX + 7, 3, " mm", C_TEXT, C_BG);
    put_tenths(RX + 16, 3, p->y, 1, C_TEXT, C_BG);
    put(RX + 21, 3, " mm", C_TEXT, C_BG);
    put_tenths(RX + 2, 4, p->z < 0 ? 0 : p->z, 0, C_TEXT, C_BG);
    put(RX + 7, 4, " mm", C_TEXT, C_BG);
    /* 16 cells = 0..32 mm: one step is 0.25 mm. Marks at the pen-down and pen-up heights. */
    z_eighths = p->z < 0 ? 0 : p->z * 2 / 5;
    bar(RX + 12, 4, 16, z_eighths, col);
    tick(RX + 12, 4, 16, Z_DOWN / 20, z_eighths, C_WHITE, col);
    tick(RX + 12, 4, 16, Z_UP / 20, z_eighths, C_DIM, col);
    put_num(RX + 5, 5, (uint32_t)ui_tilt_deg(p->ux, p->uy), 2, C_TEXT, C_BG);
    put(RX + 7, 5, " deg", C_TEXT, C_BG);
    ui_cell(RX + 21, 5, (uint8_t)(G_ARROW_E + ui_octant(p->ux, p->uy)), C_BG << 4 | C_CYAN);
}

/* ---- SENSORS panel, rows 7..9. Placed like the real corners of the board. ---- */

void ui_sensors(const int32_t lsb[12], uint32_t err)
{
    static const int col_of[4] = { RX, RX, RX + 15, RX + 15 };   /* sensor 0,1 left; 2,3 right */
    static const int row_of[4] = { 9, 8, 9, 8 };                 /* sensor 1,3 far side (+y) on top */
    int k;
    header(7, "SENSORS |B| uT");
    for (k = 0; k < 4; k++) {
        int c = col_of[k], r = row_of[k], e;
        int32_t x = lsb[3*k] >> 3, y = lsb[3*k + 1] >> 3, z = (lsb[3*k + 2] * 1612 / 1000) >> 3;
        uint32_t mag = isqrt((uint32_t)(x*x + y*y + z*z)) << 3;   /* field strength in X/Y LSBs */
        put(c, r, "S", C_TEXT, C_BG);
        put_num(c + 1, r, (uint32_t)k, 1, C_TEXT, C_BG);
        if ((err >> k) & 1) { put(c + 3, r, "NO ANSWER", C_RED, C_BG); continue; }
        /* 4 cells, one per factor of 8 above 16 LSB (4 uT), like the LEDR bars */
        e = mag < 16 ? 0 : (int)(((log2_q8(mag) - 4*256) * 8 / 3 + 128) >> 8);
        bar(c + 3, r, 4, e, mag > 30000 ? C_RED : C_BLUE);
        fill(c + 7, r, 1, C_BG);
        put_num(c + 8, r, mag / 4, 4, C_TEXT, C_BG);              /* 0.25 uT per LSB */
    }
}

/* ---- middle panel, rows 11..17: MATCH, ENROLL or COLLECT ---- */

static void middle_clear(void)
{
    int r;
    for (r = 12; r <= 17; r++) fill(RX, r, RW, C_BG);
}

/* d = 0: no result yet, only the thresholds are shown. best = -1: nobody. */
/* Person colours: P1 cyan, P2 amber, P3 blue, P4 green, P5 white. Red stays for "not enrolled". */
const uint8_t ui_person_colour[MAX_SLOTS] = { C_CYAN, C_AMBER, C_BLUE, C_GREEN, C_WHITE };

void ui_match(const uint32_t *d, const person *people, int best)
{
    int k;
    header(11, "MATCH  DTW distance");
    middle_clear();
    for (k = 0; k < MAX_SLOTS; k++) {
        int row = 12 + k, e, col;
        put(RX, row, "P", ui_person_colour[k], C_BG);
        put_num(RX + 1, row, (uint32_t)(k + 1), 1, ui_person_colour[k], C_BG);
        if (people[k].count != ENROLL_COUNT) {
            put(RX + 3, row, people[k].count ? "enrolling" : "empty slot", C_DIM, C_BG);
            continue;
        }
        /* 16 cells = 0..16000: 1000 per cell */
        e = d ? (int)((d[k] > 16000 ? 16000 : d[k]) * 8 + 500) / 1000 : 0;
        col = d && d[k] < people[k].tau ? ui_person_colour[k] : C_DIM;
        bar(RX + 3, row, 16, e, col);
        tick(RX + 3, row, 16, (int)(people[k].tau / 1000), e, C_WHITE, col);
        if (d) put_num(RX + 20, row, d[k], 5, k == best ? C_WHITE : C_TEXT, C_BG);
        if (k == best) put(RX + 26, row, "<", C_WHITE, C_BG);
    }
    ui_cell(RX + 3, 17, G_VLINE, C_BG << 4 | C_WHITE);
    put(RX + 5, 17, "= threshold tau", C_DIM, C_BG);
}

void ui_enroll(int slot, int count, uint32_t tau)
{
    int i;
    header(11, "ENROLL");
    middle_clear();
    put(RX, 13, "PERSON", C_WHITE, C_BG);
    put_num(RX + 7, 13, (uint32_t)(slot + 1), 1, C_WHITE, C_BG);
    put(RX + 10, 13, "slot = SW4-2", C_DIM, C_BG);
    for (i = 0; i < ENROLL_COUNT; i++)
        ui_cell(RX + 2*i, 15, i < count ? G_SQ_FULL : G_SQ_EMPTY, C_BG << 4 | (i < count ? C_GREEN : C_DIM));
    put_num(RX + 12, 15, (uint32_t)count, 1, C_TEXT, C_BG);
    put(RX + 14, 15, "of 5", C_TEXT, C_BG);
    if (count == ENROLL_COUNT) {
        put(RX, 17, "threshold tau", C_DIM, C_BG);
        put_num(RX + 14, 17, tau, 6, C_TEXT, C_BG);
    } else {
        put(RX, 17, "tau is set after 5", C_DIM, C_BG);
    }
}

void ui_collect(int saved, int rejected, int marks)
{
    header(11, "COLLECT  -> PC (JTAG UART)");
    middle_clear();
    put(RX, 13, "signatures saved", C_DIM, C_BG);
    put_num(RX + 18, 13, (uint32_t)saved, 3, C_WHITE, C_BG);
    put(RX, 14, "rejected", C_DIM, C_BG);
    put_num(RX + 18, 14, (uint32_t)rejected, 3, C_TEXT, C_BG);
    put(RX, 15, "MARK (KEY1)", C_DIM, C_BG);
    put_num(RX + 18, 15, (uint32_t)marks, 3, C_TEXT, C_BG);
    put(RX, 17, "raw 12 ch + position, 50 Hz", C_DIM, C_BG);
}

/* ---- result banner, rows 19..21 ---- */

static void centre(int row, const char *s, int fg, int bg)
{
    int n = 0;
    while (s[n]) n++;
    if (n > RW) n = RW;
    fill(RX, row, RW, bg);
    put(RX + (RW - n) / 2, row, s, fg, bg);
}

void ui_banner(int kind, const char *top, const char *mid, const char *bot)
{
    static const uint8_t bg_of[3] = { C_PANEL, C_DGREEN, C_DRED };
    static const uint8_t fg_of[3] = { C_CYAN, C_GREEN, C_RED };
    centre(19, top, fg_of[kind], bg_of[kind]);
    centre(20, mid, C_WHITE, bg_of[kind]);
    centre(21, bot, fg_of[kind], bg_of[kind]);
}

/* Result banner in the colour of person k (identified). */
void ui_banner_person(int k, const char *top, const char *mid, const char *bot)
{
    centre(19, top, ui_person_colour[k], C_PANEL);
    centre(20, mid, ui_person_colour[k], C_PANEL);
    centre(21, bot, C_TEXT, C_PANEL);
}

/* ---- DTW TIME panel, rows 23..26. us = 0: not measured yet. ---- */

static void time_row(int row, const char *name, uint32_t us, int col)
{
    /* 14 cells = 10 us .. 1 s on a log scale: 112 steps for 5 decades.
     * steps = 22.4 * log10(us/10) = 6.743 * (log2(us) - log2(10)) */
    int e = us <= 10 ? 0 : (int)(((log2_q8(us) - 850) * 6743 / 1000 + 128) >> 8);
    put(RX, row, name, C_TEXT, C_BG);
    bar(RX + 3, row, 14, e, col);
    fill(RX + 17, row, 1, C_BG);
    if (us) {
        put_num(RX + 18, row, us, 6, C_TEXT, C_BG);
        put(RX + 24, row, " us", C_TEXT, C_BG);
    } else {
        put(RX + 18, row, "   --- us", C_DIM, C_BG);
    }
}

void ui_time(uint32_t hw_us, uint32_t sw_us)
{
    header(23, "DTW TIME  last run");
    time_row(24, "HW", hw_us, C_GREEN);
    time_row(25, "SW", sw_us, C_AMBER);
    fill(RX, 26, RW, C_BG);
    if (hw_us && sw_us) {
        uint32_t ratio = (sw_us + hw_us / 2) / hw_us;
        int c = RX + 11;
        put(RX, 26, "SW / HW =", C_DIM, C_BG);
        put(RX + 10, 26, "x", C_WHITE, C_BG);
        /* left-aligned number: count the digits first */
        {
            uint32_t t = ratio;
            int digits = 1;
            while (t >= 10) { t /= 10; digits++; }
            if (digits > 5) digits = 5;
            put_num(c, 26, ratio, digits, C_WHITE, C_BG);
        }
        put(RX + 17, 26, "(log scale)", C_DIM, C_BG);
    } else {
        put(RX, 26, "flip SW5 and sign again", C_DIM, C_BG);
    }
}
