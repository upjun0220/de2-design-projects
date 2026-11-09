"""서명 상태기계·전처리의 Python 기준 구현. nios/signature.c와 비트 단위로 같아야 한다.
설명과 근거는 nios/signature.c 머리 주석 참고. 임계값은 nios/config.h와 같게 둔다."""
from pen_model import tdiv

Z_DOWN, Z_UP = 120, 150
END_UP_FRAMES, MIN_DOWN_FRAMES, MAX_LOST_PCT, MAX_FRAMES = 50, 25, 20, 300
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
