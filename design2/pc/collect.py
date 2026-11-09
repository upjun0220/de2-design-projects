"""서명 데이터 수집. nios2-terminal 출력을 pc/data/ 아래 파일로 저장한다.

서명 데이터는 개인정보다. 수집 전 동의를 받고, 파일명에는 이름 대신 참가자 번호만 쓴다.
pc/data/는 .gitignore로 저장소에서 제외되어 있다.

보드: SW[1:0]=10. 실행 (Nios II Command Shell):
  python pc/collect.py --participant 3 --role genuine --target 3
role: genuine(본인) / random(무작위) / static(이미지 보고 따라 쓰기) / dynamic(영상 보고 연습)
target: 이 서명이 누구 것을 쓰려는 것인지(참가자 번호). Ctrl+C로 끝낸다.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--participant", type=int, required=True)
    ap.add_argument("--role", choices=["genuine", "random", "static", "dynamic"], required=True)
    ap.add_argument("--target", type=int, required=True)
    ap.add_argument("--terminal", default="nios2-terminal")
    args = ap.parse_args()

    os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    stem = os.path.join(HERE, "data", "p%02d_%s_t%02d_%s" % (args.participant, args.role, args.target, stamp))
    with open(stem + ".json", "w", encoding="utf-8") as f:
        json.dump({"participant": args.participant, "role": args.role, "target": args.target,
                   "date": stamp[:8], "stamp": stamp}, f)

    done = 0
    proc = subprocess.Popen([args.terminal, "-q", "--no-quit-on-ctrl-d"], stdout=subprocess.PIPE, text=True)
    try:
        with open(stem + ".log", "w", encoding="ascii", errors="replace") as log:
            for line in proc.stdout:
                log.write(line)
                if line.startswith("SIG,DONE"):
                    done += 1
                    print("서명 %d개 저장" % done, flush=True)
                elif line.startswith("SIG,REJECT"):
                    print("거부: 다시 서명", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
    print("저장:", stem + ".log")
    return 0


if __name__ == "__main__":
    sys.exit(main())
