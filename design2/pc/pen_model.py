"""펜·센서 물리 모델과 보드 코드의 Python 기준 구현(C와 비트 단위로 같아야 하는 부분).

단위: 위치 m, 자기장 T. 센서 4개는 ±7 cm 모서리, 순서는 (-,-) (-,+) (+,-) (+,+).
기기 값 변환은 nios/position.c와 같다(pc/gen_golden.py로 비교).
"""
import numpy as np

MU = 1e-7            # μ0/4π
M0 = 0.9             # A·m². N52 가정의 추정값 → 실제 자석으로 교정해서 바꾼다
HALF = 0.07          # 센서 격자 반폭 (m). 조립 후 실측값으로 바꾼다
SENSORS = np.array([(x, y, 0.0) for x in (-HALF, HALF) for y in (-HALF, HALF)])

# mlx_reader.v 기본 설정(GAIN_SEL=5, RES=0)에서 LSB당 자기장. 데이터시트 Table 17, 25 °C.
UT_PER_LSB_XY = 0.250
UT_PER_LSB_Z = 0.403


def tilt_vec(ux, uy):
    """펜 축 단위벡터. ux, uy가 xy 성분(φ 대신 씀: φ는 ±180°에서 끊겨 거리 계산을 망친다)."""
    uz = np.sqrt(np.clip(1 - ux**2 - uy**2, 0, None))
    return np.stack([ux, uy, uz], -1)


def field(pos, axis, m0=M0, sensors=SENSORS):
    """쌍극자 자기장. pos (...,3), axis (...,3) → (...,N,3) [T]"""
    r = sensors - pos[..., None, :]
    d = np.linalg.norm(r, axis=-1, keepdims=True)
    rh = r / d
    m = m0 * axis[..., None, :]
    return MU * (3 * (rh * m).sum(-1, keepdims=True) * rh - m) / d**3


def lsb_from_tesla(b):
    """자기장 (…,12 또는 …,N,3) → 센서 LSB 실수값"""
    s = np.array([UT_PER_LSB_XY, UT_PER_LSB_XY, UT_PER_LSB_Z])
    return b * 1e6 / s


# ---- 아래는 nios/position.c, signature.c와 정확히 같은 정수 연산 ----

def icbrt(v):
    """정수 세제곱근(내림). 비트 단위 방식이라 나눗셈 없이 Nios II에서 돈다."""
    r, s = 0, 30
    while s >= 0:
        r *= 2
        b = 3 * r * (r + 1) + 1
        if (v >> s) >= b:
            v -= b << s
            r += 1
        s -= 3
    return r


def tdiv(a, b):
    """C의 정수 나눗셈(0 쪽으로 버림). Python //는 내림이라 음수에서 다르다."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def mount_correct(lsb, rot=(0, 0, 0, 0), sign=1, zsign=1):
    """nios/position.c의 mount_correct와 같다. 센서 k의 X,Y를 보드 축으로 돌리고 극성을 곱한다."""
    out = [int(v) for v in lsb]
    for k in range(4):
        for _ in range(rot[k]):
            out[3*k], out[3*k+1] = -out[3*k+1], out[3*k]
        out[3*k], out[3*k+1], out[3*k+2] = sign*out[3*k], sign*out[3*k+1], sign*zsign*out[3*k+2]
    return out


def mount_apply(raw, rot=(0, 0, 0, 0), sign=1, zsign=1):
    """mount_correct의 실수 배열판. raw (...,12)"""
    out = np.array(raw, float)
    out[..., 2::3] *= zsign
    for k in range(4):
        for _ in range(rot[k]):
            x, y = out[..., 3*k].copy(), out[..., 3*k+1].copy()
            out[..., 3*k], out[..., 3*k+1] = -y, x
    return out * sign


def read_mount():
    """nios/config.h의 MOUNT_ROT, FIELD_SIGN, Z_SIGN을 읽는다. 보드와 PC가 같은 값을 쓰게 하려고
    여기에 따로 적지 않는다. 돌려주는 값: (rot, sign, zsign)"""
    import os
    import re
    txt = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "nios", "config.h")).read()
    txt = txt[txt.index("#else", txt.index("TEST_MOUNT")):]          # 시험용 값 다음의 실제 값
    rot = tuple(int(v) for v in re.search(r"MOUNT_ROT\s*\{([^}]*)\}", txt).group(1).split(","))
    sign = int(re.search(r"FIELD_SIGN\s+\(?(-?\d+)", txt).group(1))
    zsign = int(re.search(r"Z_SIGN\s+\(?(-?\d+)", txt).group(1))
    return rot, sign, zsign


UNIFORM_PCT = 20     # nios/config.h와 같게 둔다


def field_is_uniform(lsb):
    """nios/position.c의 field_is_uniform과 같은 정수 연산. 센서 4개가 거의 같은 벡터를 보면 1.
    펜(가까운 자석)은 센서마다 값이 크게 다르고, 보드를 돌리거나 먼 물체가 움직인 경우는 같다."""
    v = [int(x) for x in lsb]
    for k in range(4):
        v[3*k+2] = tdiv(v[3*k+2] * 1612, 1000)
    num = den = 0
    for c in range(3):
        total = v[c] + v[3+c] + v[6+c] + v[9+c]
        for k in range(4):
            num += abs(4 * v[3*k+c] - total)      # 4 × (값 − 평균)
            den += abs(v[3*k+c])
    return 1 if num * 100 < 4 * den * UNIFORM_PCT else 0


def input_from_lsb(lsb):
    """기준값을 뺀 12채널 LSB → MLP 입력(Q6). 자기장은 거리의 세제곱에 반비례해 범위가
    수천 배이므로 세제곱근으로 압축한다. Z축은 XY축과 LSB 크기가 달라 먼저 맞춘다."""
    out = []
    for k, v in enumerate(lsb):
        v = int(v)
        if k % 3 == 2:
            v = tdiv(v * 1612, 1000)            # 0.403/0.250 = 1.612
        a = min(abs(v), 1 << 20)
        c = icbrt(a << 8)
        out.append(-c if v < 0 else c)
    return out


def input_float(b_tesla):
    """학습용 실수 버전. 위 정수 변환을 (양자화 없이) 그대로 따른다. 값은 Q6 눈금/64."""
    u = b_tesla * 1e6 / UT_PER_LSB_XY       # Z도 XY 눈금으로 맞춘 값
    return np.sign(u) * np.cbrt(np.abs(u) * 256) / 64.0


def mlp_forward_int(layers, x):
    """정수 MLP. layers = [(W int, b int), ...], 입력 Q6, 은닉 ReLU, 출력 Q12.
    합은 32비트 안에 있어야 한다(train_mlp.py가 검사). 은닉값은 4095(=64.0)에서 자른다."""
    a = list(x)
    peak = 0
    for li, (W, b) in enumerate(layers):
        out = []
        for row, bias in zip(W, b):
            s = int(bias) + sum(int(w) * v for w, v in zip(row, a))
            peak = max(peak, abs(s))
            if li == len(layers) - 1:
                out.append(s >> 4)
            else:
                out.append(min(max(s >> 10, 0), 4095))
        a = out
    return a, peak


def output_to_units(o):
    """MLP 출력(Q12, 5 cm=1.0) → x,y,z [0.1 mm], ux,uy [Q8]"""
    return [(o[0] * 500) >> 12, (o[1] * 500) >> 12, (o[2] * 500) >> 12, o[3] >> 4, o[4] >> 4]
