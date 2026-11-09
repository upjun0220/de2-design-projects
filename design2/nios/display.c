/* display.c - maps the pen position to the 320x240 VGA buffer. Board y grows up,
 * screen y grows down. Positions off the screen are held at the edge.
 * Check: nios/test_host.c. */
#include "core.h"

static int clamp(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

void screen_xy(const pen_pos *p, int *sx, int *sy)
{
    *sx = clamp(160 + p->x / SCREEN_SCALE, 0, 319);
    *sy = clamp(120 - p->y / SCREEN_SCALE, 0, 239);
}
