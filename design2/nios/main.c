/* main.c - Nios II application. Polls the sensor reader, tracks the pen, and
 * identifies signatures. Not testable on a PC; all processing lives in core.h
 * functions, which are.
 *
 * Switches (README section 7):
 *   SW[1:0]  00 identify, 01 enroll (SW[4:2] = slot), 10 collect data over JTAG UART
 *   SW[5]    0 DTW in software, 1 DTW in the hardware accelerator
 *   KEY0 re-measure baseline (pen away), KEY1 end signature, KEY2 cancel last enrolled
 *   KEY3 is the hardware reset.
 * Display: LCD result, HEX latency in us, LEDG all = enrolled person, LEDR blink = not.
 * Monitor: the whole state (nios/ui.c, docs/vga-ui-mockup.html).
 * SW[7]: LEDR shows the field strength at each sensor (for checking wiring).
 *
 * Bring-up: at power up the LCD shows which of the four sensors answer, and the
 * I2C addresses found are printed to the JTAG UART. Run this before anything else.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "system.h"
#include "io.h"
#include "core.h"

/* mlx_reader registers (word offsets) */
#define MLX_FRAME 0
#define MLX_ERR 1
#define MLX_TIME 2
#define MLX_PROBE 3
#define MLX_CFG0 4
#define MLX_NOW 10
#define MLX_SAMPLE 16
/* dtw_accel registers (word offsets) */
#define DTW_CTRL 0
#define DTW_STATUS 1
#define DTW_NTEMPL 2
#define DTW_CYCLES 5
#define DTW_RESULT 0x40
#define DTW_QUERY 0x1000
#define DTW_TEMPL 0x2000

#define MLX(r)  IORD(MLX_READER_0_BASE, (r))
typedef const int8_t (*csig)[SIG_CH];  /* gcc 4.1 needs a cast to add const here */

static const char *names[MAX_SLOTS] = { "PERSON 1", "PERSON 2", "PERSON 3", "PERSON 4", "PERSON 5" };

static int8_t  templates[MAX_SLOTS][ENROLL_COUNT][SIG_N][SIG_CH];
static person  people[MAX_SLOTS];
static sig_buf sig;
static int8_t  query[SIG_N][SIG_CH];
static FILE   *lcd;
static int     templates_changed = 1;

/* The LCD has 16 columns. Printing more wraps or scrolls, so length is cut here. */
static void lcd_show(const char *a, const char *b)
{
    if (!lcd) return;
    fprintf(lcd, "\x1b[2J\x1b[1;1H%.16s\x1b[2;1H%.16s", a, b);
    fflush(lcd);
}

static uint32_t read_inputs(void)
{
    return IORD(PIO_IN_BASE, 0);   /* bits 17:0 SW, bits 21:18 KEY (pressed = 0) */
}

/* ---- monitor (hdl/vga_ui.v): text cells, pad bitmap, pen cursor ---- */
#define VGA_CTRL 0
#define VGA_FROM 1
#define VGA_TO 2
#define VGA_CURSOR 3
#define VGA_TEXT 4096

void ui_cell(int col, int row, uint8_t ch, uint8_t attr)
{
    IOWR(VGA_0_BASE, VGA_TEXT + row * UI_COLS + col, (attr << 8) | ch);
}

static void vga_xy_line(int x0, int y0, int x1, int y1)
{
    while (IORD(VGA_0_BASE, VGA_CTRL) & 1) ;
    IOWR(VGA_0_BASE, VGA_FROM, (y0 << 16) | x0);
    IOWR(VGA_0_BASE, VGA_TO, (y1 << 16) | x1);
}

static void vga_line(const pen_pos *a, const pen_pos *b)
{
    int x0, y0, x1, y1;
    screen_xy(a, &x0, &y0);
    screen_xy(b, &x1, &y1);
    vga_xy_line(x0, y0, x1, y1);
}

/* Empty pad: dashed outline of the 80 mm paper (160 pixels), a dotted signing line
 * and an x mark, as on a paper form. Dashes are short lines; the drawer has no pattern. */
static void vga_pad_reset(void)
{
    int i;
    while (IORD(VGA_0_BASE, VGA_CTRL) & 1) ;
    IOWR(VGA_0_BASE, VGA_CTRL, 1);
    for (i = 16; i < 176; i += 6) {
        vga_xy_line(i, 16, i + 2, 16);
        vga_xy_line(i, 176, i + 2, 176);
        vga_xy_line(16, i, 16, i + 2);
        vga_xy_line(176, i, 176, i + 2);
    }
    for (i = 30; i <= 162; i += 2) vga_xy_line(i, 140, i, 140);
    vga_xy_line(24, 130, 30, 136);
    vga_xy_line(30, 130, 24, 136);
}

static void vga_cursor(const pen_pos *p, int present, int down)
{
    int x, y;
    screen_xy(p, &x, &y);
    IOWR(VGA_0_BASE, VGA_CURSOR, ((uint32_t)(present != 0) << 31) | ((uint32_t)(down ? C_GREEN : C_DIM) << 24) | (y << 16) | x);
}

/* Small helpers for the text lines built here. sprintf is fine: these run per event, not per frame. */
static int count_ok(uint32_t err)
{
    int k, n = 0;
    for (k = 0; k < 4; k++) n += !((err >> k) & 1);
    return n;
}

static void leds(uint32_t green, uint32_t red)
{
    IOWR(PIO_LED_BASE, 0, (green << 18) | red);
}

/* SW[7]: field strength bars on LEDR for checking the sensors. Four LEDs per sensor,
 * one more LED per factor of 8 above 16 LSB (4 uT). LEDR[17]: some axis is near saturation. */
static void show_field_bars(const int32_t lsb[12], uint32_t raw_peak)
{
    uint32_t bars = 0;
    int k, c;
    for (k = 0; k < 4; k++) {
        uint32_t m = 0;
        int leds_on = 0;
        for (c = 0; c < 3; c++) {
            uint32_t a = lsb[3*k + c] < 0 ? -lsb[3*k + c] : lsb[3*k + c];
            if (a > m) m = a;
        }
        while (m >= 16 && leds_on < 4) { leds_on++; m >>= 3; }
        bars |= ((1u << leds_on) - 1) << (4 * k);
    }
    if (raw_peak > 30000) bars |= 1u << 17;
    leds(0, bars);
}

static void hex_show(uint32_t value)
{
    uint32_t bcd = 0;
    int i;
    for (i = 0; i < 8; i++) {
        bcd |= (value % 10) << (4 * i);
        value /= 10;
    }
    IOWR(PIO_HEX_BASE, 0, bcd);
}

static int wait_frame(uint32_t *last, int32_t lsb[12], uint32_t *err)
{
    uint32_t f = MLX(MLX_FRAME);
    int k;
    if (f == *last) return 0;
    do {   /* the reader may replace the frame while we read: read again if so */
        f = MLX(MLX_FRAME);
        for (k = 0; k < 12; k++) lsb[k] = (int32_t)MLX(MLX_SAMPLE + k);
        *err = MLX(MLX_ERR);
    } while (f != MLX(MLX_FRAME));
    *last = f;
    return 1;
}

/* Print every address that answers, on the terminal and on the monitor. For checking wiring. */
static void i2c_scan(void)
{
    int bus, a, row = 6;
    char line[40];
    ui_put(3, 4, "I2C SCAN", C_CYAN);
    for (bus = 0; bus < 4; bus++)
        for (a = 0x08; a < 0x78; a++) {
            IOWR(MLX_READER_0_BASE, MLX_PROBE, 0x80000000u | (bus << 8) | a);
            usleep(100);
            while (MLX(MLX_PROBE) & 0x80000000u) ;
            if (MLX(MLX_PROBE) & 1) {
                printf("I2C bus %d: device at 0x%02X\n", bus, a);
                snprintf(line, sizeof(line), "bus %d   0x%02X   ACK", bus, a);
                if (row < 12) ui_put(4, row++, line, C_TEXT);
            }
        }
    if (row == 6) ui_put(4, 6, "no device answered", C_RED);
}

static void baseline_measure(uint32_t *last, int32_t base[12])
{
    int64_t sum[12];
    int32_t lsb[12];
    uint32_t err;
    int n = 0, k;
    memset(sum, 0, sizeof(sum));
    lcd_show("BASELINE", "KEEP PEN AWAY");
    ui_put(3, 14, "BASELINE", C_CYAN);
    ui_put(4, 16, "keep the pen away from the pad", C_TEXT);
    ui_banner(BANNER_INFO, "", "BASELINE", "keep the pen away");
    while (n < BASELINE_FRAMES) {
        if (!wait_frame(last, lsb, &err)) continue;
        for (k = 0; k < 12; k++) sum[k] += lsb[k];
        n++;
        ui_bar(4, 18, 32, n * 256 / BASELINE_FRAMES, C_BLUE);
    }
    for (k = 0; k < 12; k++) base[k] = (int32_t)(sum[k] / BASELINE_FRAMES);
    lcd_show("READY", "SIGN ON PAPER");
    ui_pad_clear();
    vga_pad_reset();
}

/* Copies a signature to the accelerator 32 bits at a time. */
static void accel_write(uint32_t base_word, const int8_t s[SIG_N][SIG_CH])
{
    int i;
    for (i = 0; i < SIG_N; i++) {
        const uint32_t *w = (const void *)s[i];
        IOWR(DTW_ACCEL_0_BASE, base_word + 2*i, w[0]);
        IOWR(DTW_ACCEL_0_BASE, base_word + 2*i + 1, w[1]);
    }
}

/* Distance to each enrolled person: the smallest over that person's templates.
 * The time includes copying the query, which every hardware run needs, so the SW/HW
 * comparison stays fair. Templates are copied only after they change. */
static uint32_t identify_all(uint32_t d[MAX_SLOTS], int use_hw)
{
    uint32_t t0, t1;
    int k, j, n = 0;
    for (k = 0; k < MAX_SLOTS; k++) d[k] = DTW_BIG;

    if (use_hw) {
        for (k = 0; k < MAX_SLOTS; k++)
            for (j = 0; j < people[k].count; j++, n++)
                if (templates_changed) accel_write(DTW_TEMPL + 256*n, (csig)templates[k][j]);
        templates_changed = 0;
        if (n == 0) return 0;
        IOWR(DTW_ACCEL_0_BASE, DTW_NTEMPL, n);
        t0 = MLX(MLX_NOW);
        accel_write(DTW_QUERY, (csig)query);
        IOWR(DTW_ACCEL_0_BASE, DTW_CTRL, 1);
        while (IORD(DTW_ACCEL_0_BASE, DTW_STATUS) & 1) ;
        t1 = MLX(MLX_NOW);
        n = 0;
        for (k = 0; k < MAX_SLOTS; k++)
            for (j = 0; j < people[k].count; j++, n++) {
                uint32_t v = IORD(DTW_ACCEL_0_BASE, DTW_RESULT + n);
                if (v < d[k]) d[k] = v;
            }
    } else {
        t0 = MLX(MLX_NOW);
        for (k = 0; k < MAX_SLOTS; k++)
            for (j = 0; j < people[k].count; j++) {
                uint32_t v = dtw_sw((csig)query, (csig)templates[k][j]);
                if (v < d[k]) d[k] = v;
            }
        t1 = MLX(MLX_NOW);
    }
    return t1 - t0;
}

static uint32_t last_hw_us, last_sw_us;     /* 0 = not measured yet */

static void do_identify(int use_hw)
{
    uint32_t d[MAX_SLOTS], us;
    char line[32], status[80];
    int who, i, k, near = -1;
    sig_preprocess(&sig, query);
    us = identify_all(d, use_hw);
    who = decide(d, people, MAX_SLOTS);
    hex_show(us);
    if (use_hw) last_hw_us = us; else last_sw_us = us;
    for (k = 0; k < MAX_SLOTS; k++)          /* closest enrolled person, to explain the answer */
        if (people[k].count == ENROLL_COUNT && (near < 0 || d[k] < d[near])) near = k;
    ui_match(near < 0 ? 0 : d, people, near);
    ui_time(last_hw_us, last_sw_us);
    snprintf(status, sizeof(status), "signature %d frames   DTW %lu us (%s)", sig.n, (unsigned long)us, use_hw ? "hardware" : "software");
    ui_status(status);
    if (who >= 0) {
        snprintf(line, sizeof(line), "d %lu < tau %lu", (unsigned long)d[who], (unsigned long)people[who].tau);
        ui_banner(BANNER_OK, "IDENTIFIED AS", names[who], line);
    } else {
        if (near < 0) snprintf(line, sizeof(line), "nobody is enrolled yet");
        else if (d[near] >= people[near].tau)
            snprintf(line, sizeof(line), "P%d: d %lu > tau %lu", near + 1, (unsigned long)d[near], (unsigned long)people[near].tau);
        else snprintf(line, sizeof(line), "P%d: second best too close", near + 1);
        ui_banner(BANNER_BAD, "", "NOT ENROLLED", line);
    }
    printf("ID who=%d us=%lu hw=%d d=%lu,%lu,%lu,%lu,%lu\n", who, (unsigned long)us, use_hw,
           (unsigned long)d[0], (unsigned long)d[1], (unsigned long)d[2], (unsigned long)d[3], (unsigned long)d[4]);
    if (who >= 0) {
        snprintf(line, sizeof(line), "d=%lu", (unsigned long)d[who]);
        lcd_show(names[who], line);
        leds(0x1FF, 0);
    } else {
        lcd_show("NOT ENROLLED", "");
        for (i = 0; i < 3; i++) {
            leds(0, 0x3FFFF); usleep(150000);
            leds(0, 0);       usleep(150000);
        }
    }
}

static void do_enroll(int slot)
{
    person *p;
    char line[32];
    if (slot >= MAX_SLOTS) {
        lcd_show("SLOT MAX IS 4", "SET SW[4:2]");
        ui_banner(BANNER_BAD, "", "NO SUCH SLOT", "set SW4-2 to 0..4");
        return;
    }
    p = &people[slot];
    if (p->count == ENROLL_COUNT) p->count = 0;   /* full: start the person again */
    sig_preprocess(&sig, templates[slot][p->count]);
    p->count++;
    templates_changed = 1;
    if (p->count == ENROLL_COUNT) {
        uint32_t pair[ENROLL_COUNT * (ENROLL_COUNT - 1) / 2];
        int i, j, n = 0;
        for (i = 0; i < ENROLL_COUNT; i++)
            for (j = i + 1; j < ENROLL_COUNT; j++)
                pair[n++] = dtw_sw((csig)templates[slot][i], (csig)templates[slot][j]);
        p->tau = enroll_threshold(pair, n);
        printf("ENROLL slot=%d tau=%lu\n", slot, (unsigned long)p->tau);
    }
    snprintf(line, sizeof(line), "%d/%d", p->count, ENROLL_COUNT);
    lcd_show(names[slot], line);
    ui_enroll(slot, p->count, p->tau);
    if (p->count == ENROLL_COUNT) ui_banner(BANNER_OK, "ENROLLED", names[slot], "5 of 5");
    else {
        snprintf(line, sizeof(line), "%d more", ENROLL_COUNT - p->count);
        ui_banner(BANNER_INFO, "SAVED", "SIGN AGAIN", line);
    }
}

/* The middle panel and the banner for the mode on the switches. */
static void show_mode(uint32_t inputs, uint32_t err, int saved, int rejected, int marks)
{
    int mode = inputs & 3, slot = (inputs >> 2) & 7;
    ui_title(mode, (inputs >> 5) & 1, count_ok(err));
    if (mode == 0) ui_match(0, people, -1);
    else if (mode == 1) ui_enroll(slot < MAX_SLOTS ? slot : MAX_SLOTS - 1, slot < MAX_SLOTS ? people[slot].count : 0,
                                  slot < MAX_SLOTS ? people[slot].tau : 0);
    else ui_collect(saved, rejected, marks);
    if (err) {
        char top[12] = "SENSOR 0";
        while (!((err >> (top[7] - '0')) & 1)) top[7]++;     /* first sensor with an error */
        ui_banner(BANNER_BAD, top, "NO ANSWER", "check wiring and address");
    }
    else ui_banner(BANNER_INFO, "", "READY", mode == 2 ? "recording to the PC" : "sign on the paper");
    ui_time(last_hw_us, last_sw_us);
}

int main(void)
{
    uint32_t last_frame = 0, err = 0, prev_keys = 0xF, inputs;
    int32_t base[12], lsb[12], corrected[12], in[12];
    pen_pos pos;
    pen_pos prev_pos;
    int prev_down = 0;
    uint32_t us_mlp = 0, shown_inputs = 0xFFFFFFFF, shown_err = 0xFFFFFFFF;
    int k, n_ok, saved = 0, rejected = 0, marks = 0;
    char line[80];

    memset(&prev_pos, 0, sizeof(prev_pos));

    lcd = fopen("/dev/lcd_0", "w");
    memset(people, 0, sizeof(people));
    sig_reset(&sig);
    ui_frame();
    ui_pen(&prev_pos, 0, 0);

    /* Tell the reader where the sensors are, then restart its init sequence */
    {
        static const uint32_t cfg[4] = SENSOR_CFG;
        for (k = 0; k < 4; k++) IOWR(MLX_READER_0_BASE, MLX_CFG0 + k, cfg[k]);
        IOWR(MLX_READER_0_BASE, MLX_FRAME, 0);
    }

    /* Bring-up report: which sensors answered in the first frames */
    usleep(200000);
    i2c_scan();
    err = MLX(MLX_ERR);
    for (k = 0, n_ok = 0; k < 4; k++) n_ok += !((err >> k) & 1);
    snprintf(line, sizeof(line), "SENSORS OK %d/4", n_ok);
    lcd_show(line, "");
    ui_put(3, 12, line, n_ok == 4 ? C_GREEN : C_RED);
    ui_title(0, 0, n_ok);
    usleep(1000000);
    baseline_measure(&last_frame, base);

    for (;;) {
        uint32_t keys, pressed, t0;
        int mode, ev, lost, uniform, present;
        inputs = read_inputs();
        keys = (inputs >> 18) & 0xF;
        pressed = prev_keys & ~keys;      /* falling edges, keys are active low */
        prev_keys = keys;
        mode = inputs & 3;

        if (pressed & 1) { baseline_measure(&last_frame, base); sig_reset(&sig); shown_inputs = 0xFFFFFFFF; }
        if ((pressed & 4) && mode == 1) {
            int slot = (inputs >> 2) & 7;
            if (slot < MAX_SLOTS && people[slot].count > 0) people[slot].count--;
            templates_changed = 1;
            lcd_show("CANCELLED", "LAST SIGNATURE");
            shown_inputs = 0xFFFFFFFF;
        }
        /* Mode, slot or SW5 changed, or a sensor started or stopped answering: redraw the panel.
         * Not while signing, so the result of a signature stays until the next action. */
        if (!sig.active && ((inputs & 0x3F) != shown_inputs || err != shown_err)) {
            show_mode(inputs, err, saved, rejected, marks);
            shown_inputs = inputs & 0x3F;
            shown_err = err;
        }

        ev = SIG_NONE;
        if (wait_frame(&last_frame, lsb, &err)) {
            uint32_t raw_peak = 0;
            for (k = 0; k < 12; k++) {
                uint32_t a = lsb[k] < 0 ? -lsb[k] : lsb[k];
                if (a > raw_peak) raw_peak = a;
                lsb[k] -= base[k];
            }
            if (inputs & (1u << 7)) show_field_bars(lsb, raw_peak);
            t0 = MLX(MLX_NOW);
            for (k = 0; k < 12; k++) corrected[k] = lsb[k];
            mount_correct(corrected);
            field_to_input(corrected, in);
            mlp_forward(in, &pos);
            uniform = field_is_uniform(corrected);
            if (uniform) pos.z = Z_AWAY;      /* not the pen: do not start or continue a signature */
            us_mlp = MLX(MLX_NOW) - t0;
            lost = err != 0;
            ev = sig_feed(&sig, &pos, lost);
            if (ev == SIG_STARTED) vga_pad_reset();
            if (sig.is_down && prev_down) vga_line(&prev_pos, &pos);
            prev_pos = pos;
            prev_down = sig.is_down;
            {
                /* The pen is "present" when a sensor sees it. Without this the position of
                 * an absent pen (noise through the network) would move the cursor around. */
                uint32_t peak = 0;
                for (k = 0; k < 12; k++) {
                    uint32_t a = lsb[k] < 0 ? -lsb[k] : lsb[k];
                    if (a > peak) peak = a;
                }
                present = peak >= PEN_PRESENT_LSB && !uniform;
                vga_cursor(&pos, present, sig.is_down);
                if (last_frame % 5 == 0) {          /* numbers at 10 Hz: readable, and cheap */
                    ui_pen(&pos, sig.is_down, present);
                    ui_sensors(lsb, err);
                    if (sig.active) {
                        snprintf(line, sizeof(line), "%d.%d s   %d frames", sig.n / 50, sig.n % 50 / 5, sig.n);
                        ui_banner(BANNER_INFO, "", "SIGNING...", line);
                    }
                }
            }
            if (mode == 2) {
                /* Raw values are logged too (before mount_correct): the tracker and
                 * the mount settings can be changed and everything re-computed later. */
                printf("R,%lu,%lu,%lu", (unsigned long)last_frame, (unsigned long)MLX(MLX_TIME), (unsigned long)err);
                for (k = 0; k < 12; k++) printf(",%ld", (long)lsb[k]);
                printf(",%d,%d,%d,%d,%d,%d,%lu\n", pos.x, pos.y, pos.z, pos.ux, pos.uy, sig.is_down, (unsigned long)us_mlp);
            }
        }
        if (pressed & 2) {
            ev = sig_finish(&sig);
            if (mode == 2) {
                printf("MARK\n");   /* pc/gate1.py: the pen is on the next grid point */
                marks++;
                shown_inputs = 0xFFFFFFFF;
            }
        }

        if (ev == SIG_STARTED) {
            lcd_show("SIGNING...", "");
            leds(0, 0);
            if (mode == 0) ui_match(0, people, -1);     /* the bars of the previous result go away */
        } else if (ev == SIG_REJECT) {
            lcd_show("SIGN AGAIN", "");
            ui_banner(BANNER_BAD, "REJECTED", "SIGN AGAIN", "too short or sensor errors");
            rejected++;
            if (mode == 2) { printf("SIG,REJECT\n"); ui_collect(saved, rejected, marks); }
        } else if (ev == SIG_DONE) {
            if (mode == 0) do_identify((inputs >> 5) & 1);
            else if (mode == 1) do_enroll((inputs >> 2) & 7);
            else {
                printf("SIG,DONE,%d\n", sig.n);
                lcd_show("SAVED", "");
                saved++;
                ui_collect(saved, rejected, marks);
                ui_banner(BANNER_OK, "", "SAVED", "sign the next one");
            }
        }
    }
    return 0;
}
