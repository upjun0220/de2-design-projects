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

#define END_UP_FRAMES   50    /* pen up for 1.0 s ends the signature */
#define MIN_DOWN_FRAMES 25    /* less than 0.5 s of pen-down: discard */
#define MAX_LOST_PCT    20    /* more than 20 % of frames with sensor errors: discard */

#define BASELINE_FRAMES 32    /* frames averaged for KEY0 baseline (0.64 s) */

/* Identification rule, README section 6.4. ESTIMATE: set from validation data. */
#define ENROLL_COUNT 5        /* signatures per person */
#define MAX_SLOTS    5        /* 25 templates fit the accelerator RAM */
#define TAU_A_Q8     (2*256)  /* a in tau_k = mu_k + a*sigma_k */
#define MARGIN_M     500      /* required gap between best and second best */

/* How the sensors and the magnet are mounted. pc/gate1.py --find-mount finds these
 * from a measurement. ESTIMATE until then.
 * MOUNT_ROT: quarter turns (counter-clockwise, seen from above) of each sensor
 * module relative to the board axes. FIELD_SIGN: -1 if the magnet is upside down. */
#ifdef TEST_MOUNT             /* only for nios/test_host.c */
#define MOUNT_ROT  { 1, 2, 3, 0 }
#define FIELD_SIGN (-1)
#else
#define MOUNT_ROT  { 0, 0, 0, 0 }
#define FIELD_SIGN 1
#endif

#endif
