/* display.c - maps the pen position to the 192x192 pad bitmap. Board y grows up,
 * screen y grows down. Positions off the pad are held at the edge.
 * Check: nios/test_host.c. */
#include "core.h"

static int clamp(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

void screen_xy(const pen_pos *p, int *sx, int *sy)
{
    *sx = clamp(96 + p->x / SCREEN_SCALE, 0, 191);
    *sy = clamp(96 - p->y / SCREEN_SCALE, 0, 191);
}
