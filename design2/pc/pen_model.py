"""펜·센서 물리 모델과 보드 코드의 Python 기준 구현(C와 비트 단위로 같아야 하는 부분).

단위: 위치 m, 자기장 T. 센서 4개는 ±7 cm 모서리, 순서는 (-,-) (-,+) (+,-) (+,+).
기기 값 변환은 nios/position.c와 같다(pc/gen_golden.py로 비교).
"""
import numpy as np

MU = 1e-7            # μ0/4π
M0 = 0.62            # A·m². 2026-11-20 젓가락 펜 9점 측정에서 gate1.py가 추정한 값(점별 0.617~0.635). 11/19 볼펜 자석 0.585, 처음 가정 0.9
HALF = 0.07          # 센서 격자 반폭 (m). 조립 후 실측값으로 바꾼다
SENSORS = np.array([(x, y, 0.0) for x in (-HALF, HALF) for y in (-HALF, HALF)])

# mlx_reader.v 기본 설정(GAIN_SEL=5, RES=0)에서 LSB당 자기장. 데이터시트 Table 17, 25 °C.
UT_PER_LSB_XY = 0.250
UT_PER_LSB_Z = 0.403


# 자석을 펜에 붙인 방식.
#   "axial": 원통 축(극 방향)이 펜 축과 같다. README 4장의 원래 설계.
#   "side":  펜촉 옆에 붙어 극 방향이 펜 축과 직각이다. 2026-11-18 실물이 이랬다.
#            2026-11-19 펜 끝에 축 방향으로 다시 붙였다 → "axial".
#            펜을 손에서 돌려 잡는 각도(롤)에 따라 극 방향이 펜 축 둘레로 돈다. 롤은 관측되지 않으므로
#            MLP는 롤을 모든 값으로 학습하고, 출력 ux, uy는 "펜 기울기"가 아니라 "자석 극 방향의 수평 성분"이 된다.
MAGNET = "axial"


def tilt_vec(ux, uy):
    """펜 축 단위벡터. ux, uy가 xy 성분(φ 대신 씀: φ는 ±180°에서 끊겨 거리 계산을 망친다)."""
    uz = np.sqrt(np.clip(1 - ux**2 - uy**2, 0, None))
    return np.stack([ux, uy, uz], -1)


def magnet_axis(pen_axis, roll=0.0, kind=None):
    """자석 극 방향 단위벡터 (...,3). kind 생략 시 MAGNET.
    side: 펜 축 a에 수직인 기준 e1(a를 품은 수직면 안의 위쪽; 펜이 수직이면 +x)을 a 둘레로 roll[rad] 돌린 방향."""
    a = np.asarray(pen_axis, float)
    if (kind or MAGNET) == "axial":
        return a
    z = np.array([0.0, 0.0, 1.0])
    e1 = z - (a @ z)[..., None] * a
    n1 = np.linalg.norm(e1, axis=-1, keepdims=True)
    x = np.array([1.0, 0.0, 0.0])
    alt = x - (a @ x)[..., None] * a
    e1 = np.where(n1 > 1e-6, e1 / np.maximum(n1, 1e-12), alt / np.linalg.norm(alt, axis=-1, keepdims=True))
    e2 = np.cross(a, e1)
    roll = np.asarray(roll, float)[..., None]
    return np.cos(roll) * e1 + np.sin(roll) * e2


def sample_magnet(n, rng, tilt_deg=(0, 60)):
    """학습·평가용 자석 극 방향 n개. 펜 기울기 tilt_deg, 방위·롤은 균일."""
    th = np.deg2rad(rng.uniform(*tilt_deg, n))
    ph = rng.uniform(0, 2*np.pi, n)
    a = tilt_vec(np.sin(th)*np.cos(ph), np.sin(th)*np.sin(ph))
    return magnet_axis(a, rng.uniform(0, 2*np.pi, n))


def unit(v):
    """방향 벡터 정규화. 피팅은 자석 방향을 반구 제한 없이 3성분으로 풀고 이것으로 단위벡터를 만든다."""
    v = np.asarray(v, float)
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


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


def mount_correct(lsb, rot=(0, 0, 0, 0), sign=1, zsign=1, mirror=0):
    """nios/position.c의 mount_correct와 같다. (mirror면 X,Y 교환) → 센서 k의 X,Y를 보드 축으로 돌림 → 극성.
    mirror: 회전·Z 반전으로는 거울상(X↔Y 교환, 모듈을 뒤집어 붙임)을 만들 수 없어 따로 둔다(config.h MIRROR_XY)."""
    out = [int(v) for v in lsb]
    for k in range(4):
        if mirror:
            out[3*k], out[3*k+1] = out[3*k+1], out[3*k]
        for _ in range(rot[k]):
            out[3*k], out[3*k+1] = -out[3*k+1], out[3*k]
        out[3*k], out[3*k+1], out[3*k+2] = sign*out[3*k], sign*out[3*k+1], sign*zsign*out[3*k+2]
    return out


def mount_apply(raw, rot=(0, 0, 0, 0), sign=1, zsign=1, mirror=0):
    """mount_correct의 실수 배열판. raw (...,12)"""
    out = np.array(raw, float)
    out[..., 2::3] *= zsign
    for k in range(4):
        if mirror:
            out[..., [3*k, 3*k+1]] = out[..., [3*k+1, 3*k]]
        for _ in range(rot[k]):
            x, y = out[..., 3*k].copy(), out[..., 3*k+1].copy()
            out[..., 3*k], out[..., 3*k+1] = -y, x
    return out * sign


def read_mount():
    """nios/config.h의 MOUNT_ROT, FIELD_SIGN, Z_SIGN, MIRROR_XY를 읽는다. 보드와 PC가 같은 값을 쓰게 하려고
    여기에 따로 적지 않는다. 돌려주는 값: (rot, sign, zsign, mirror)"""
    import os
    import re
    txt = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "nios", "config.h")).read()
    txt = txt[txt.index("#else", txt.index("TEST_MOUNT")):]          # 시험용 값 다음의 실제 값
    # #define 줄만 읽는다(주석에 같은 이름이 나와도 속지 않게)
    rot = tuple(int(v) for v in re.search(r"#define\s+MOUNT_ROT\s*\{([^}]*)\}", txt).group(1).split(","))
    sign = int(re.search(r"#define\s+FIELD_SIGN\s+\(?(-?\d+)", txt).group(1))
    zsign = int(re.search(r"#define\s+Z_SIGN\s+\(?(-?\d+)", txt).group(1))
    mirror = int(re.search(r"#define\s+MIRROR_XY\s+(\d)", txt).group(1))
    return rot, sign, zsign, mirror


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
