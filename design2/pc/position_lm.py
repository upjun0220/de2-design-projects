"""위치 복원 기준선: Levenberg-Marquardt 피팅 (PC, 실수 연산). 게이트 1 오차 측정에 쓴다.

쌍극자 모델로 (x, y, z, ux, uy) 5자유도를 푼다. 첫 프레임은 여러 시작점, 이후는 직전 해에서 시작.
입력은 보드 로그의 raw(기준값을 뺀 LSB). 실제 센서 위치·자석 세기는 --half, --m0로 맞춘다.

실행: python pc/position_lm.py 로그파일    로그의 서명마다 궤적 요약 출력
      python pc/position_lm.py --check     시뮬레이션 자체 검증
"""
import argparse
import numpy as np
from scipy.optimize import least_squares
import pen_model as pm
from parse_log import parse_lines

STARTS = [(0, 0, 0.01), (-0.03, -0.03, 0.01), (0.03, 0.03, 0.01), (0.03, -0.03, 0.01), (-0.03, 0.03, 0.01), (0, 0, 0.05)]


def raw_to_tesla(raw):
    s = np.array([pm.UT_PER_LSB_XY, pm.UT_PER_LSB_XY, pm.UT_PER_LSB_Z] * 4)
    return raw * s * 1e-6


def fit_frame(meas, sensors, m0, start):
    def resid(q):
        return (pm.field(q[:3], pm.tilt_vec(q[3], q[4]), m0, sensors).ravel() - meas) * 1e6
    return least_squares(resid, start, method="lm", max_nfev=100)


def track(raw, sensors=pm.SENSORS, m0=pm.M0):
    """raw N×12 → N×5 (x,y,z [m], ux, uy)와 프레임별 잔차 RMS [µT]"""
    meas = raw_to_tesla(np.asarray(raw, float))
    out, res, q = [], [], None
    for b in meas:
        if q is None:
            sols = [fit_frame(b, sensors, m0, np.array([*s, 0.2, 0.2])) for s in STARTS]
            sol = min(sols, key=lambda r: r.cost)
        else:
            sol = fit_frame(b, sensors, m0, q)
        q = sol.x
        out.append(q.copy())
        res.append(np.sqrt(2 * sol.cost / 12))
    return np.array(out), np.array(res)


def check():
    """이상 조건 궤적을 복원해 본다. 시뮬레이션이고 실측이 아니다."""
    rng = np.random.default_rng(3)
    t = np.arange(0, 3, 0.02)
    p = np.stack([0.03*np.sin(5*t), 0.02*np.sin(8*t + 1), 0.009 + 0.001*np.sin(3*t)], 1)
    ux, uy = 0.5 + 0.1*np.sin(4*t), 0.3*np.cos(2*t)
    b = pm.field(p, pm.tilt_vec(ux, uy)).reshape(len(t), 12) + rng.normal(0, 3e-6, (len(t), 12))
    raw = np.round(b * 1e6 / np.array([pm.UT_PER_LSB_XY, pm.UT_PER_LSB_XY, pm.UT_PER_LSB_Z] * 4))
    est, res = track(raw)
    xy = np.sqrt(((est[:, :2] - p[:, :2])**2).sum(1).mean()) * 1e3
    tilt = np.sqrt(((est[:, 3] - ux)**2 + (est[:, 4] - uy)**2).mean())
    print("position_lm 시뮬레이션: xy %.2f mm, 기울기벡터 %.3f, 잔차 %.1f µT" % (xy, tilt, res.mean()))
    assert xy < 3.0 and tilt < 0.05, (xy, tilt)
    print("position_lm OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--half", type=float, default=pm.HALF)
    ap.add_argument("--m0", type=float, default=pm.M0)
    args = ap.parse_args()
    if args.check or not args.log:
        return check()
    sensors = np.array([(x, y, 0.0) for x in (-args.half, args.half) for y in (-args.half, args.half)])
    sigs, bad = parse_lines(open(args.log, errors="replace"))
    print("서명 %d개, 깨진 줄 %d" % (len(sigs), bad))
    for i, s in enumerate(sigs):
        est, res = track(s["raw"], sensors, args.m0)
        print("서명 %d: 프레임 %d, x %.1f~%.1f mm, y %.1f~%.1f mm, z 평균 %.1f mm, 잔차 평균 %.1f µT, 오류 프레임 %d" % (
            i, len(est), est[:, 0].min()*1e3, est[:, 0].max()*1e3, est[:, 1].min()*1e3, est[:, 1].max()*1e3,
            est[:, 2].mean()*1e3, res.mean(), (s["err"] != 0).sum()))


if __name__ == "__main__":
    main()
