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
import pen_filter as pf

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


def channel_mask():
    """nios/config.h의 CHANNEL_MASK. 보드는 쓰지 않는 채널을 0으로 만든다(signature.c)."""
    here = os.path.dirname(os.path.abspath(__file__))
    txt = open(os.path.join(here, "..", "nios", "config.h")).read()
    return int(re.search(r"#define\s+CHANNEL_MASK\s+(\w+)", txt).group(1), 0)


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
    mask = channel_mask()

    # 1. 세제곱근
    vals = [0, 1, 7, 8, 26, 27, 1000, 1 << 20, (1 << 28) - 1] + [r.randrange(1 << 28) for _ in range(200)]
    out.append(len(vals))
    for v in vals:
        out += [v, pm.icbrt(v)]

    # 2. 센서값 → 입력 → MLP → 위치
    layers = load_weights()
    n = 300
    out.append(n)
    flags = []
    for _ in range(n):
        if _ % 3 == 0:      # 센서 4개가 거의 같은 값: 균일 외란. 크기와 섞인 잡음을 바꿔 경계 근처도 넣는다
            lsb = [int(v) for v in np.round(np.tile(rng.normal(0, 400, 3), 4) + rng.normal(0, rng.uniform(1, 150), 12))]
        elif _ % 3 == 1:    # 최댓값 근처: 32비트 넘침이 없는지
            lsb = [int(v) for v in rng.choice([-32768, 32767], 12)]
        else:
            lsb = [int(v) for v in np.round(rng.normal(0, 800, 12) * rng.uniform(0, 1))]
        x = pm.input_from_lsb(lsb)
        o, peak = pm.mlp_forward_int(layers, x)
        assert peak < 2**31
        out += lsb + x + pm.output_to_units(o) + [pm.field_is_uniform(lsb)]
        flags.append(pm.field_is_uniform(lsb))
    assert 30 < sum(flags) < 200, sum(flags)        # 두 경우가 모두 시험에 들어 있어야 한다

    # 3. 서명 분할·전처리 (프레임 수가 짧은 것부터 최대 길이까지, 거부되는 짧은 서명 포함)
    cases = [10, 20, 40, 77, 128, 129, 200, 299, 400, 499, 600] + [r.randrange(30, 499) for _ in range(40)]
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
                out += [v if (mask >> c) & 1 else 0 for c, v in enumerate(row)]

    # 4. DTW
    pairs = dtw_ref.make_vectors()
    pick = pairs[:10] + pairs[70:]
    out.append(len(pick))
    for _, a, b in pick:
        out += [int(v) for v in a.ravel()] + [int(v) for v in b.ravel()] + [dtw_ref.dtw_rows(a, b)]

    # 5. 위치 필터(중앙값 + 1€): 잡음 섞인 곡선, 한 프레임 튐, 범위 밖 값, 중간 재시작(펜이 사라짐)
    seqs = []
    for c in range(12):
        n = r.randrange(20, 300)
        t = np.arange(n)
        speed = r.choice([0.0, 0.3, 1.0, 3.0])
        rows = []
        for i in range(n):
            v = [int(round(400 * np.sin(speed * t[i] / 10 + k) + rng.normal(0, 15))) for k in range(3)]
            if r.random() < 0.03:
                v[r.randrange(3)] += r.choice([-1, 1]) * r.randrange(100, 3000)
            if c == 0 and i % 50 == 7:
                v = [r.choice([-32000, 32000, 6000, -6000]) for _ in range(3)]
            rows.append((int(i == 0 or r.random() < 0.02), v))
        seqs.append(rows)
    out.append(len(seqs))
    for rows in seqs:
        out.append(len(rows))
        f = pf.PenFilter()
        for reset, v in rows:
            if reset:
                f = pf.PenFilter()
            out += [reset] + v + list(f.step(v))

    # 6. 펜 스위치 서명 끝의 꼬리 자르기
    tcases = []
    for c in range(60):
        zr = r.randrange(50, 150)
        n_write = r.randrange(5, 400)
        z = [zr + int(abs(rng.normal(0, 20))) for _ in range(n_write)]
        if r.random() < 0.3:                      # 쓰는 중 잠깐 튄 높이
            i = r.randrange(n_write)
            z[i:i + 3] = [zr + r.randrange(100, 400)] * len(z[i:i + 3])
        kind = c % 4
        if kind == 1:                             # 끝에서 펜을 들고 스위치를 끔
            rise = r.randrange(5, 30)
            top = zr + r.randrange(160, 500)
            z += [z[-1] + (top - z[-1]) * (i + 1) // rise for i in range(rise)] + [top + r.randrange(-20, 20) for _ in range(r.randrange(0, 120))]
        elif kind == 2:                           # 낮게 들고 끝(못 찾아야 한다)
            z += [zr + 5 * i for i in range(r.randrange(1, 28))]
        elif kind == 3:                           # 오래 들고 있었음(창 밖)
            z += [zr + 300] * r.randrange(140, 200)
        tcases.append((zr, z[:pp.MAX_FRAMES]))
    tcases.append((90, [440] * 50))
    cut = sum(pp.trim_tail(z, zr) < len(z) for zr, z in tcases)
    assert 10 < cut < len(tcases) - 10, cut         # 자르는 경우와 안 자르는 경우가 모두 시험에 들어 있어야 한다
    out.append(len(tcases))
    for zr, z in tcases:
        out += [len(z), zr] + z + [pp.trim_tail(z, zr)]

    with open(path, "w") as f:
        f.write(" ".join(str(v) for v in out))
    print("golden:", path)


if __name__ == "__main__":
    main(sys.argv[1])
