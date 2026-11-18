"""서명 상태기계·전처리의 Python 기준 구현. nios/signature.c와 비트 단위로 같아야 한다.
설명과 근거는 nios/signature.c 머리 주석 참고. 임계값은 nios/config.h와 같게 둔다."""
from pen_model import tdiv

Z_DOWN, Z_UP = 120, 150
END_UP_FRAMES, MIN_DOWN_FRAMES, MAX_LOST_PCT, MAX_FRAMES = 50, 25, 20, 500
TRIM_LIFT, TRIM_WINDOW = 150, 150
N, CH = 128, 8


def clamp8(v):
    return max(-127, min(127, v))


def preprocess(frames, pen):
    """frames: [(x,y,z,ux,uy), ...], pen: [0/1, ...] → 128×8 정수 리스트"""
    down = [f for f, p in zip(frames, pen) if p]
    cx = tdiv(sum(f[0] for f in down), len(down))
    cy = tdiv(sum(f[1] for f in down), len(down))
    width = max(max(f[0] for f in down) - min(f[0] for f in down), 1)
    zmin = min(f[2] for f in down)
    last = len(frames) - 1
    out = [[0] * CH for _ in range(N)]
    for i in range(N):
        pos = i * last
        a, f = pos // (N - 1), pos % (N - 1)
        b = a + 1 if a < last else a
        g = (N - 1) - f
        X, Y, Z, UX, UY = [tdiv(frames[a][c] * g + frames[b][c] * f, N - 1) for c in range(5)]
        out[i][0] = clamp8(tdiv((X - cx) * 100, width))
        out[i][1] = clamp8(tdiv((Y - cy) * 100, width))
        out[i][2] = clamp8(tdiv(Z - zmin, 4))
        out[i][5] = clamp8(tdiv(UX * 100, 256))
        out[i][6] = clamp8(tdiv(UY * 100, 256))
        out[i][7] = 64 if pen[b if f >= 64 else a] else 0
    for i in range(N):
        p, q = max(i - 1, 0), min(i + 1, N - 1)
        out[i][3] = clamp8((out[q][0] - out[p][0]) * 2)
        out[i][4] = clamp8((out[q][1] - out[p][1]) * 2)
    return out


def segment(stream):
    """프레임 스트림 → 완성된 서명들. stream: [(x,y,z,ux,uy,lost), ...].
    nios/signature.c의 sig_feed와 같은 규칙. 돌려주는 값: [(frames, pen), ...]"""
    result = []
    active, is_down = False, False
    frames, pen, up_run, down_total, lost = [], [], 0, 0, 0
    for fr in stream:
        z = fr[2]
        if z < Z_DOWN:
            is_down = True
        elif z > Z_UP:
            is_down = False
        if not active:
            if not is_down:
                continue
            active, frames, pen, up_run, down_total, lost = True, [], [], 0, 0, 0
        frames.append(fr[:5])
        pen.append(1 if is_down else 0)
        lost += 1 if fr[5] else 0
        if is_down:
            down_total, up_run = down_total + 1, 0
        else:
            up_run += 1
        if up_run >= END_UP_FRAMES or len(frames) >= MAX_FRAMES:
            while frames and not pen[-1]:
                frames.pop(), pen.pop()
            active = False
            if down_total >= MIN_DOWN_FRAMES and lost * 100 <= len(frames) * MAX_LOST_PCT:
                result.append((frames, pen))
    return result


def trim_tail(z, z_ref):
    """펜 스위치 서명 끝의 꼬리 자르기(nios/signature.c sig_trim_tail과 같다). 돌려주는 값: 남길 프레임 수.
    서명 끝: 마지막 획 → 펜을 듦 → 손을 스위치로 → 스위치 끔. 펜을 든 뒤의 움직임은 서명이 아니다.
     1. zs = 앞뒤 2프레임씩 평균한 높이(서명이 다 저장된 뒤라 지연이 없다).
     2. j = zs가 z_ref + TRIM_LIFT보다 낮은 마지막 프레임. 그보다 높게 끝났고 높은 구간이
        마지막 TRIM_WINDOW 프레임 안에서 시작했으면, 끝에서 펜을 들고 다시 내리지 않은 것이다.
     3. 처음 높아진 프레임에서 높이가 계속 낮아지는 쪽으로 거슬러 가서, 가장 낮은 점(펜이 종이를 떠난 곳)
        다음을 자른다.
    못 찾으면 자르지 않는다(꼬리가 남는 게 획이 잘리는 것보다 낫다)."""
    n = len(z)
    if TRIM_LIFT <= 0 or n < 2:
        return n

    def zs(i):
        vals = [z[k] for k in range(i - 2, i + 3) if 0 <= k < n]
        return tdiv(sum(vals), len(vals))

    start = n - TRIM_WINDOW if n > TRIM_WINDOW else 0
    j = n - 1
    while j >= 0 and zs(j) >= z_ref + TRIM_LIFT:
        j -= 1
    if j < 0 or j == n - 1 or j + 1 < start:
        return n
    k = j + 1
    while k > start and zs(k - 1) <= zs(k):
        k -= 1
    return k + 1


def _check_trim():
    """꼬리 자르기의 대표 경우. 숫자는 0.1 mm."""
    write = [90 + (i % 7) for i in range(200)]                       # 종이 위(약 9 mm, 떨림)
    lift = [90 + 12 * i for i in range(1, 30)]                        # 끝에서 펜을 듦(최고 약 44 mm)
    assert trim_tail(write, 90) == 200                                # 들지 않고 끝: 그대로
    n = trim_tail(write + lift + [440] * 40, 90)
    assert 195 <= n <= 201, n                                         # 들기 직전에서 잘린다
    spikes = write[:100] + [300] * 3 + write[100:]                    # 쓰는 중 잠깐 튄 높이
    assert trim_tail(spikes, 90) == len(spikes)
    low = write + [90 + 3 * i for i in range(1, 30)]                  # 낮게(15 mm 미만) 들고 끝: 못 찾음
    assert trim_tail(low, 90) == len(low)
    long_up = write + lift + [440] * 200                              # 3초 넘게 들고 있었음: 자르지 않음
    assert trim_tail(long_up, 90) == len(long_up)
    assert trim_tail([440] * 50, 90) == 50                            # 처음부터 높음(z_ref가 틀림): 자르지 않음
