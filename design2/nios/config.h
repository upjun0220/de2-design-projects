/* config.h - values that must be tuned on the real hardware. Keep them all here.
 * Values marked ESTIMATE have not been measured. */
#ifndef CONFIG_H
#define CONFIG_H

#define SIG_N       128   /* samples per signature after resampling */
#define SIG_CH      8     /* x, y, z, vx, vy, ux, uy, pen */
#define MAX_FRAMES  500   /* 10 s at 50 Hz (was 6 s: long signatures ended early) */

/* Pen contact: magnet centre height above the sensor chips, in 0.1 mm.
 * ESTIMATE: 7..10 mm when touching the paper. Measure after assembly. */
#define Z_DOWN      120   /* below this height the pen is down */
#define Z_UP        150   /* above this height the pen is up (hysteresis) */

/* Pen switch (2026-11-18): the estimated height was not reliable enough to tell pen down
 * from pen up, so a board switch marks the signature instead. SW[17] on = signing,
 * off = signature ends. PEN_SWITCH_ONLY 1: the height is never used for pen up/down;
 * 0: with the switch off, the height-based detection below still works. */
#define PEN_SWITCH_BIT  17
#define PEN_SWITCH_ONLY 1

/* With the switch on, pen up = lifted more than LIFT_UP above the contact height z_ref,
 * pen down again = back below LIFT_DOWN (0.1 mm). ESTIMATE: tune while signing.
 * Too small: strokes break while writing. Too large: lifts are drawn. LIFT_UP 0 = always down.
 * Wider values (e.g. 120 / 100) help when the contact height differs a lot across the pad,
 * but then the small lifts of a few mm between strokes are no longer seen: try ZREF_SHIFT first. */
#define LIFT_UP     80
#define LIFT_DOWN   50

/* z_ref = contact height. While the pen is down it follows the height: at once downwards,
 * slowly upwards (1/2^ZREF_SHIFT per frame; 5 = about 0.64 s). This copes with the
 * uncalibrated height being a few mm different at different places on the pad.
 * While the pen is up z_ref stays where it was. ESTIMATE. */
#define ZREF_SHIFT  5

/* Position filter (nios/position.c pf_step, pc/pen_filter.py): per axis a median of 3,
 * then a One Euro filter (Casiez et al., CHI 2012): a low-pass whose cut-off rises with
 * speed, fc = PF_MINCUT + PF_BETA * speed. Units: 0.01 Hz, and 0.01 Hz per mm/s.
 * Simulated (jitter 1.5 mm): still jitter 0.58 mm, lag 2.7 mm at 100 mm/s, against
 * 0.57 mm and 6 mm for the old moving average. ESTIMATE.
 * Shaking when the pen is still: lower PF_MINCUT. Lagging on fast strokes: raise PF_BETA. */
#define PF_MINCUT   100
#define PF_BETA     20
#define PF_DCUT     50
#define PF_CLAMP    4000  /* input range in 0.1 mm, keeps the products within 32 bits */

/* Screen only (not the stored signature): while the pen is down, a new point is drawn only
 * when it is more than ANCHOR_R (0.1 mm) from the last drawn point, so a pen held still
 * draws a dot instead of a scribble. 0 = off. ESTIMATE. */
#define ANCHOR_R    15

/* End of a pen switch signature (signature.c sig_trim_tail). After the last stroke the pen is
 * lifted and the switch turned off; the movement in between would be a tail. The tail is cut
 * when the pen ended more than TRIM_LIFT (0.1 mm) above z_ref without coming back down,
 * searched in the last TRIM_WINDOW frames. Cut point = lowest height before that lift.
 * TRIM_LIFT 0 = off. ESTIMATE: 15 mm, check with data. */
#define TRIM_LIFT   150
#define TRIM_WINDOW 150   /* 3 s */

#define END_UP_FRAMES   50    /* pen up for 1.0 s ends the signature */
#define MIN_DOWN_FRAMES 25    /* less than 0.5 s of pen-down: discard */
#define MAX_LOST_PCT    20    /* more than 20 % of frames with sensor errors: discard */

#define BASELINE_FRAMES 32    /* frames averaged for KEY0 baseline (0.64 s) */

/* Which of the 8 DTW input channels are used, bit 0 = x ... bit 7 = pen. Set after
 * comparing channel sets with pc/evaluate.py. Unused channels become 0. */
#define CHANNEL_MASK 0xFF

/* Identification rule, README section 6.4. ESTIMATE: set from validation data. */
#define ENROLL_COUNT 5        /* signatures per person */
#define MAX_SLOTS    5        /* 25 templates fit the accelerator RAM */
#define TAU_A_Q8     (2*256)  /* a in tau_k = mu_k + a*sigma_k */
#define MARGIN_M     500      /* required gap between best and second best */

/* Screen mapping: this many 0.1 mm per bitmap pixel. 5 means the 192 pixel pad is 96 mm */
#define SCREEN_SCALE 5

/* When the four sensors see nearly the same field vector, it is not the pen: the board
 * was turned in the earth's field, or something far away moved. "Nearly the same" = the
 * differences between the sensors are below this percentage of the field. Simulated: the
 * pen gives 24 % or more, a uniform change of 50 uT or more gives 22 % or less. ESTIMATE.
 * This does not catch a magnet or phone close to the pad: press KEY0 after moving things. */
#define UNIFORM_PCT 20
#define Z_AWAY      3000  /* height reported for "no pen", 300 mm */

/* The pen counts as present when some sensor channel is this far from its baseline.
 * ESTIMATE (40 LSB = 10 uT): set it above the noise seen with the pen away. */
#define PEN_PRESENT_LSB 40

/* I2C of each sensor: (bus << 8) | address. One bus, four addresses needs A0/A1 wired:
 *   { 0x018, 0x019, 0x01A, 0x01B }
 * Four buses need no soldering; all sensors may keep the same address:
 *   { 0x018, 0x118, 0x218, 0x318 }
 * The default address depends on the module: check the scan printed at power up. */
/* Order = board corner: S0 (-x,-y), S1 (-x,+y), S2 (+x,-y), S3 (+x,+y).
 * 2026-11-18: modules swapped on the pad, S0<->S3 and S1<->S2. */
#define SENSOR_CFG { 0x01B, 0x01A, 0x019, 0x018 }

/* How the sensors and the magnet are mounted. pc/gate1.py --find-mount finds these
 * from a measurement. ESTIMATE until then.
 * MOUNT_ROT: quarter turns (counter-clockwise, seen from above) of each sensor
 * module relative to the board axes. FIELD_SIGN: -1 if the magnet is upside down.
 * Z_SIGN: -1 if the sensor's Z axis points the other way from the model's. The datasheet
 * text does not state the axis polarity, so this has to come from a measurement.
 * MIRROR_XY: 1 swaps each sensor's X and Y before the rotation. Rotations and Z_SIGN
 * cannot express a mirror image (X<->Y swapped, or a module mounted face down), so
 * without this flag such a mount can never be matched (2026-11-18: swapping X and Y
 * by hand lowered the error from 72 to 44 mm). Applies to all four sensors. */
#ifdef TEST_MOUNT             /* only for nios/test_host.c */
#define MOUNT_ROT  { 1, 2, 3, 0 }
#define FIELD_SIGN (-1)
#define Z_SIGN     (-1)
#define MIRROR_XY  1
#else
/* 2026-11-19: pc/gate1.py --find-mount on the 140 mm layout, magnet on the pen axis
 * (9-point log bringup_20261119.log, last 9 marks). The opposite Z sign fits equally well
 * but puts the magnet below the sensors (z -3 mm): a flat sensor array cannot tell them apart,
 * so the one above the board was chosen. Ranked on all 9 points (3 points first chose
 * {2,2,2,1}, which fits worse on all 9). Result: xy RMS 11.7 mm, of which a constant
 * offset of (2.3, 11.0) mm; 3.3 mm without the offset. Magnet strength 0.585 A*m^2
 * (0.55..0.62 over the points), magnet centre about 7.7 mm above the sensors.
 * S3 is turned 180 degrees against the other three: check the module on the pad. */
#define MOUNT_ROT  { 2, 2, 2, 0 }
/* 2026-11-20: the chopstick pen has its magnet pole pointing down (fitted uz = -1.0 at all
 * 9 points), the MLP is trained for poles pointing up: flip the field. */
#define FIELD_SIGN (-1)
#define Z_SIGN     1
#define MIRROR_XY  0
#endif

#endif
