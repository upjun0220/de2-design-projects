import numpy as np
from scipy.optimize import differential_evolution, least_squares

MU = 1e-7
M0 = 0.55
SIGMA = 3e-6          # 3 uT
WRITE = 0.05
ZMIN, ZMAX = 0.03, 0.08
BOUND = 0.09          # sensors may be placed within +-9 cm (board size)
MIN_SEP = 0.02        # module size ~2 cm
rng = np.random.default_rng(0)

def dir_vec(th, ph):
    return np.array([np.sin(th)*np.cos(ph), np.sin(th)*np.sin(ph), np.cos(th)])

def field(S, pos, mvec):
    r = S - pos
    d = np.linalg.norm(r, axis=1, keepdims=True)
    rh = r / d
    return MU * (3 * (rh @ mvec)[:, None] * rh - mvec) / d**3

def model(S, q):
    return field(S, q[:3], M0 * dir_vec(q[3], q[4])).ravel()

# fixed workspace samples for CRLB
NP = 150
PTS = []
for _ in range(NP):
    PTS.append([rng.uniform(-WRITE, WRITE), rng.uniform(-WRITE, WRITE), rng.uniform(ZMIN, ZMAX),
                np.deg2rad(rng.uniform(0, 20)), rng.uniform(0, 2*np.pi)])
PTS = np.array(PTS)

def crlb_xy(S):
    out = []
    for q in PTS:
        J = np.zeros((len(S)*3, 5))
        for k in range(5):
            h = 1e-5 if k < 3 else 1e-4
            dq = np.zeros(5); dq[k] = h
            J[:, k] = (model(S, q + dq) - model(S, q - dq)) / (2*h)
        F = J.T @ J / SIGMA**2
        try:
            C = np.linalg.inv(F + 1e-9*np.eye(5))
            sd = np.sqrt(max(C[0, 0] + C[1, 1], 0))
        except np.linalg.LinAlgError:
            sd = 0.05
        out.append(min(sd, 0.05))
    return np.array(out)

def objective(x, n):
    S = np.zeros((n, 3))
    S[:, :2] = x.reshape(n, 2)
    # min separation penalty
    pen = 0.0
    for i in range(n):
        for j in range(i+1, n):
            d = np.linalg.norm(S[i, :2] - S[j, :2])
            if d < MIN_SEP:
                pen += (MIN_SEP - d) * 50
    e = crlb_xy(S)
    return np.sqrt(np.mean(e**2)) * 1e3 + pen   # mm

def grid(nx, half):
    xs = np.linspace(-half, half, nx)
    return np.array([(x, y, 0.0) for x in xs for y in xs])

def mc(S, sigma_uT=3.0, calib=False, npts=150, seed=1):
    r = np.random.default_rng(seed)
    S_true = S.copy(); gains = np.ones((len(S), 1))
    if calib:
        S_true = S + r.normal(0, 1e-3, S.shape)
        gains = 1 + r.normal(0, 0.02, (len(S), 1))
    errs = []
    for _ in range(npts):
        p = np.array([r.uniform(-WRITE, WRITE), r.uniform(-WRITE, WRITE), r.uniform(ZMIN, ZMAX)])
        th, ph = np.deg2rad(r.uniform(0, 20)), r.uniform(0, 2*np.pi)
        meas = field(S_true, p, M0*dir_vec(th, ph)) * gains + r.normal(0, sigma_uT*1e-6, (len(S), 3))
        best = None
        for st in [(0, 0, 0.055), (-0.04, -0.04, 0.04), (0.04, 0.04, 0.07), (0.04, -0.04, 0.05)]:
            x0 = np.array([*st, 0.1, 0.1])
            f = lambda q: (field(S, q[:3], M0*dir_vec(q[3], q[4])) - meas).ravel() * 1e6
            try:
                sol = least_squares(f, x0, method="lm", max_nfev=200)
            except Exception:
                continue
            if best is None or sol.cost < best.cost:
                best = sol
        errs.append(np.hypot(best.x[0]-p[0], best.x[1]-p[1]) * 1e3)
    e = np.array(errs)
    return np.sqrt(np.mean(e**2)), np.percentile(e, 90)

if __name__ == "__main__":
    base = {"4개 2x2 ±3cm": grid(2, 0.03), "4개 2x2 ±6cm": grid(2, 0.06), "9개 3x3 ±6cm": grid(3, 0.06)}
    for k, S in base.items():
        print(f"CRLB xy RMS {k}: {np.sqrt(np.mean(crlb_xy(S)**2))*1e3:.2f} mm", flush=True)

    best_layouts = {}
    for n in (4, 5):
        res = differential_evolution(objective, [(-BOUND, BOUND)]*(2*n), args=(n,), maxiter=60, popsize=10,
                                     seed=3, tol=1e-6, polish=False, workers=1)
        S = np.zeros((n, 3)); S[:, :2] = res.x.reshape(n, 2)
        best_layouts[f"AI 최적 {n}개"] = S
        print(f"DE {n}: CRLB xy RMS {res.fun:.2f} mm; positions (cm):", np.round(S[:, :2]*100, 1).tolist(), flush=True)

    allL = {**base, **best_layouts}
    print("\nLM Monte Carlo (150 pts, 3uT, 5DoF) xy RMS / p90 mm: ideal | calib error")
    for k, S in allL.items():
        a = mc(S); b = mc(S, calib=True)
        print(f"{k:14s}: {a[0]:5.2f}/{a[1]:5.2f} | {b[0]:5.2f}/{b[1]:5.2f}", flush=True)
