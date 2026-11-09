"""게이트 1 측정: 알려진 격자점에 펜을 두고 실제 위치 오차를 잰다. 조립 후 첫날 쓴다.

순서 (데이터 수집 모드 SW[1:0]=10, 펜 없이 KEY0으로 기준값 측정):
 1. python pc/collect.py --participant 0 --role genuine --target 0
 2. 종이에 격자를 그리고, 펜을 수직으로 첫 점에 대고 약 1초 멈춘 뒤 KEY1. 다음 점으로 옮겨 반복.
 3. python pc/gate1.py pc/data/p00_....log --find-mount   맞는 장착 설정(회전, 극성) 찾기
 4. 결과를 nios/config.h의 MOUNT_ROT, FIELD_SIGN에 넣는다.
 5. python pc/gate1.py 같은로그 --rot 0 0 0 0 --sign 1     위치 오차 보고

격자 기본값: 서명 영역 ±3 cm, 3 cm 간격, 왼쪽 아래부터 x가 커지는 쪽으로 줄 단위 (9점).
RMS는 격자 원점을 센서 판 중심에 정확히 맞췄다는 가정의 값이다. 평행이동을 빼고 구한 값도 함께 보고한다.

실행: python pc/gate1.py --check  합성 로그로 자체 검증(실측 아님).
"""
import argparse
import itertools
import numpy as np
import pen_model as pm
from position_lm import raw_to_tesla, fit_frame, STARTS

DWELL = 25   # MARK 직전 프레임 수(0.5 s)를 평균한다


def read_points(lines):
    """MARK마다 직전 DWELL 프레임의 raw 평균을 낸다. 돌려주는 값: K×12"""
    rows, points = [], []
    for line in lines:
        p = line.strip().split(",")
        if p[0] == "R" and len(p) == 23:
            try:
                rows.append([int(v) for v in p[4:16]])
            except ValueError:
                pass
        elif p[0] == "MARK" and len(rows) >= DWELL // 2:
            points.append(np.mean(rows[-DWELL:], axis=0))
            rows = []
    return np.array(points)


def correct(raw, rot, sign):
    """pm.mount_correct와 같은 변환의 실수 배열판"""
    out = np.array(raw, float)
    for k in range(4):
        for _ in range(rot[k]):
            x, y = out[..., 3*k].copy(), out[..., 3*k+1].copy()
            out[..., 3*k], out[..., 3*k+1] = -y, x
    return out * sign


def fit_point(raw, sensors, m0):
    b = raw_to_tesla(raw)
    sols = [fit_frame(b, sensors, m0, np.array([*s, 0.05, 0.05])) for s in STARTS]
    return min(sols, key=lambda r: r.cost)


def find_mount(points, sensors, m0):
    """회전 4^4 × 극성 2를 전부 시험해 잔차가 가장 작은 조합을 찾는다.
    센서별로 독립이 아니라 조합을 봐야 해서 전수조사다. 격자점 3개만 쓴다."""
    use = points[np.linspace(0, len(points) - 1, min(3, len(points))).astype(int)]
    results = []
    for rot in itertools.product(range(4), repeat=4):
        for sign in (1, -1):
            c = sum(fit_point(correct(p, rot, sign), sensors, m0).cost for p in use)
            results.append((c, rot, sign))
    results.sort(key=lambda r: r[0])
    return results[:3]


def grid(half, step):
    v = np.arange(-half, half + 1e-9, step)
    return np.array([(x, y) for y in v for x in v])


def errors(points, truth, rot, sign, sensors, m0):
    est = []
    res = []
    for p in points:
        s = fit_point(correct(p, rot, sign), sensors, m0)
        est.append(s.x)
        res.append(np.sqrt(2 * s.cost / 12))
    est = np.array(est)
    d = est[:, :2] - truth[:len(est)]
    rms = np.sqrt((d**2).sum(1).mean())
    d0 = d - d.mean(0)
    return est, rms, np.sqrt((d0**2).sum(1).mean()), d.mean(0), np.mean(res)


def check():
    """정답을 아는 합성 로그: 일부러 돌려 붙인 장착을 찾아내는지, 오차 계산이 맞는지 본다."""
    rng = np.random.default_rng(4)
    truth = grid(0.03, 0.03)
    true_rot, true_sign = (1, 0, 3, 2), -1
    lines = []
    for x, y in truth:
        pos = np.array([x, y, 0.009])
        b = pm.field(pos, pm.tilt_vec(0.05, -0.05)).reshape(12)
        lsb = pm.lsb_from_tesla(b.reshape(4, 3)).ravel()
        # 보드 축의 값을 센서가 내놓을 값으로 되돌린다(correct의 역변환)
        inv = correct(lsb, [(4 - r) % 4 for r in true_rot], true_sign)
        for f in range(DWELL):
            noise = rng.normal(0, 8, 12)
            lines.append("R,%d,0,0," % f + ",".join(str(int(v + n)) for v, n in zip(inv, noise)) + ",0,0,0,0,0,0,0")
        lines.append("MARK")
    pts = read_points(lines)
    assert len(pts) == 9
    best = find_mount(pts, pm.SENSORS, pm.M0)
    assert best[0][1] == true_rot and best[0][2] == true_sign, best[0]
    _, rms, rms0, _, _ = errors(pts, truth, true_rot, true_sign, pm.SENSORS, pm.M0)
    assert rms < 1.0e-3, rms
    # 파이썬 정수판과 일치하는지
    v = list(range(1, 13))
    assert pm.mount_correct(v, (1, 2, 3, 0), -1) == [int(x) for x in correct(v, (1, 2, 3, 0), -1)]
    assert pm.mount_correct(v, (1, 2, 3, 0), -1) == [2, -1, -3, 4, 5, -6, -8, 7, -9, -10, -11, -12]  # nios/test_host.c
    print("gate1 OK (합성 로그 xy %.2f mm)" % (rms * 1e3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--find-mount", action="store_true")
    ap.add_argument("--rot", type=int, nargs=4, default=[0, 0, 0, 0])
    ap.add_argument("--sign", type=int, default=1)
    ap.add_argument("--half", type=float, default=pm.HALF, help="센서 격자 반폭 [m]")
    ap.add_argument("--m0", type=float, default=pm.M0)
    ap.add_argument("--grid-half", type=float, default=0.03)
    ap.add_argument("--grid-step", type=float, default=0.03)
    a = ap.parse_args()
    if a.check or not a.log:
        return check()
    sensors = np.array([(x, y, 0.0) for x in (-a.half, a.half) for y in (-a.half, a.half)])
    pts = read_points(open(a.log, errors="replace"))
    print("MARK 지점 %d개" % len(pts))
    if a.find_mount:
        for cost, rot, sign in find_mount(pts, sensors, a.m0):
            print("  MOUNT_ROT {%d, %d, %d, %d}  FIELD_SIGN %d  비용 %.1f" % (*rot, sign, cost))
        print("첫 줄이 둘째 줄보다 뚜렷이 작아야 믿을 수 있다.")
        return
    truth = grid(a.grid_half, a.grid_step)
    est, rms, rms0, bias, res = errors(pts, truth, a.rot, a.sign, sensors, a.m0)
    print("실측 xy RMS %.2f mm, 평행이동(%.2f, %.2f mm) 제거 후 %.2f mm, 평균 잔차 %.1f µT" % (
        rms * 1e3, bias[0] * 1e3, bias[1] * 1e3, rms0 * 1e3, res))
    print("z 평균 %.1f mm" % (est[:, 2].mean() * 1e3))
    print("게이트 1 기준(≤10 mm): %s, 게이트 2 기준(≤5 mm): %s" % ("통과" if rms <= 0.01 else "불통과", "통과" if rms <= 0.005 else "불통과"))


if __name__ == "__main__":
    main()
