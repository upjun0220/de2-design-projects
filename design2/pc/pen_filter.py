"""펜 위치 필터의 Python 기준 구현. nios/position.c의 pf_reset/pf_step과 비트 단위로 같아야 한다.

왜 바꿨나 (2026-11-18 보드에서 본 문제):
  예전 필터는 고정 세기 지수 이동 평균(SMOOTH_SHIFT)이라 덜 튀게 하면 늦게 따라왔다
  (2 → 100 mm/s에서 약 6 mm, 3 → 약 14 mm 뒤처짐).
처리 순서 (축마다 따로, x·y·z):
  1. 3점 중앙값: 한 프레임만 튀는 값을 없앤다. 대가로 1프레임(20 ms) 늦는다(100 mm/s에서 2 mm).
  2. 1€ 필터(One Euro Filter, Casiez·Roussel·Vogel, CHI 2012): 저역 통과 필터의 차단 주파수를
     속도에 따라 바꾼다. fc = PF_MINCUT + PF_BETA × 속도. 멈춰 있으면 fc가 낮아 떨림을 세게 누르고,
     빠르게 그으면 fc가 높아 덜 늦는다. 속도도 잡음이 있어 PF_DCUT으로 따로 거른다.
  1차 저역 통과의 계수: alpha = w / (1 + w), w = 2π·fc·Te, Te = 0.02 s (50 Hz).
정수 형식: 위치 Q4(0.1 mm의 1/16), alpha Q12, 주파수는 0.01 Hz 단위(cHz).
값의 범위: 입력을 ±PF_CLAMP(400 mm)로 자른다 → 위치 차 ≤ 12.8만(Q4), 속도 차 ≤ 25.6만, × alpha < 4096
→ 32비트 안. fc는 50 Hz에서 자른다.

실행: python pc/pen_filter.py --check   합성 신호로 떨림·지연을 재고 예전 필터와 비교(시뮬레이션)
"""
import argparse
import numpy as np

# nios/config.h와 같게 둔다
PF_MINCUT = 100     # cHz: 멈춰 있을 때 차단 주파수 1.0 Hz
PF_BETA = 20        # cHz per (mm/s): 100 mm/s에서 +20 Hz
PF_DCUT = 50        # cHz: 속도를 거르는 차단 주파수 0.5 Hz
FC_MAX = 5000       # cHz: 50 Hz
PF_CLAMP = 4000     # 0.1 mm: 입력 범위(32비트 넘침 방지). 서명 영역은 ±50 mm라 닿지 않는다


def alpha_q12(fc_chz):
    """차단 주파수(cHz) → Q12 계수. w = 2π·0.02·fc, Q12로 1 Hz = 514.7 → 1 cHz = 5.147"""
    w = fc_chz * 5147 // 1000
    return (w << 12) // (4096 + w)


def _shr(v, s):
    """C의 부호 있는 >>(gcc: 산술 시프트, 내림)와 같다. Python >>도 내림이다."""
    return v >> s


class PenFilter:
    """축 3개(x, y, z) 상태. reset 뒤 첫 값은 그대로 나온다."""

    def __init__(self):
        self.valid = False

    def step(self, v):
        """v = (x, y, z) 정수 0.1 mm → 걸러낸 (x, y, z)"""
        v = [max(-PF_CLAMP, min(PF_CLAMP, int(c))) for c in v]
        if not self.valid:
            self.m0, self.m1 = list(v), list(v)
            self.x = [c << 4 for c in v]
            self.dx = [0, 0, 0]
            self.valid = True
            return tuple(v)
        out = []
        ad = alpha_q12(PF_DCUT)
        for k in range(3):
            a, b, c = self.m0[k], self.m1[k], v[k]
            med = max(min(a, b), min(max(a, b), c))
            self.m0[k], self.m1[k] = b, c
            xq = med << 4
            d = xq - self.x[k]
            self.dx[k] += _shr(ad * (d - self.dx[k]), 12)
            speed = abs(self.dx[k]) * 5 // 16                 # Q4 0.1 mm/프레임 → mm/s
            fc = min(PF_MINCUT + PF_BETA * speed, FC_MAX)
            self.x[k] += _shr(alpha_q12(fc) * (xq - self.x[k]), 12)
            out.append(_shr(self.x[k], 4))
        return tuple(out)


def ema(values, shift):
    """예전 필터(nios/main.c SMOOTH_SHIFT)와 같은 계산. 비교용."""
    s = None
    out = []
    for v in values:
        if s is None:
            s = v << 4
        s += _shr((v << 4) - s, shift)
        out.append(_shr(s, 4))
    return np.array(out)


def run_pf(values):
    f = PenFilter()
    return np.array([f.step((int(v), 0, 0))[0] for v in values])


def measure(name, fn, rng, sigma):
    """멈춤 떨림(표준편차)과 100 mm/s 직선 지연, 서명 모양 궤적의 RMS 오차. 단위 mm."""
    still = np.round(rng.normal(0, sigma * 10, 1500)).astype(int)
    jitter = fn(still)[100:].std() / 10
    t = np.arange(350)
    ramp = (t * 20 - 3500).astype(int)                           # 100 mm/s = 2 mm/프레임 = 20 단위, ±350 mm 안
    lag = (ramp - fn(ramp))[100:].mean() / 10
    tt = np.arange(0, 6, 0.02)                                   # 서명처럼: 2~3 Hz로 방향이 바뀌는 곡선
    true = 150 * np.sin(2 * np.pi * 1.3 * tt) + 80 * np.sin(2 * np.pi * 2.9 * tt + 1)
    noisy = np.round(true + rng.normal(0, sigma * 10, len(tt))).astype(int)
    rms = np.sqrt(((fn(noisy) - true)[25:] ** 2).mean()) / 10
    print("  %-22s 멈춤 떨림 %.2f mm   100 mm/s 지연 %5.2f mm   곡선 RMS 오차 %.2f mm" % (name, jitter, lag, rms))
    return jitter, lag, rms


def check():
    rng = np.random.default_rng(7)
    sigma = 1.5
    print("필터 비교 (시뮬레이션, 입력 떨림 σ %.1f mm, 50 Hz)" % sigma)
    raw = measure("필터 없음", lambda v: np.asarray(v), rng, sigma)
    e2 = measure("이동 평균 SHIFT 2", lambda v: ema(v, 2), rng, sigma)
    e3 = measure("이동 평균 SHIFT 3", lambda v: ema(v, 3), rng, sigma)
    pf = measure("중앙값3 + 1€", run_pf, rng, sigma)
    # 같은 신호면 지연은 결정적이다: 예전 값이 설명과 맞는지(SHIFT 2 약 6 mm, 3 약 14 mm)
    assert 5 < e2[1] < 7 and 12 < e3[1] < 16, (e2, e3)
    # 새 필터: 떨림은 SHIFT 2와 비슷하게(5% 이내) 두고, 지연은 절반 이하, 곡선 오차는 더 작아야 한다.
    # 기본값(PF_MINCUT 100, PF_BETA 20, PF_DCUT 50)은 이 조건에서 곡선 오차가 가장 작은 쪽으로 골랐다.
    # 떨림을 더 줄이면 지연이 늘고, 지연을 더 줄이면 떨림이 는다(맞바꿈). 실제 떨림 크기는 보드에서 본다.
    assert pf[0] < e2[0] * 1.05 and pf[1] < e2[1] / 2 and pf[2] < e2[2], (pf, e2)
    # 한 프레임만 튀는 값은 중앙값이 없앤다
    f = PenFilter()
    outs = [f.step((0, 0, 0)) for _ in range(20)] + [f.step((500, 500, 500))] + [f.step((0, 0, 0)) for _ in range(3)]
    assert max(abs(c) for o in outs for c in o) == 0, outs
    assert alpha_q12(0) == 0 and 0 < alpha_q12(100) < alpha_q12(5000) < 4096
    print("pen_filter OK")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.parse_args()
    check()
