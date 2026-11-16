/* core.h - board-independent signal processing. Compiled on the Nios II and,
 * for tests, on the PC (nios/test_host.c). The Python reference in pc/ must give
 * the same bits. */
#ifndef CORE_H
#define CORE_H
#include <stdint.h>
#include "config.h"

/* ---- position.c: 12 sensor channels -> pen position ---- */
typedef struct { int16_t x, y, z, ux, uy; } pen_pos;  /* 0.1 mm, tilt vector in Q8 */

uint32_t icbrt(uint32_t v);
void     mount_correct(int32_t lsb[12]);
int      field_is_uniform(const int32_t lsb[12]);
void     field_to_input(const int32_t lsb[12], int32_t in[12]);
void     mlp_forward(const int32_t in[12], pen_pos *out);

/* ---- signature.c: frame stream -> one signature -> 128x8 int8 ---- */
typedef struct {
    pen_pos p[MAX_FRAMES];
    uint8_t pen[MAX_FRAMES];
    int     n;
    int     active, is_down, up_run, down_total, lost;
} sig_buf;

enum { SIG_NONE = 0, SIG_STARTED, SIG_DONE, SIG_REJECT };

void sig_reset(sig_buf *s);
int  sig_feed(sig_buf *s, const pen_pos *p, int lost);  /* returns SIG_* */
int  sig_finish(sig_buf *s);                            /* KEY1: end now */
void sig_preprocess(const sig_buf *s, int8_t out[SIG_N][SIG_CH]);

/* ---- display.c: pen position (0.1 mm) to the 192x192 bitmap of hdl/vga_ui.v ---- */
void screen_xy(const pen_pos *p, int *sx, int *sy);

/* ---- dtw.c ---- */
#define DTW_BIG 0xFFFFFF
uint32_t dtw_sw(const int8_t x[SIG_N][SIG_CH], const int8_t y[SIG_N][SIG_CH]);

/* ---- decide.c ---- */
typedef struct {
    int      count;   /* signatures stored, 0..ENROLL_COUNT */
    uint32_t tau;     /* acceptance threshold, valid when count == ENROLL_COUNT */
} person;

uint32_t isqrt(uint32_t v);
/* tau from the pairwise distances among the enrolled signatures */
uint32_t enroll_threshold(const uint32_t *pairwise, int n);
/* d[k] = distance to person k. Returns the person, or -1 for "not enrolled". */
int decide(const uint32_t *d, const person *people, int n_people);

/* ---- ui.c: the monitor screen, 80 x 30 character cells (hdl/vga_ui.v) ---- */
#define UI_COLS 80
#define UI_ROWS 30
/* palette indices, same order as the palette in hdl/vga_ui.v */
enum { C_BLACK, C_BG, C_PANEL, C_RULE, C_DIM, C_TEXT, C_WHITE, C_CYAN, C_GREEN, C_DGREEN,
       C_RED, C_DRED, C_AMBER, C_BLUE, C_TITLE, C_TRACK };
enum { BANNER_INFO, BANNER_OK, BANNER_BAD };

/* Supplied by the platform: nios/main.c writes the hardware, the test keeps an array.
 * attr = background << 4 | text colour. */
void ui_cell(int col, int row, uint8_t ch, uint8_t attr);

void ui_frame(void);
void ui_title(int mode, int use_hw, int sensors_ok);
void ui_status(const char *s);
void ui_pen(const pen_pos *p, int down, int present);
void ui_sensors(const int32_t lsb[12], uint32_t err);
void ui_match(const uint32_t *d, const person *people, int best);
void ui_enroll(int slot, int count, uint32_t tau);
void ui_collect(int saved, int rejected, int marks);
void ui_banner(int kind, const char *top, const char *mid, const char *bot);
void ui_time(uint32_t hw_us, uint32_t sw_us);
void ui_put(int col, int row, const char *s, int fg);
void ui_bar(int col, int row, int len, int eighths, int fg);
void ui_pad_clear(void);
int  ui_tilt_deg(int ux, int uy);
int  ui_octant(int ux, int uy);

#endif
