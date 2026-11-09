"""평가 하네스: DTW 식별 정확도, FAR/FRR/EER, 혼동행렬, 입력 채널 비교, 신뢰구간.

데이터: pc/data/*.log + 같은 이름의 .json (collect.py). 위치는 로그의 보드 MLP 값을 쓰거나
--lm 옵션으로 raw에서 다시 푼다(추적기를 고쳐도 다시 계산할 수 있게 raw를 저장한 이유).

분리 원칙 (README 10장):
 - 등록·문턱 결정용과 시험용 서명은 날짜로 나눈다. 같은 날짜로 재면 낙관적으로 나온다.
 - 미등록 역할의 문턱 결정용 사람과 시험용 사람을 나눈다(leave-one-person-out).
보고: "N회 중 M회 통과, 95% 신뢰구간". 0회면 "FAR 0%"가 아니라 상한을 쓴다.

실행: python pc/evaluate.py [--lm]        데이터가 있을 때
      python pc/evaluate.py --check       가짜 데이터로 코드 자체를 검증
"""
import argparse
import glob
import json
import os
import sys
import numpy as np
from scipy.stats import beta
import preprocess as pp
from parse_log import parse_lines

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hw"))
from dtw_ref import dtw_fast

HERE = os.path.dirname(os.path.abspath(__file__))
# 입력 채널 비교: 순서는 x, y, z, vx, vy, ux, uy, pen
CHANNEL_SETS = {"모양 (x,y,pen)": [0, 1, 7], "+속도": [0, 1, 3, 4, 7], "+기울기·z": list(range(8))}


def clopper_pearson(m, n, conf=0.95):
    """이항 비율의 정확한 신뢰구간"""
    a = (1 - conf) / 2
    lo = 0.0 if m == 0 else beta.ppf(a, m, n - m + 1)
    hi = 1.0 if m == n else beta.ppf(1 - a, m + 1, n - m)
    return lo, hi


def report_rate(name, m, n):
    if n == 0:
        return "%s: 시도 없음" % name
    lo, hi = clopper_pearson(m, n)
    return "%s: %d회 중 %d회 (%.1f%%), 95%% 신뢰구간 %.1f~%.1f%%" % (name, n, m, 100*m/n, 100*lo, 100*hi)


def eer(genuine, impostor):
    """FAR과 FRR이 같아지는 지점. 값이 작을수록 본인에 가까운 거리 점수."""
    g, i = np.sort(genuine), np.sort(impostor)
    best = (2.0, 0.0, 0.0)
    for t in np.unique(np.concatenate([g, i])):
        frr, far = (g > t).mean(), (i <= t).mean()
        if abs(frr - far) < best[0]:
            best = (abs(frr - far), (frr + far) / 2, t)
    return best[1], best[2]


def masked(sig, ch):
    """비교에 쓰지 않는 채널을 0으로. DTW 코드를 그대로 쓰기 위해서다."""
    out = np.zeros_like(sig)
    out[:, ch] = sig[:, ch]
    return out


def distance_to_person(q, templates):
    """nios/main.c와 같다: 그 사람의 템플릿 중 가장 가까운 것"""
    return min(dtw_fast(q, t) for t in templates)


def evaluate(samples, n_enroll=5, verbose=True):
    """samples: {"who","role","target","date","sig"(128×8)} 목록. 사람별 첫 날짜의 본인 서명으로 등록,
    나머지 날짜의 본인 서명과 다른 역할을 시험에 쓴다. 결과 요약을 돌려준다."""
    people = sorted({s["target"] for s in samples if s["role"] == "genuine"})
    results = {}
    for name, ch in CHANNEL_SETS.items():
        templates, test = {}, []
        for p in people:
            own = sorted([s for s in samples if s["role"] == "genuine" and s["who"] == p], key=lambda s: s["date"])
            first = own[0]["date"]
            first_day = [s for s in own if s["date"] == first]
            templates[p] = [masked(s["sig"], ch) for s in first_day[:n_enroll]]
            enrolled = {id(s) for s in first_day[:n_enroll]}
            # 등록과 같은 날 서명은 낙관적이므로, 다른 날짜가 있으면 시험에서 뺀다
            test += [s for s in own if id(s) not in enrolled and (s["date"] != first or len({o["date"] for o in own}) == 1)]
        test += [s for s in samples if s["role"] != "genuine"]

        g_scores, i_scores, by_role, conf = [], [], {}, {}
        ok = tot = 0
        for s in test:
            q = masked(s["sig"], ch)
            d = {p: distance_to_person(q, templates[p]) for p in people}
            best = min(d, key=d.get)
            if s["role"] == "genuine":
                g_scores.append(d[s["who"]])
                tot += 1
                ok += best == s["who"]
                conf[(s["who"], best)] = conf.get((s["who"], best), 0) + 1
            else:
                score = d.get(s["target"], min(d.values()))
                i_scores.append(score)
                by_role.setdefault(s["role"], []).append(score)
        e, t = eer(np.array(g_scores), np.array(i_scores)) if g_scores and i_scores else (float("nan"), 0)
        results[name] = {"identify": (ok, tot), "eer": e, "threshold": t, "by_role": by_role,
                         "genuine": g_scores, "confusion": conf}
        if verbose:
            print("== %s ==" % name)
            print(report_rate("식별 정답", ok, tot))
            print("EER %.1f%% (문턱 %d). 이 문턱을 같은 데이터로 잡았으므로 낙관적인 값이다." % (100*e, t))
            for role, sc in sorted(by_role.items()):
                print(report_rate("  위조 %s 통과" % role, sum(v <= t for v in sc), len(sc)))
            print("  혼동행렬 (실제, 판정): 횟수", dict(sorted(conf.items())))
    return results


def load_samples(use_lm):
    samples, reject = [], 0
    for log in sorted(glob.glob(os.path.join(HERE, "data", "*.log"))):
        meta = json.load(open(log[:-4] + ".json", encoding="utf-8"))
        sigs, _ = parse_lines(open(log, errors="replace"))
        for s in sigs:
            pos = s["pos"]
            if use_lm:
                import position_lm
                est, _ = position_lm.track(s["raw"])
                pos = np.column_stack([est[:, 0]*1e4, est[:, 1]*1e4, est[:, 2]*1e4, est[:, 3]*256, est[:, 4]*256]).astype(int)
            pen = s["pen"].tolist()
            if sum(pen) == 0:
                reject += 1
                continue
            frames = [tuple(int(v) for v in row) for row in pos]
            samples.append({"who": meta["participant"], "role": meta["role"], "target": meta["target"],
                            "date": meta["date"], "sig": np.array(pp.preprocess(frames, pen), dtype=np.int8)})
    print("서명 %d개 (펜 내림 없는 것 %d개 제외)" % (len(samples), reject))
    return samples


def check():
    """가짜 서명으로 코드 경로를 검증한다. 숫자 자체에는 의미가 없다."""
    rng = np.random.default_rng(1)
    shape = {p: rng.uniform(1, 4, 4) for p in range(3)}

    def fake(p, jitter):
        t = np.linspace(0, 6, 128)
        s = np.zeros((128, 8))
        a = shape[p]
        s[:, 0] = 50*np.sin(a[0]*t) + rng.normal(0, jitter, 128)
        s[:, 1] = 40*np.sin(a[1]*t) + rng.normal(0, jitter, 128)
        s[:, 3] = 10*a[2]*np.cos(a[0]*t)
        s[:, 4] = 10*a[3]*np.cos(a[1]*t)
        s[:, 7] = 64
        return np.clip(s, -127, 127).astype(np.int8)

    samples = []
    for p in range(3):
        for d, n in (("20261113", 6), ("20261115", 4)):
            samples += [{"who": p, "role": "genuine", "target": p, "date": d, "sig": fake(p, 3)} for _ in range(n)]
    samples += [{"who": 9, "role": "random", "target": 0, "date": "20261115", "sig": fake(1, 3)} for _ in range(4)]
    r = evaluate(samples, verbose=False)
    res = r["+기울기·z"]
    assert res["identify"][1] == 3 * (10 - 6)            # 첫날 서명은 시험에서 빠진다
    assert res["identify"][0] == res["identify"][1]      # 뚜렷이 다른 가짜 서명은 맞혀야 한다
    assert res["eer"] < 0.5
    lo, hi = clopper_pearson(0, 30)
    assert lo == 0 and 0.10 < hi < 0.13                  # 0/30의 상한은 약 11.6% (3/n 근사 10%)
    assert eer(np.array([1., 2.]), np.array([3., 4.]))[0] == 0
    print("evaluate OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lm", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if args.check:
        return check()
    samples = load_samples(args.lm)
    if not samples:
        print("pc/data/에 수집 데이터가 없다. collect.py로 먼저 수집한다.")
        return
    evaluate(samples)


if __name__ == "__main__":
    main()
