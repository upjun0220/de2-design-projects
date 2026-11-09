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

/* ---- dtw.c ---- */
#define DTW_BIG 0xFFFFFF
uint32_t dtw_sw(const int8_t x[SIG_N][SIG_CH], const int8_t y[SIG_N][SIG_CH]);

/* ---- decide.c ---- */
typedef struct {
    int      count;   /* signatures stored, 0..ENROLL_COUNT */
    uint32_t tau;     /* acceptance threshold, valid when count == ENROLL_COUNT */
} person;

/* tau from the pairwise distances among the enrolled signatures */
uint32_t enroll_threshold(const uint32_t *pairwise, int n);
/* d[k] = distance to person k. Returns the person, or -1 for "not enrolled". */
int decide(const uint32_t *d, const person *people, int n_people);

#endif
