"""보드 로그를 그림으로 저장한다. 첫날 디버깅과 보고서 그림용.

서명마다 PNG 한 장: 왼쪽은 위에서 본 궤적(보드 MLP, --lm이면 LM 추적 겹침, 펜 든 구간은 흐리게),
오른쪽은 시간에 따른 높이와 펜 판정, 센서별 자기장 크기.
서명 그림은 개인정보이므로 pc/data/ 아래에 저장한다(저장소에 올라가지 않는다).

실행: python pc/plot_log.py 로그파일 [--lm]
      python pc/plot_log.py --check
"""
import argparse
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from parse_log import parse_lines

HERE = os.path.dirname(os.path.abspath(__file__))


def plot_signature(sig, path, lm=None):
    pos = sig["pos"]
    t = (sig["t_us"] - sig["t_us"][0]) / 1e6
    fig, ax = plt.subplots(1, 3, figsize=(13, 4))
    x, y, z = pos[:, 0] / 10, pos[:, 1] / 10, pos[:, 2] / 10     # mm
    pen = sig["pen"].astype(bool)
    ax[0].plot(x, y, color="0.8", lw=1)
    ax[0].plot(np.where(pen, x, np.nan), np.where(pen, y, np.nan), color="C0", lw=1.5, label="보드 MLP")
    if lm is not None:
        ax[0].plot(lm[:, 0] * 1e3, lm[:, 1] * 1e3, color="C1", lw=0.8, label="LM")
        ax[0].legend()
    ax[0].set(xlabel="x [mm]", ylabel="y [mm]", title="궤적")
    ax[0].set_aspect("equal")
    ax[1].plot(t, z, label="z")
    ax[1].fill_between(t, 0, z.max() if len(z) else 1, where=pen, color="C0", alpha=0.1, label="펜 내림")
    ax[1].set(xlabel="시간 [s]", ylabel="높이 [mm]", title="높이와 펜 판정")
    ax[1].legend()
    raw = sig["raw"].reshape(-1, 4, 3)
    for k in range(4):
        ax[2].semilogy(t, np.maximum(np.linalg.norm(raw[:, k], axis=1), 1), label="센서 %d" % k)
    ax[2].set(xlabel="시간 [s]", ylabel="|B| [LSB]", title="센서별 자기장")
    ax[2].legend()
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def font():
    """한글 제목이 깨지지 않게 맑은 고딕을 쓴다. 없으면 기본 글꼴(네모로 보일 뿐 오류는 아니다)."""
    plt.rcParams["font.family"] = ["Malgun Gothic", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False


def check():
    t = np.arange(100)
    rows = []
    for i in t:
        raw = [int(500 * np.sin(i / 9 + k)) for k in range(12)]
        pen = 0 if 40 < i < 50 else 1
        rows.append("R,%d,%d,0," % (i, i * 20000) + ",".join(map(str, raw)) + ",%d,%d,%d,3,4,%d,700" % (
            300 * np.sin(i / 7), 200 * np.cos(i / 5), 90 + 60 * (1 - pen), pen))
    rows.append("SIG,DONE,100")
    sigs, bad = parse_lines(rows)
    assert bad == 0 and len(sigs) == 1
    path = os.path.join(HERE, "..", "build", "plot_check.png")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    font()
    plot_signature(sigs[0], path)
    assert os.path.getsize(path) > 10000
    print("plot_log OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?")
    ap.add_argument("--lm", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check or not a.log:
        return check()
    font()
    sigs, bad = parse_lines(open(a.log, errors="replace"))
    print("서명 %d개, 깨진 줄 %d" % (len(sigs), bad))
    os.makedirs(os.path.join(HERE, "data", "plots"), exist_ok=True)
    stem = os.path.splitext(os.path.basename(a.log))[0]
    for i, s in enumerate(sigs):
        lm = None
        if a.lm:
            import position_lm
            lm, _ = position_lm.track(s["raw"])
        out = os.path.join(HERE, "data", "plots", "%s_%02d.png" % (stem, i))
        plot_signature(s, out, lm)
        print(out)


if __name__ == "__main__":
    main()
