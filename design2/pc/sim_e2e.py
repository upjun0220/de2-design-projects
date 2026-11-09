"""전체 경로 시뮬레이션: 자기장 → 센서 정수값 → MLP → 서명 분할 → 전처리 → DTW → 판정.

목적은 모듈을 이었을 때만 드러나는 설계 문제(펜 내림 판정 흔들림, 문턱 값 범위 등)를 찾는 것이다.
가상 서명은 사람 습관을 흉내 낸 임의의 곡선이므로 **아래 수치는 실제 사람의 식별률이 아니다.**

실행: python pc/sim_e2e.py [--people 5] [--tests 8] [--noise 3] [--lm]
      python pc/sim_e2e.py --check    파이프라인이 끊기지 않는지 짧게 검증
"""
import argparse
import os
import re
import sys
import numpy as np
import pen_model as pm
import preprocess as pp

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hw"))
from dtw_ref import dtw_fast

FS = 50.0
CONTACT_Z = 0.009    # 펜이 종이에 닿았을 때 자석 중심 높이 (조립 후 실측값으로 바꿀 것)


def load_weights():
    here = os.path.dirname(os.path.abspath(__file__))
    txt = open(os.path.join(here, "..", "nios", "mlp_weights.h")).read()
    layers = []
    for i in range(3):
        W = re.search(r"mlp_w%d\[\d+\]\[\d+\] = \{(.*?)\n\};" % i, txt, re.S).group(1)
        W = np.array([[int(v) for v in r.split(",")] for r in re.findall(r"\{([^{}]*)\}", W)], dtype=np.int64)
        b = np.array([int(v) for v in re.search(r"mlp_b%d\[\d+\] = \{([^}]*)\}" % i, txt).group(1).split(",")], dtype=np.int64)
        layers.append((W, b))
    return layers


def mlp_batch(layers, x):
    """pm.mlp_forward_int의 배열판. 시뮬레이션 속도용이고 값은 같다(check에서 비교)."""
    a = x
    for li, (W, b) in enumerate(layers):
        s = a @ W.T + b
        a = (s >> 4) if li == len(layers) - 1 else np.clip(s >> 10, 0, 4095)
    return a


class Person:
    """사람마다 다른 모양·속도·기울기 습관"""
    def __init__(self, rng):
        self.fx = rng.uniform(0.6, 2.5, 3)
        self.fy = rng.uniform(0.6, 2.5, 3)
        self.ax = rng.dirichlet([2, 2, 2]) * 0.03
        self.ay = rng.dirichlet([2, 2, 2]) * 0.02
        self.ph = rng.uniform(0, 2*np.pi, 6)
        self.T = rng.uniform(2.0, 4.0)
        self.tilt = rng.uniform(np.deg2rad(20), np.deg2rad(45))
        self.dir = rng.uniform(0, 2*np.pi)
        self.lifts = np.sort(rng.uniform(0.15, 0.85, rng.integers(1, 4)))


def signature(person, rng, shape_jitter, time_jitter, habit=None):
    """펜 궤적 하나. habit: 위조자의 기울기·속도 습관(모양은 person, 동적 습관은 위조자)."""
    h = habit or person
    T = h.T * (1 + rng.normal(0, time_jitter))
    n = int(T * FS)
    u = np.linspace(0, 1, n)
    warp = u + time_jitter * 0.5 * np.sin(2*np.pi*u*rng.uniform(1, 2) + rng.uniform(0, 6)) / (2*np.pi)
    tw = warp * person.T
    def curve(a, f, ph):
        return sum(a[k] * (1 + rng.normal(0, shape_jitter)) * np.sin(2*np.pi*f[k]*tw + ph[k]) for k in range(3))
    x = curve(person.ax, person.fx, person.ph[:3])
    y = curve(person.ay, person.fy, person.ph[3:])
    z = np.full(n, CONTACT_Z + rng.normal(0, 3e-4))
    for l in person.lifts:          # 획 사이에 펜을 든다
        c = int(l * n)
        z[c: c + 8] += 0.012 * np.hanning(min(8, n - c))
    th = h.tilt + 0.05*np.sin(2*np.pi*0.5*u + rng.uniform(0, 6)) + rng.normal(0, 0.03)
    ph = h.dir + 0.1*np.sin(2*np.pi*0.3*u) + rng.normal(0, 0.05)
    ux, uy = np.sin(th)*np.cos(ph), np.sin(th)*np.sin(ph)
    tail = int(1.2 * FS)            # 끝나고 펜을 들어 치운다 (1 s 이상)
    x = np.r_[x, np.full(tail, x[-1])]
    y = np.r_[y, np.full(tail, y[-1])]
    z = np.r_[z, np.linspace(z[-1] + 0.01, 0.05, tail)]
    ux = np.r_[ux, np.full(tail, ux[-1])]
    uy = np.r_[uy, np.full(tail, uy[-1])]
    return np.stack([x, y, z], 1), ux, uy


def to_lsb(pos, ux, uy, rng, sigma, sensors, gain):
    b = pm.field(pos, pm.tilt_vec(ux, uy), pm.M0, sensors) * gain + rng.normal(0, sigma, (len(pos), 4, 3))
    return np.round(pm.lsb_from_tesla(b).reshape(len(pos), 12)).astype(np.int64)


def input_batch(lsb):
    return np.array([pm.input_from_lsb(row) for row in lsb.tolist()], dtype=np.int64)


def track_mlp(layers, lsb):
    o = mlp_batch(layers, input_batch(lsb))
    return np.stack([(o[:, 0]*500) >> 12, (o[:, 1]*500) >> 12, (o[:, 2]*500) >> 12, o[:, 3] >> 4, o[:, 4] >> 4], 1)


class Bench:
    def __init__(self, sigma, rng):
        self.rng = rng
        self.sigma = sigma
        self.layers = load_weights()
        self.sensors = pm.SENSORS + rng.normal(0, 1e-3, pm.SENSORS.shape)   # 조립 오차 1 mm
        self.gain = 1 + rng.normal(0, 0.02, (4, 1))                         # 이득 오차 2 %
        self.flips = []

    def capture(self, person, shape_jitter=0.03, time_jitter=0.03, habit=None):
        """서명 하나를 끝까지 처리. 분할 실패면 None."""
        pos, ux, uy = signature(person, self.rng, shape_jitter, time_jitter, habit)
        lsb = to_lsb(pos, ux, uy, self.rng, self.sigma, self.sensors, self.gain)
        est = track_mlp(self.layers, lsb)
        stream = [tuple(int(v) for v in row) + (0,) for row in est]
        sigs = pp.segment(stream)
        if len(sigs) != 1:
            self.flips.append(len(sigs))
            return None
        frames, pen = sigs[0]
        return np.array(pp.preprocess(frames, pen), dtype=np.int8)


def enroll_threshold(pair, a):
    """nios/decide.c와 같은 뜻의 실수판(문턱 탐색용)"""
    return np.mean(pair) + a * np.std(pair)


def run(args):
    rng = np.random.default_rng(args.seed)
    bench = Bench(args.noise * 1e-6, rng)
    people = [Person(rng) for _ in range(args.people)]
    outsiders = [Person(rng) for _ in range(args.people)]
    templates, tau, fails = [], [], 0
    for p in people:
        t = []
        while len(t) < 5:
            s = bench.capture(p)
            if s is None:
                fails += 1
            else:
                t.append(s)
        pair = [dtw_fast(t[i], t[j]) for i in range(5) for j in range(i + 1, 5)]
        templates.append(t)
        tau.append(enroll_threshold(pair, 2.0))

    def score(sig):
        return np.array([min(dtw_fast(sig, t) for t in templates[k]) for k in range(len(templates))])

    def decide(d):
        order = np.argsort(d)
        if d[order[0]] >= tau[order[0]]:
            return -1
        if len(d) > 1 and d[order[1]] - d[order[0]] < 500:
            return -1
        return int(order[0])

    res = {"genuine": [0, 0, 0], "random": [0, 0], "static": [0, 0], "dynamic": [0, 0]}
    for k, p in enumerate(people):
        for _ in range(args.tests):
            s = bench.capture(p)
            if s is None:
                fails += 1
                continue
            who = decide(score(s))
            res["genuine"][0] += 1
            res["genuine"][1] += who == k
            res["genuine"][2] += who == -1
            for role, sig in (("random", bench.capture(outsiders[k])),
                              ("static", bench.capture(p, 0.08, 0.12, habit=outsiders[k])),
                              ("dynamic", bench.capture(p, 0.06, 0.05))):
                if sig is None:
                    fails += 1
                    continue
                res[role][0] += 1
                res[role][1] += decide(score(sig)) == k if role != "random" else decide(score(sig)) != -1
    return res, tau, fails, bench


def check():
    rng = np.random.default_rng(1)
    layers = load_weights()
    # 배열판 MLP가 기준 구현과 같은지
    lsb = rng.integers(-3000, 3000, (20, 12))
    x = input_batch(lsb)
    py = np.array([pm.mlp_forward_int([(W.tolist(), b.tolist()) for W, b in layers], row)[0] for row in x.tolist()])
    assert (py == mlp_batch(layers, x)).all()
    args = argparse.Namespace(people=2, tests=1, noise=3.0, seed=1)
    res, tau, fails, _ = run(args)
    assert res["genuine"][0] > 0, "서명이 하나도 분할되지 않음"
    print("sim_e2e OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--people", type=int, default=5)
    ap.add_argument("--tests", type=int, default=8)
    ap.add_argument("--noise", type=float, default=3.0, help="축당 노이즈 [µT]")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if args.check:
        return check()
    res, tau, fails, bench = run(args)
    g = res["genuine"]
    print("[가상 서명, 시뮬레이션. 실제 사람 식별률이 아니다]")
    print("분할 실패 %d회 (한 서명이 여러 조각으로 잘린 경우 포함, 조각 수 %s)" % (fails, sorted(set(bench.flips))))
    print("본인: %d회 중 정답 %d, 미등록 판정 %d" % (g[0], g[1], g[2]))
    for role in ("random", "static", "dynamic"):
        r = res[role]
        print("%s 위조: %d회 중 통과 %d" % (role, r[0], r[1]))
    print("tau 평균 %.0f, 범위 %.0f~%.0f" % (np.mean(tau), np.min(tau), np.max(tau)))


if __name__ == "__main__":
    main()
