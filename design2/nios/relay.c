/* relay.c - sends what the monitor shows to the laptop over the JTAG UART, so the
 * laptop (pc/screen.py) can show the same screen without a VGA monitor. The board
 * still decides everything on the screen; the laptop only draws what it is told.
 *
 * Lines start with '@' so log tools (pc/parse_log.py, pc/gate1.py) skip them:
 *   @T row col HHHH...   text cells of one row from col on; 4 hex digits per cell =
 *                        attribute (2) then character (2), the same 16 bits as hdl/vga_ui.v
 *   @K                   clear the pad bitmap
 *   @L x0 y0 x1 y1       line on the pad bitmap (192 x 192)
 *   @P on colour x y     pen cursor
 *
 * Text is sent only where it changed: ui_cell() records it, relay_flush() sends one
 * line per changed row. relay_refresh_row() resends one whole row now and then, so a
 * laptop that connects late fills its screen within a few seconds.
 * Check: nios/test_host.c encodes a screen, pc/screen.py --check decodes it.
 */
#include <string.h>
#include "core.h"

static uint16_t shadow[UI_ROWS][UI_COLS];
static int8_t   lo[UI_ROWS], hi[UI_ROWS];       /* changed columns of each row; lo > hi: none */
static int      refresh_row;
static uint32_t last_cursor = 0xFFFFFFFF;

static const char HEX[] = "0123456789ABCDEF";

/* Small number to text. Faster and smaller than printf on the Nios II. */
static char *put_dec(char *p, int v)
{
    char tmp[6];
    int n = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { tmp[n++] = (char)('0' + v % 10); v /= 10; } while (v && n < 6);
    while (n) *p++ = tmp[--n];
    return p;
}

void relay_init(void)
{
    int r;
    memset(shadow, 0, sizeof(shadow));        /* character 0 is never written, so all cells count as new */
    for (r = 0; r < UI_ROWS; r++) { lo[r] = UI_COLS; hi[r] = -1; }
    last_cursor = 0xFFFFFFFF;
}

void relay_cell(int col, int row, uint8_t ch, uint8_t attr)
{
    uint16_t v = (uint16_t)(attr << 8 | ch);
    if (shadow[row][col] == v) return;
    shadow[row][col] = v;
    if (col < lo[row]) lo[row] = (int8_t)col;
    if (col > hi[row]) hi[row] = (int8_t)col;
}

void relay_flush(void)
{
    char buf[16 + 4 * UI_COLS];
    int r, c;
    for (r = 0; r < UI_ROWS; r++) {
        char *p = buf;
        if (lo[r] > hi[r]) continue;
        *p++ = '@'; *p++ = 'T'; *p++ = ' ';
        p = put_dec(p, r); *p++ = ' ';
        p = put_dec(p, lo[r]); *p++ = ' ';
        for (c = lo[r]; c <= hi[r]; c++) {
            uint16_t v = shadow[r][c];
            *p++ = HEX[v >> 12]; *p++ = HEX[(v >> 8) & 15]; *p++ = HEX[(v >> 4) & 15]; *p++ = HEX[v & 15];
        }
        *p++ = '\n'; *p = 0;
        relay_out(buf);
        lo[r] = UI_COLS; hi[r] = -1;
    }
}

void relay_refresh_row(void)
{
    int r = refresh_row;
    refresh_row = (refresh_row + 1) % UI_ROWS;
    if (shadow[r][0] == 0) return;            /* row never written yet */
    lo[r] = 0;
    hi[r] = UI_COLS - 1;
}

void relay_clear(void)
{
    relay_out("@K\n");
}

void relay_line(int x0, int y0, int x1, int y1)
{
    char buf[40], *p = buf;
    *p++ = '@'; *p++ = 'L'; *p++ = ' ';
    p = put_dec(p, x0); *p++ = ' ';
    p = put_dec(p, y0); *p++ = ' ';
    p = put_dec(p, x1); *p++ = ' ';
    p = put_dec(p, y1); *p++ = '\n'; *p = 0;
    relay_out(buf);
}

void relay_cursor(int on, int colour, int x, int y)
{
    char buf[40], *p = buf;
    uint32_t key = (uint32_t)(on != 0) << 31 | (uint32_t)colour << 24 | (uint32_t)y << 12 | (uint32_t)x;
    if (key == last_cursor) return;
    last_cursor = key;
    *p++ = '@'; *p++ = 'P'; *p++ = ' ';
    p = put_dec(p, on != 0); *p++ = ' ';
    p = put_dec(p, colour); *p++ = ' ';
    p = put_dec(p, x); *p++ = ' ';
    p = put_dec(p, y); *p++ = '\n'; *p = 0;
    relay_out(buf);
}
