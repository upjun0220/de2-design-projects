"""게이트 1 측정: 알려진 격자점에 펜을 두고 실제 위치 오차를 잰다. 조립 후 첫날 쓴다.

순서 (데이터 수집 모드 SW[1:0]=10, 펜 없이 KEY0으로 기준값 측정):
 1. python pc/collect.py --participant 0 --role genuine --target 0
 2. 종이에 격자를 그리고, 펜을 수직으로 첫 점에 대고 약 1초 멈춘 뒤 KEY1. 다음 점으로 옮겨 반복.
 3. python pc/gate1.py pc/data/p00_....log --find-mount   맞는 장착 설정(회전, 극성) 찾기
 4. 결과를 nios/config.h의 MOUNT_ROT, FIELD_SIGN, Z_SIGN, MIRROR_XY에 넣는다.
 5. python pc/gate1.py 같은로그 --rot 0 0 0 0 --sign 1 --zsign 1 --mirror 0     위치 오차 보고

격자 기본값: 서명 영역 ±3 cm, 3 cm 간격, 왼쪽 아래부터 x가 커지는 쪽으로 줄 단위 (9점).
RMS는 격자 원점을 센서 판 중심에 정확히 맞췄다는 가정의 값이다. 평행이동을 빼고 구한 값도 함께 보고한다.

실행: python pc/gate1.py --check  합성 로그로 자체 검증(실측 아님).
"""
import argparse
import itertools
import numpy as np
import pen_model as pm
from position_lm import raw_to_tesla, fit_best, STARTS

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


correct = pm.mount_apply


def fit_point(raw, sensors, m0, xy=None, free_m=True):
    """격자점 하나를 피팅. xy(그 점의 실제 위치)를 알면 거기서 시작한다(엉뚱한 해에 빠지는 것을 막는다).
    free_m: 자석 세기도 함께 푼다(기본). 실제 세기를 모르는데 고정하면 위치가 크게 틀린다(position_lm.fit_frame 설명).
    피팅된 세기 = m0 × |해의 3~5번째 값| (moment())."""
    b = raw_to_tesla(raw)
    starts = [(xy[0], xy[1], 0.01), (xy[0], xy[1], 0.03)] if xy is not None else STARTS[:3]
    return fit_best(b, sensors, m0, starts, free_m=free_m)


def moment(sol, m0):
    """피팅 해의 자석 세기 [A·m²]"""
    return m0 * np.linalg.norm(sol.x[3:6])


def find_mount(points, sensors, m0, truth=None, free_m=True):
    """회전 4^4 × Z 방향 2 × 거울상 2를 전부 시험해 잔차가 가장 작은 조합을 찾는다. 격자점 3개(첫·가운데·끝)를 쓴다.
    자석 방향을 반구 제한 없이 피팅하므로 FIELD_SIGN(전체 부호)은 방향에 흡수되어 구별되지 않는다 → 1로 고정.
    같은 이유로 (회전 r, Z_SIGN z)와 (네 센서 모두 r+2, -z)는 같은 결과를 낸다. 둘 중 아무거나 써도 된다.
    거울상(MIRROR_XY)은 회전·Z 반전으로 만들 수 없어 따로 시험한다. 그래서 거울상 없던 때보다 시간이 두 배 걸린다.
    센서가 한 평면에 있으면 Z_SIGN만 뒤집은 장착도 "판 아래(z < 0)의 거울 위치 자석"으로 똑같이 맞는다.
    자석은 판 위에 있으므로 어느 점이든 z < 0으로 풀리는 조합은 버린다(2026-11-19 실측에서 비용이 같게 나와 발견)."""
    idx = np.linspace(0, len(points) - 1, min(3, len(points))).astype(int)
    results = []
    for mirror in (0, 1):
        for rot in itertools.product(range(4), repeat=4):
            for zsign in (1, -1):
                sols = [fit_point(correct(points[i], rot, 1, zsign, mirror), sensors, m0,
                                  None if truth is None else truth[i], free_m) for i in idx]
                c = float("inf") if any(s.x[2] < 0 for s in sols) else sum(s.cost for s in sols)
                results.append((c, rot, 1, zsign, mirror))
    results.sort(key=lambda r: r[0])
    # 3점만으로는 센서 하나의 회전 차이가 몇 %밖에 안 날 수 있다(2026-11-19 실측: 525.9 대 553.9, 9점 전체로는
    # 순위가 바뀌었다). 상위 10개를 모든 점으로 다시 채점한다. 비용은 점 수로 나눠 3점 기준과 같은 눈금으로 쓴다.
    rescored = []
    for c, rot, sign, zsign, mirror in results[:10]:
        if c == float("inf"):
            continue
        sols = [fit_point(correct(points[i], rot, 1, zsign, mirror), sensors, m0,
                          None if truth is None else truth[i], free_m) for i in range(len(points))]
        c = float("inf") if any(s.x[2] < 0 for s in sols) else sum(s.cost for s in sols) * len(idx) / len(points)
        rescored.append((c, rot, sign, zsign, mirror))
    rescored.sort(key=lambda r: r[0])
    return rescored[:3]


def same_mount(a, b):
    """(rot, sign, zsign, mirror) 두 개가 피팅 결과상 같은 장착인지(위 find_mount 설명)"""
    # mount_apply: (mirror면 X,Y 교환) 뒤 X,Y는 sign·회전, Z는 sign·zsign. 전체 부호를 뒤집는 것(sign)은 자석 방향에
    # 흡수되고, 네 센서 모두 회전 +2(X,Y 부호 반전)에 zsign 반전을 더해도 전체 부호 반전이다.
    # 거울상인 것과 아닌 것은 어떤 회전·부호로도 같아지지 않는다.
    (ra, _, za, ma), (rb, _, zb, mb) = a, b
    flip = tuple((r + 2) % 4 for r in rb)
    return ma == mb and ((tuple(ra) == tuple(rb) and za == zb) or (tuple(ra) == flip and za == -zb))


def grid(half, step):
    v = np.arange(-half, half + 1e-9, step)
    return np.array([(x, y) for y in v for x in v])


def errors(points, truth, rot, sign, zsign, sensors, m0, mirror=0, free_m=True):
    """돌려주는 값: 추정 해, xy RMS, 평행이동 제거 후 RMS, 평행이동, 평균 잔차 [µT], 점별 자석 세기(free_m일 때)"""
    est = []
    res = []
    mom = []
    for p, t in zip(points, truth):
        s = fit_point(correct(p, rot, sign, zsign, mirror), sensors, m0, t, free_m)
        est.append(s.x)
        res.append(np.sqrt(2 * s.cost / 12))
        mom.append(moment(s, m0) if free_m else m0)
    est = np.array(est)
    d = est[:, :2] - truth[:len(est)]
    rms = np.sqrt((d**2).sum(1).mean())
    d0 = d - d.mean(0)
    return est, rms, np.sqrt((d0**2).sum(1).mean()), d.mean(0), np.mean(res), np.array(mom)


def check():
    """정답을 아는 합성 로그: 일부러 돌려 붙이고 거울상으로 만든 장착을 찾아내는지, 오차 계산이 맞는지 본다.
    자석 세기도 모델 가정(pm.M0)과 다르게 만든다: 세기를 함께 풀어야 맞게 나와야 한다."""
    rng = np.random.default_rng(4)
    truth = grid(0.03, 0.03)
    true_rot, true_sign, true_z, true_m = (1, 0, 3, 2), -1, -1, 1
    true_m0 = round(pm.M0 * 2 / 3, 2)      # 모델 가정과 1.5배 다른 세기
    lines = []
    for x, y in truth:
        pos = np.array([x, y, 0.009])
        b = pm.field(pos, pm.tilt_vec(0.05, -0.05), true_m0).reshape(12)
        lsb = pm.lsb_from_tesla(b.reshape(4, 3)).ravel()
        # 보드 축의 값을 센서가 내놓을 값으로 되돌린다(correct의 역변환: 부호·역회전, 마지막에 거울상)
        inv = correct(correct(lsb, [(4 - r) % 4 for r in true_rot], true_sign, true_z), (0, 0, 0, 0), 1, 1, true_m)
        for f in range(DWELL):
            noise = rng.normal(0, 8, 12)
            lines.append("R,%d,0,0," % f + ",".join(str(int(v + n)) for v, n in zip(inv, noise)) + ",0,0,0,0,0,0,0")
        lines.append("MARK")
    pts = read_points(lines)
    assert len(pts) == 9
    best = find_mount(pts, pm.SENSORS, pm.M0, truth)
    assert same_mount(best[0][1:], (true_rot, true_sign, true_z, true_m)), best[0]
    assert same_mount(((3, 2, 1, 0), 1, 1, 0), ((1, 0, 3, 2), -1, -1, 0))
    assert not same_mount(((3, 2, 1, 0), 1, 1, 0), ((3, 2, 1, 0), 1, 1, 1))
    _, rms, rms0, _, _, mom = errors(pts, truth, true_rot, true_sign, true_z, pm.SENSORS, pm.M0, true_m)
    assert rms < 1.0e-3, rms
    assert abs(np.median(mom) / true_m0 - 1) < 0.03, mom
    # 세기를 0.9로 고정하면 같은 로그에서 위치가 크게 틀린다(세기를 함께 푸는 이유)
    _, rms_fixed, _, _, _, _ = errors(pts, truth, true_rot, true_sign, true_z, pm.SENSORS, pm.M0, true_m, free_m=False)
    assert rms_fixed > 0.01, rms_fixed
    # 파이썬 정수판과 일치하는지
    v = list(range(1, 13))
    for m in (0, 1):
        assert pm.mount_correct(v, (1, 2, 3, 0), -1, -1, m) == [int(x) for x in correct(v, (1, 2, 3, 0), -1, -1, m)]
    assert pm.mount_correct(v, (1, 2, 3, 0), -1, -1) == [2, -1, 3, 4, 5, 6, -8, 7, 9, -10, -11, 12]
    assert pm.mount_correct(v, (1, 2, 3, 0), -1, -1, 1) == [1, -2, 3, 5, 4, 6, -7, 8, 9, -11, -10, 12]  # nios/test_host.c
    print("gate1 OK (합성 로그 xy %.2f mm, 자석 세기 추정 %.3f / 실제 %.2f A·m², 세기 고정 시 xy %.1f mm)" % (
        rms * 1e3, np.median(mom), true_m0, rms_fixed * 1e3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--find-mount", action="store_true")
    ap.add_argument("--rot", type=int, nargs=4, default=[0, 0, 0, 0])
    ap.add_argument("--sign", type=int, default=1)
    ap.add_argument("--zsign", type=int, default=1)
    ap.add_argument("--mirror", type=int, default=0, help="1: 센서 X,Y 교환(config.h MIRROR_XY)")
    ap.add_argument("--half", type=float, default=pm.HALF, help="센서 격자 반폭 [m]")
    ap.add_argument("--m0", type=float, default=pm.M0, help="자석 세기 시작값(--fix-m0이면 고정값) [A·m²]")
    ap.add_argument("--fix-m0", action="store_true", help="자석 세기를 풀지 않고 --m0으로 고정(예전 방식)")
    ap.add_argument("--grid-half", type=float, default=0.03)
    ap.add_argument("--grid-step", type=float, default=0.03)
    ap.add_argument("--from-top", action="store_true", help="위 줄 왼쪽부터 찍은 로그(위 줄 → 가운데 줄 → 아래 줄)")
    a = ap.parse_args()
    if a.check or not a.log:
        return check()
    sensors = np.array([(x, y, 0.0) for x in (-a.half, a.half) for y in (-a.half, a.half)])
    pts = read_points(open(a.log, errors="replace"))
    print("MARK 지점 %d개" % len(pts))
    truth = grid(a.grid_half, a.grid_step)
    if a.from_top:      # 줄 순서만 뒤집어 아래 줄부터인 격자 순서에 맞춘다
        n = int(round(np.sqrt(len(truth))))
        order = [r * n + c for r in reversed(range(n)) for c in range(n)]
        pts = pts[order[:len(pts)]] if len(pts) == len(truth) else pts
    if a.find_mount:
        for cost, rot, sign, zsign, mirror in find_mount(pts, sensors, a.m0, truth, not a.fix_m0):
            print("  MOUNT_ROT {%d, %d, %d, %d}  FIELD_SIGN %d  Z_SIGN %d  MIRROR_XY %d  비용 %.1f" % (*rot, sign, zsign, mirror, cost))
        print("첫 줄이 다른 장착인 줄보다 뚜렷이 작아야 믿을 수 있다. (회전 r, Z_SIGN z)와 (모두 r+2, -z)는 같은 결과다.")
        return
    est, rms, rms0, bias, res, mom = errors(pts, truth, a.rot, a.sign, a.zsign, sensors, a.m0, a.mirror, not a.fix_m0)
    print("실측 xy RMS %.2f mm, 평행이동(%.2f, %.2f mm) 제거 후 %.2f mm, 평균 잔차 %.1f µT" % (
        rms * 1e3, bias[0] * 1e3, bias[1] * 1e3, rms0 * 1e3, res))
    if not a.fix_m0:
        # 점마다 크게 다르면 세기가 아니라 다른 것(장착, 기준값, 간격)이 틀렸다는 신호다
        print("추정 자석 세기 %.3f A·m² (점별 %.3f~%.3f). 이 값을 train_mlp.py --m0에 넣어 MLP를 다시 학습한다." % (
            np.median(mom), mom.min(), mom.max()))
    print("z 평균 %.1f mm" % (est[:, 2].mean() * 1e3))
    print("게이트 1 기준(≤10 mm): %s, 게이트 2 기준(≤5 mm): %s" % ("통과" if rms <= 0.01 else "불통과", "통과" if rms <= 0.005 else "불통과"))


if __name__ == "__main__":
    main()
