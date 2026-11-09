"""보드 로그 파서. 데이터 수집 모드(SW[1:0]=10)의 JTAG UART 출력을 서명별 배열로 나눈다.

줄 형식 (nios/main.c):
  R,frame,time_us,err,b0..b11,x,y,z,ux,uy,pen,mlp_us   프레임 1개 (b = 기준값을 뺀 센서 LSB)
  SIG,DONE,n / SIG,REJECT                               서명 하나의 끝
  MARK                                                  KEY1 눌림 (gate1.py가 격자점 구분에 쓴다)
깨진 줄(JTAG 전송 중 잘림)은 건너뛰고 수를 보고한다.
"""
import numpy as np


def parse_lines(lines):
    """돌려주는 값: (서명 목록, 깨진 줄 수). 서명 = {"raw": N×12, "pos": N×5, "pen": N, "t_us": N, "err": N}"""
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
            if p[1] == "DONE" and cur:
                sigs.append(_to_sig(cur))
            cur = []
    return sigs, bad


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
    print("parse_log OK")


if __name__ == "__main__":
    _check()
