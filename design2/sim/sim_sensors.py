import numpy as np
from scipy.optimize import least_squares

rng = np.random.default_rng(0)
MU = 1e-7            # mu0/4pi
M0 = 0.55            # A*m^2, ~8x10mm N52 cylinder (estimate)
WRITE = 0.05         # writing area half-width (m): 10x10 cm
ZMIN, ZMAX = 0.03, 0.08   # magnet height above sensor plane (m)

def grid(n, half):
    xs = np.linspace(-half, half, n)
    return np.array([(x, y, 0.0) for x in xs for y in xs])

LAYOUTS = {
    "4개 (±6cm)": grid(2, 0.06),
    "4개 (±3cm)": grid(2, 0.03),
    "9개 (±6cm)": grid(3, 0.06),
    "16개 (±6cm)": grid(4, 0.06),
}

def dir_vec(theta, phi):
    return np.array([np.sin(theta)*np.cos(phi), np.sin(theta)*np.sin(phi), np.cos(theta)])

def field(sensors, pos, mvec):
    r = sensors - pos
    d = np.linalg.norm(r, axis=1, keepdims=True)
    rh = r / d
    return MU * (3 * (rh @ mvec)[:, None] * rh - mvec) / d**3   # Tesla, shape (N,3)

def run(layout, mode, sigma_uT, calib_err, npts=150):
    S_true = layout.copy()
    N = len(S_true)
    if calib_err:
        S_used = S_true.copy()   # model assumes nominal positions
        S_true = S_true + rng.normal(0, 1e-3, S_true.shape)   # 1 mm placement error
        gains = 1 + rng.normal(0, 0.02, (N, 1))               # 2% gain error
    else:
        S_used = S_true
        gains = np.ones((N, 1))
    errs_xy, errs_z = [], []
    for _ in range(npts):
        p = np.array([rng.uniform(-WRITE, WRITE), rng.uniform(-WRITE, WRITE), rng.uniform(ZMIN, ZMAX)])
        if mode == "ideal":
            th, ph = 0.0, 0.0
        else:
            th, ph = np.deg2rad(rng.uniform(0, 20)), rng.uniform(0, 2*np.pi)
        m = M0 * dir_vec(th, ph)
        meas = field(S_true, p, m) * gains + rng.normal(0, sigma_uT*1e-6, (N, 3))
        best = None
        for start in [(0, 0, 0.055), (-0.04, -0.04, 0.04), (0.04, 0.04, 0.07), (0.04, -0.04, 0.05)]:
            if mode == "tilt_5dof":
                x0 = np.array([*start, 0.1, 0.1])
                f = lambda q: (field(S_used, q[:3], M0*dir_vec(q[3], q[4])) - meas).ravel() * 1e6
            else:
                x0 = np.array(start)
                f = lambda q: (field(S_used, q[:3], M0*dir_vec(0, 0)) - meas).ravel() * 1e6
            try:
                sol = least_squares(f, x0, method="lm", max_nfev=200)
            except Exception:
                continue
            if best is None or sol.cost < best.cost:
                best = sol
        q = best.x
        errs_xy.append(np.hypot(q[0]-p[0], q[1]-p[1]) * 1e3)
        errs_z.append(abs(q[2]-p[2]) * 1e3)
    exy, ez = np.array(errs_xy), np.array(errs_z)
    return np.sqrt(np.mean(exy**2)), np.percentile(exy, 90), np.sqrt(np.mean(ez**2))

CONDS = [("잡음 1µT, 교정 이상적", 1, False),
         ("잡음 3µT, 교정 이상적", 3, False),
         ("잡음 6µT, 교정 이상적", 6, False),
         ("잡음 3µT + 교정오차(게인 2%, 위치 1mm)", 3, True)]
MODES = [("ideal", "펜 수직 고정(이상)"),
         ("tilt_3dof", "기울기 ≤20° 무시(3자유도 피팅)"),
         ("tilt_5dof", "기울기 ≤20° 추정(5자유도 피팅)")]

for cname, sig, cal in CONDS:
    print(f"\n### {cname}")
    for mkey, mname in MODES:
        print(f"  [{mname}]  xy RMS / xy p90 / z RMS (mm)")
        for lname, lay in LAYOUTS.items():
            a, b, c = run(lay, mkey, sig, cal)
            print(f"    {lname:12s}: {a:6.1f} / {b:6.1f} / {c:6.1f}")
