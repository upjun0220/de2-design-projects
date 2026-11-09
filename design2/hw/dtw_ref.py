"""DTW 기준 모델 (Python이 정답) — HW(Verilog)와 Nios II C가 이 값과 비트 단위로 같아야 한다.

입력: 서명 2개, 128 × 8채널 int8.
국소 거리: 채널별 절댓값 차의 합(L1, 최대 255×8 = 2040 → 11비트). 곱셈기 없음.
점화식: D[i][j] = d(i,j) + min(D[i-1][j], D[i][j-1], D[i-1][j-1])
대역: |i-j| ≤ 16 (Sakoe-Chiba). 대역 밖은 24비트 포화값 BIG.

행 순서 DP(dtw_rows)와 하드웨어처럼 안티대각선 순서로 도는 DP(dtw_antidiag)를 둘 다 두어
"계산 순서를 바꿔도 값이 같다"를 확인한다. 안티대각선 k = i+j에서는 k-1, k-2의 값만 쓰므로
같은 k의 셀을 동시에(병렬로) 계산할 수 있다. 이것이 PE 배열의 근거다.

실행: python hw/dtw_ref.py            자체 검증
      python hw/dtw_ref.py --vectors  테스트 벡터 100개를 hw/vectors/에 생성
"""
import os
import sys
import numpy as np

N, CH, BAND = 128, 8, 16
BIG = (1 << 24) - 1


def l1(a, b):
    return int(np.abs(a.astype(int) - b.astype(int)).sum())


def sat_add(m, d):
    return BIG if m == BIG else min(m + d, BIG)


def dtw_rows(x, y):
    """행 순서 DP. 2차원 표 전체를 쓰는 가장 읽기 쉬운 형태."""
    D = [[BIG] * N for _ in range(N)]
    for i in range(N):
        for j in range(max(0, i - BAND), min(N, i + BAND + 1)):
            if i == 0 and j == 0:
                m = 0
            else:
                m = min(D[i - 1][j] if i else BIG, D[i][j - 1] if j else BIG, D[i - 1][j - 1] if i and j else BIG)
            D[i][j] = sat_add(m, l1(x[i], y[j]))
    return D[N - 1][N - 1]


def dtw_fast(x, y):
    """dtw_rows와 값이 같고 국소 거리를 한 번에 계산해 훨씬 빠르다. 평가·시뮬레이션용."""
    c = np.abs(x[:, None, :].astype(np.int32) - y[None, :, :].astype(np.int32)).sum(2).tolist()
    prev = [BIG] * (2 * BAND + 3)
    for i in range(N):
        cur = [BIG] * (2 * BAND + 3)
        row = c[i]
        for j in range(max(0, i - BAND), min(N, i + BAND + 1)):
            d = j - i + BAND + 1
            m = 0 if i == 0 and j == 0 else min(prev[d + 1], prev[d], cur[d - 1])
            cur[d] = BIG if m == BIG else m + row[j]
        prev = cur
    return prev[BAND + 1]


def dtw_antidiag(x, y):
    """안티대각선 순서 DP. 표를 k 순서로 채우는 것 외에는 dtw_rows와 같다."""
    D = {}
    for k in range(2 * N - 1):
        for i in range(max(0, k - N + 1), min(N, k + 1)):
            j = k - i
            if abs(i - j) > BAND:
                continue
            m = 0 if k == 0 else min(D.get((i - 1, j), BIG), D.get((i, j - 1), BIG), D.get((i - 1, j - 1), BIG))
            D[(i, j)] = sat_add(m, l1(x[i], y[j]))
    return D[(N - 1, N - 1)]


def band_stats():
    """대역 내 셀 수, 안티대각선 수, 한 대각선 최대 셀 수."""
    cells, widest = 0, 0
    for k in range(2 * N - 1):
        c = sum(1 for i in range(max(0, k - N + 1), min(N, k + 1)) if abs(2 * i - k) <= BAND)
        cells += c
        widest = max(widest, c)
    return cells, 2 * N - 1, widest


def make_vectors(seed=2):
    """README 8장: 무작위 70, 동일 10, 최대 차이 10, 대역 가장자리 10."""
    rng = np.random.default_rng(seed)
    pairs = []
    rand = lambda: rng.integers(-128, 128, (N, CH), dtype=np.int8)
    for _ in range(70):
        pairs.append(("random", rand(), rand()))
    for _ in range(10):
        a = rand()
        pairs.append(("same", a, a.copy()))
    for _ in range(5):
        pairs.append(("maxconst", np.full((N, CH), 127, np.int8), np.full((N, CH), -128, np.int8)))
    for _ in range(5):
        a = rng.choice(np.array([-128, 127], dtype=np.int8), (N, CH))
        pairs.append(("maxdiff", a, np.where(a == 127, -128, 127).astype(np.int8)))
    for _ in range(10):
        # 시간이 대역 가장자리(16칸)까지 밀린 신호: 최적 경로가 대역 끝을 지나간다
        a = rand()
        s = int(rng.choice([-16, 16]))
        pairs.append(("band_edge", a, np.roll(a, s, axis=0)))
    return pairs


def write_vectors(path):
    """$readmemh로 읽는 형식. 한 줄 = 샘플 하나의 64비트(채널 0이 최하위 바이트)."""
    os.makedirs(path, exist_ok=True)
    pairs = make_vectors()
    def word(s):
        return "".join("%02x" % (int(v) & 0xFF) for v in s[::-1])
    with open(os.path.join(path, "x.hex"), "w") as fx, open(os.path.join(path, "y.hex"), "w") as fy, \
            open(os.path.join(path, "expected.hex"), "w") as fe:
        for _, a, b in pairs:
            fx.writelines(word(s) + "\n" for s in a)
            fy.writelines(word(s) + "\n" for s in b)
            fe.write("%06x\n" % dtw_rows(a, b))
    # 질의 하나(0번)와 템플릿 25개(0~24번의 y)를 한 번에 비교하는 경우의 기대값
    with open(os.path.join(path, "expected_multi.hex"), "w") as f:
        for k in range(25):
            f.write("%06x\n" % dtw_rows(pairs[0][1], pairs[k][2]))
    return len(pairs)


def self_check():
    cells, diags, widest = band_stats()
    assert (cells, diags, widest) == (3952, 255, 17), (cells, diags, widest)
    pairs = make_vectors()
    assert len(pairs) == 100
    for kind, a, b in pairs[:30] + pairs[70:]:
        d = dtw_rows(a, b)
        assert d == dtw_antidiag(a, b) == dtw_fast(a, b), kind
        if kind == "same":
            assert d == 0
        if kind == "maxconst":
            assert d == N * 2040   # 모든 셀이 2040이면 최단 경로(대각선 128칸)가 최소
    print("dtw_ref OK: cells=%d diagonals=%d widest=%d" % (cells, diags, widest))


if __name__ == "__main__":
    if "--vectors" in sys.argv:
        here = os.path.dirname(os.path.abspath(__file__))
        print("wrote", write_vectors(os.path.join(here, "vectors")), "pairs")
    else:
        self_check()
