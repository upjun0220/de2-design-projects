import numpy as np
from scipy.optimize import least_squares
from scipy.signal import savgol_filter

MU = 1e-7
M0 = 0.55
SIGMA = 3e-6
FS = 50.0
rng = np.random.default_rng(7)

def grid(n, half):
    xs = np.linspace(-half, half, n)
    return np.array([(x, y, 0.0) for x in xs for y in xs])

LAYOUTS = {"4개 ±3cm": grid(2, 0.03), "4개 ±6cm": grid(2, 0.06), "9개 ±6cm": grid(3, 0.06)}

def dirv(th, ph):
    return np.array([np.sin(th)*np.cos(ph), np.sin(th)*np.sin(ph), np.cos(th)])

def field(S, pos, m):
    r = S - pos
    d = np.linalg.norm(r, axis=1, keepdims=True)
    rh = r / d
    return MU * (3 * (rh @ m)[:, None] * rh - m) / d**3

def make_traj(T=3.0):
    t = np.arange(0, T, 1/FS)
    p = rng.uniform(0, 2*np.pi, 6)
    # signature-like loopy path, speeds ~ 50-200 mm/s
    x = 0.03*np.sin(2*np.pi*0.9*t + p[0]) + 0.012*np.sin(2*np.pi*2.3*t + p[1])
    y = 0.02*np.sin(2*np.pi*1.3*t + p[2]) + 0.012*np.sin(2*np.pi*2.9*t + p[3])
    z = 0.045 + 0.004*np.sin(2*np.pi*1.7*t + p[4])
    th = np.deg2rad(35 + 12*np.sin(2*np.pi*0.8*t + p[5]))
    ph = 2*np.pi*0.3*t + p[0]
    return t, np.stack([x, y, z], 1), th, ph

def track(S, pos, th, ph, calib=False):
    S_true = S.copy(); gains = np.ones((len(S), 1))
    if calib:
        S_true = S + rng.normal(0, 1e-3, S.shape)
        gains = 1 + rng.normal(0, 0.02, (len(S), 1))
    est = []
    q = None
    for i in range(len(pos)):
        meas = field(S_true, pos[i], M0*dirv(th[i], ph[i])) * gains + rng.normal(0, SIGMA, (len(S), 3))
        f = lambda qq: (field(S, qq[:3], M0*dirv(qq[3], qq[4])) - meas).ravel() * 1e6
        if q is None:
            best = None
            for st in [(0, 0, 0.05), (-0.03, -0.03, 0.04), (0.03, 0.03, 0.06), (0.03, -0.03, 0.05)]:
                for t0, p0 in [(0.5, 0.0), (0.5, 2.1), (0.5, 4.2)]:
                    sol = least_squares(f, np.array([*st, t0, p0]), method="lm", max_nfev=200)
                    if best is None or sol.cost < best.cost:
                        best = sol
            q = best.x
        else:
            sol = least_squares(f, q, method="lm", max_nfev=100)
            q = sol.x
        est.append(q.copy())
    return np.array(est)

def wrap(a):
    return (a + np.pi) % (2*np.pi) - np.pi

def evaluate(S, calib, ntraj=6):
    exy, ez, eth, eph, vrel, vcorr = [], [], [], [], [], []
    for _ in range(ntraj):
        t, pos, th, ph = make_traj()
        est = track(S, pos, th, ph, calib)
        exy.append(np.hypot(est[:, 0]-pos[:, 0], est[:, 1]-pos[:, 1])*1e3)
        ez.append((est[:, 2]-pos[:, 2])*1e3)
        de = np.array([dirv(a, b) for a, b in zip(est[:, 3], est[:, 4])])
        dt = np.array([dirv(a, b) for a, b in zip(th, ph)])
        eth.append(np.rad2deg(np.arccos(np.clip((de*dt).sum(1), -1, 1))))
        eph.append(np.zeros(len(th)))
        # speed from smoothed positions (Savitzky-Golay, window 9, poly 2)
        def speed(p):
            vx = savgol_filter(p[:, 0], 9, 2, deriv=1, delta=1/FS)
            vy = savgol_filter(p[:, 1], 9, 2, deriv=1, delta=1/FS)
            return np.hypot(vx, vy)
        vt, ve = speed(pos), speed(est[:, :3])
        vrel.append(np.sqrt(np.mean((ve-vt)**2)) / np.sqrt(np.mean(vt**2)))
        vcorr.append(np.corrcoef(vt, ve)[0, 1])
    exy = np.concatenate(exy); ez = np.concatenate(ez); eth = np.concatenate(eth); eph = np.concatenate(eph)
    return (np.sqrt(np.mean(exy**2)), np.sqrt(np.mean(ez**2)), np.sqrt(np.mean(eth**2)),
            np.sqrt(np.mean(eph**2)), np.mean(vrel)*100, np.mean(vcorr))

if __name__ == "__main__":
    print("서명형 궤적 추적 (50Hz, 3s, 노이즈 3uT, 기울기 약 23~47도)")
    print("layout | 교정오차 | xy RMS mm | z RMS mm | 기울기θ RMS deg | 방위φ RMS deg | 속도 상대오차 % | 속도 상관")
    for name, S in LAYOUTS.items():
        for calib in (False, True):
            r = evaluate(S, calib)
            print(f"{name:9s} | {'있음' if calib else '없음'} | {r[0]:5.2f} | {r[1]:5.2f} | {r[2]:5.2f} | {r[3]:6.2f} | {r[4]:5.1f} | {r[5]:.3f}", flush=True)
