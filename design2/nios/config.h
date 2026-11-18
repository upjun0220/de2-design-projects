/* config.h - values that must be tuned on the real hardware. Keep them all here.
 * Values marked ESTIMATE have not been measured. */
#ifndef CONFIG_H
#define CONFIG_H

#define SIG_N       128   /* samples per signature after resampling */
#define SIG_CH      8     /* x, y, z, vx, vy, ux, uy, pen */
#define MAX_FRAMES  300   /* 6 s at 50 Hz */

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

/* With the switch on, pen up = lifted more than LIFT_UP above the lowest height of this
 * signature, pen down again = back below LIFT_DOWN (0.1 mm). ESTIMATE: tune while signing.
 * Too small: strokes break while writing. Too large: lifts are drawn. LIFT_UP 0 = always down. */
#define LIFT_UP     80
#define LIFT_DOWN   50

/* Position smoothing: new frame weight 1/2^SMOOTH_SHIFT. 2 = 1/4: about 0.1 s lag at 50 Hz.
 * 0 = off. Larger is smoother and slower. */
#define SMOOTH_SHIFT 2

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
/* 2026-11-18: best of pc/gate1.py --find-mount on the 140 mm layout with the side magnet.
 * NOT a pass: xy error was still about 72 mm. Recheck after the next 9-point measurement. */
#define MOUNT_ROT  { 0, 2, 2, 0 }
#define FIELD_SIGN 1
#define Z_SIGN     1
#define MIRROR_XY  0
#endif

#endif
