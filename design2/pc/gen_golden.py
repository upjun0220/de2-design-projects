"""C 코드 검증용 기대값 파일 생성. nios/test_host.c가 읽어서 Python과 비트 단위로 비교한다.
Python 쪽이 정답이다. 형식은 공백으로 구분한 정수의 나열.

실행: python pc/gen_golden.py build/golden.txt
"""
import os
import random
import re
import sys
import numpy as np
import pen_model as pm
import preprocess as pp

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hw"))
import dtw_ref


def load_weights():
    """nios/mlp_weights.h를 읽는다. C와 같은 가중치를 쓴다는 보장."""
    here = os.path.dirname(os.path.abspath(__file__))
    txt = open(os.path.join(here, "..", "nios", "mlp_weights.h")).read()
    layers = []
    for i in range(3):
        W = re.search(r"mlp_w%d\[\d+\]\[\d+\] = \{(.*?)\n\};" % i, txt, re.S).group(1)
        W = [[int(v) for v in r.split(",")] for r in re.findall(r"\{([^{}]*)\}", W)]
        b = re.search(r"mlp_b%d\[\d+\] = \{([^}]*)\}" % i, txt).group(1)
        layers.append((W, [int(v) for v in b.split(",")]))
    return layers


def fake_stream(rng, n):
    """서명처럼 움직이는 정수 프레임 열. 펜 올림·내림과 끝의 1 s 올림을 포함."""
    t = np.arange(n)
    x = (300 * np.sin(t / 7 + rng.uniform(0, 6)) + rng.normal(0, 3, n)).astype(int)
    y = (200 * np.sin(t / 5 + rng.uniform(0, 6)) + rng.normal(0, 3, n)).astype(int)
    z = (90 + rng.normal(0, 3, n)).astype(int)
    z[n // 2: n // 2 + 8] = 200          # 획 사이 펜 들기
    ux = (80 * np.sin(t / 11)).astype(int)
    uy = (-60 * np.cos(t / 13)).astype(int)
    lost = rng.uniform(0, 1, n) < 0.02
    tail = [(int(x[-1]), int(y[-1]), 300, int(ux[-1]), int(uy[-1]), 0)] * pp.END_UP_FRAMES
    return [(int(x[i]), int(y[i]), int(z[i]), int(ux[i]), int(uy[i]), int(lost[i])) for i in range(n)] + tail


def main(path):
    rng = np.random.default_rng(5)
    r = random.Random(5)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    out = []

    # 1. 세제곱근
    vals = [0, 1, 7, 8, 26, 27, 1000, 1 << 20, (1 << 28) - 1] + [r.randrange(1 << 28) for _ in range(200)]
    out.append(len(vals))
    for v in vals:
        out += [v, pm.icbrt(v)]

    # 2. 센서값 → 입력 → MLP → 위치
    layers = load_weights()
    n = 300
    out.append(n)
    for _ in range(n):
        lsb = [int(v) for v in np.round(rng.normal(0, 800, 12) * rng.uniform(0, 1))]
        x = pm.input_from_lsb(lsb)
        o, peak = pm.mlp_forward_int(layers, x)
        assert peak < 2**31
        out += lsb + x + pm.output_to_units(o)

    # 3. 서명 분할·전처리 (프레임 수가 짧은 것부터 최대 길이까지, 거부되는 짧은 서명 포함)
    cases = [10, 20, 40, 77, 128, 129, 200, 299, 400] + [r.randrange(30, 299) for _ in range(40)]
    out.append(len(cases))
    for c in cases:
        stream = fake_stream(rng, c)
        sigs = pp.segment(stream)
        out.append(len(stream))
        for f in stream:
            out += list(f)
        out.append(len(sigs))
        for frames, pen in sigs:
            out.append(len(frames))
            for row in pp.preprocess(frames, pen):
                out += row

    # 4. DTW
    pairs = dtw_ref.make_vectors()
    pick = pairs[:10] + pairs[70:]
    out.append(len(pick))
    for _, a, b in pick:
        out += [int(v) for v in a.ravel()] + [int(v) for v in b.ravel()] + [dtw_ref.dtw_rows(a, b)]

    with open(path, "w") as f:
        f.write(" ".join(str(v) for v in out))
    print("golden:", path)


if __name__ == "__main__":
    main(sys.argv[1])
