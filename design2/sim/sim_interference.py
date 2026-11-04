import numpy as np
from scipy.optimize import least_squares

rng = np.random.default_rng(1)
MU = 1e-7
M0 = 0.55            # A*m^2 (8x10mm N52 cylinder, estimate)
WRITE = 0.05
ZMIN, ZMAX = 0.03, 0.08
SIGMA = 3.0          # uT sensor noise
RSCALE = 0.06        # reference distance for gradient amplitude (m)

def grid(n, half):
    xs = np.linspace(-half, half, n)
    return np.array([(x, y, 0.0) for x in xs for y in xs])

LAYOUTS = {"4개 (±3cm)": grid(2, 0.03), "9개 (±6cm)": grid(3, 0.06)}

def dir_vec(theta, phi):
    return np.array([np.sin(theta)*np.cos(phi), np.sin(theta)*np.sin(phi), np.cos(theta)])

def field(S, pos, mvec):
    r = S - pos
    d = np.linalg.norm(r, axis=1, keepdims=True)
    rh = r / d
    return MU * (3 * (rh @ mvec)[:, None] * rh - mvec) / d**3

def rand_unit():
    v = rng.normal(size=3)
    return v / np.linalg.norm(v)

def gradtensor(a, b, d, e, f):
    # symmetric, traceless (static, source-free field gradient)
    return np.array([[a, d, e], [d, b, f], [e, f, -a - b]])

def make_interference(S, b0_uT, g_uT):
    b0 = rand_unit() * b0_uT * 1e-6
    G = gradtensor(*rng.normal(size=5))
    if g_uT > 0:
        G = G * (g_uT * 1e-6) / (RSCALE * np.linalg.norm(G, 2))
    else:
        G = G * 0.0
    return b0 + S @ G.T

def run(S, b0_uT, g_uT, nuis, npts=100):
    errs = []
    for _ in range(npts):
        p = np.array([rng.uniform(-WRITE, WRITE), rng.uniform(-WRITE, WRITE), rng.uniform(ZMIN, ZMAX)])
        th, ph = np.deg2rad(rng.uniform(0, 20)), rng.uniform(0, 2*np.pi)
        m = M0 * dir_vec(th, ph)
        meas = field(S, p, m) + make_interference(S, b0_uT, g_uT) + rng.normal(0, SIGMA*1e-6, (len(S), 3))

        def f(q):
            out = field(S, q[:3], M0*dir_vec(q[3], q[4]))
            if nuis >= 1:
                out = out + q[5:8] * 1e-6
            if nuis >= 2:
                G = gradtensor(*q[8:13]) * 1e-6 / RSCALE
                out = out + S @ G.T
            return (out - meas).ravel() * 1e6

        best = None
        for start in [(0, 0, 0.055), (-0.04, -0.04, 0.04), (0.04, 0.04, 0.07), (0.04, -0.04, 0.05)]:
            x0 = np.array([*start, 0.1, 0.1] + [0.0] * (3 if nuis >= 1 else 0) + [0.0] * (5 if nuis >= 2 else 0))
            try:
                sol = least_squares(f, x0, method="lm", max_nfev=300)
            except Exception:
                continue
            if best is None or sol.cost < best.cost:
                best = sol
        q = best.x
        errs.append(np.hypot(q[0]-p[0], q[1]-p[1]) * 1e3)
    e = np.array(errs)
    return np.sqrt(np.mean(e**2)), np.percentile(e, 90)

SCEN = [("간섭 없음", 0, 0),
        ("균일 잔여장 5µT", 5, 0),
        ("균일 잔여장 20µT", 20, 0),
        ("균일 5µT + 기울기장 5µT", 5, 5),
        ("균일 20µT + 기울기장 20µT", 20, 20)]
MITIG = [(0, "무시"), (1, "균일장 보정"), (2, "균일+기울기장 보정")]

print("xy RMS / p90 (mm), 잡음 3µT, 펜 기울기 ≤20° 5자유도 피팅")
for sname, b0, g in SCEN:
    print(f"\n### {sname}")
    for lname, S in LAYOUTS.items():
        row = []
        for nuis, mname in MITIG:
            # gradient nuisance needs more measurements than unknowns: 4 sensors -> 12 meas vs 13 unknowns
            if nuis == 2 and len(S) == 4:
                row.append(f"{mname}: 불가(미지수 13 > 측정 12)")
                continue
            a, b = run(S, b0, g, nuis)
            row.append(f"{mname}: {a:5.1f}/{b:5.1f}")
        print(f"  {lname:10s} | " + " | ".join(row))
