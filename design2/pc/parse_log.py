"""보드 로그 파서. 데이터 수집 모드(SW[1:0]=10)의 JTAG UART 출력을 서명별 배열로 나눈다.

줄 형식 (nios/main.c):
  R,frame,time_us,err,b0..b11,x,y,z,ux,uy,pen,mlp_us   프레임 1개 (b = 기준값을 뺀 센서 LSB)
  SIG,DONE,n / SIG,REJECT                               서명 하나의 끝
  MARK                                                  KEY1 눌림 (gate1.py가 격자점 구분에 쓴다)
깨진 줄(JTAG 전송 중 잘림)은 건너뛰고 수를 보고한다.

수집 모드는 프레임을 계속 내보내므로 로그에는 서명 앞의 대기 구간과 끝난 뒤 펜을 든 1초도 들어 있다.
보드는 첫 펜 내림부터 마지막 펜 내림까지만 서명으로 쓴다(nios/signature.c). 여기서도 똑같이 자른다.
그러지 않으면 PC 평가가 보드와 다른 신호를 비교하게 된다.
펜 스위치(SW17) 서명은 끝난 뒤 보드가 끝의 꼬리(펜을 든 뒤의 움직임)를 잘라 낸다(sig_trim_tail). 그 프레임들은
이미 pen=1로 로그에 찍혔으므로, SIG,DONE,n이 있으면 첫 펜 내림부터 n줄을 서명으로 쓴다.
"""
import numpy as np


def parse_lines(lines):
    """돌려주는 값: (서명 목록, 깨진 줄 수). 서명 = {"raw": N×12, "pos": N×5, "pen": N, "t_us": N, "err": N}
    프레임 수가 보드가 알려 준 수(SIG,DONE,n)와 다르면 줄이 빠진 것이므로 깨진 줄 수에 더한다."""
    sigs, cur, bad = [], [], 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        p = line.split(",")
        if p[0] == "R":
            if len(p) != 4 + 12 + 7:
                bad += 1
                continue
            try:
                cur.append([int(v) for v in p[1:]])
            except ValueError:
                bad += 1
        elif p[0] == "SIG":
            pen = [r[PEN] for r in cur]
            if p[1] == "DONE" and 1 in pen:
                first, last = pen.index(1), len(pen) - 1 - pen[::-1].index(1)
                n = last + 1 - first
                if len(p) > 2 and p[2].isdigit():
                    if int(p[2]) > n:
                        bad += 1                 # 보드보다 줄이 적다: 줄이 빠졌다
                    n = min(n, int(p[2]))        # 보드가 꼬리를 잘랐으면 n이 더 작다
                sigs.append(_to_sig(cur[first:first + n]))
            cur = []
    return sigs, bad


PEN = 20     # R 줄에서 "R,"을 뺀 뒤의 pen 열 위치: frame, time, err, 센서 12개, x, y, z, ux, uy, pen


def _to_sig(rows):
    a = np.array(rows, dtype=np.int64)
    return {"frame": a[:, 0], "t_us": a[:, 1], "err": a[:, 2], "raw": a[:, 3:15],
            "pos": a[:, 15:20], "pen": a[:, 20], "mlp_us": a[:, 21]}


def _check():
    good = "R,1,20000,0," + ",".join(str(i) for i in range(12)) + ",1,2,90,3,4,1,700"
    lines = [good, good.replace("R,1", "R,2"), "R,3,broken", "SIG,DONE,2", good, "SIG,REJECT", "", good, "SIG,DONE,1"]
    sigs, bad = parse_lines(lines)
    assert bad == 1 and len(sigs) == 2, (bad, len(sigs))
    assert sigs[0]["raw"].shape == (2, 12) and sigs[0]["pos"][1, 2] == 90 and sigs[0]["frame"][1] == 2
    assert sigs[1]["raw"].shape == (1, 12)     # 거부된 서명의 프레임은 버려진다

    # 보드와 같은 구간을 잘라내는지: 대기 4초 + 서명 + 펜 올림 1초짜리 로그를 만들어 비교한다
    import preprocess as pp
    from gen_golden import fake_stream
    stream = [(0, 0, 300, 0, 0, 0)] * 200 + fake_stream(np.random.default_rng(5), 150)
    (frames, pen), = pp.segment(stream)
    log, down = [], False
    for i, f in enumerate(stream):
        down = True if f[2] < pp.Z_DOWN else False if f[2] > pp.Z_UP else down
        log.append("R,%d,%d,0," % (i, i * 20000) + ",".join(["0"] * 12) + ",%d,%d,%d,%d,%d,%d,700" % (*f[:5], down))
    sigs, bad = parse_lines(log + ["SIG,DONE,%d" % len(frames)])
    assert bad == 0 and [tuple(r) for r in sigs[0]["pos"].tolist()] == frames and sigs[0]["pen"].tolist() == pen
    sigs, bad = parse_lines(log[:250] + log[251:] + ["SIG,DONE,%d" % len(frames)])
    assert bad == 1                              # 서명 중간의 줄 하나가 빠지면 알려 준다
    # 보드가 끝의 꼬리를 잘랐을 때(SIG,DONE,n이 pen=1 줄 수보다 작다): 앞의 n줄만 쓰고 오류로 세지 않는다
    sigs, bad = parse_lines(log + ["SIG,DONE,%d" % (len(frames) - 10)])
    assert bad == 0 and len(sigs[0]["pos"]) == len(frames) - 10
    assert [tuple(r) for r in sigs[0]["pos"].tolist()] == frames[:-10]
    pp._check_trim()                             # 꼬리 자르기의 Python 기준 구현
    print("parse_log OK")


if __name__ == "__main__":
    _check()
