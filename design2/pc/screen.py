"""노트북에 보드 화면 띄우기. 모니터 없이 VGA와 같은 화면을 본다.

보드는 화면이 바뀔 때마다 그 내용을 JTAG UART로 보낸다(nios/relay.c, '@'로 시작하는 줄).
이 프로그램은 nios2-terminal을 대신 실행해서 그 줄을 받아, 보드의 폰트 ROM(hdl/font8x16.v)과
팔레트(hdl/vga_ui.v)로 640x480 화면을 그린다. 화면 내용은 보드가 정하고, 여기서는 그리기만 한다.
'@'가 아닌 줄(I2C 스캔 결과, 수집 모드 로그)은 터미널에 그대로 찍고 --log를 주면 파일에도 저장한다.

실행 (Nios II Command Shell, nios2-download 다음에):
  python design2/pc/screen.py                     창 띄우기
  python design2/pc/screen.py --log pc/data/p01.log  수집 로그도 저장 (collect.py 대신)
  python design2/pc/screen.py --scale 1           처음 창 배율 (생략하면 화면에 맞춤, 창은 늘리고 줄일 수 있음)
  python design2/pc/screen.py --check 화면.txt     자체 검증 (run_checks.sh가 실행)

nios2-terminal과 동시에 쓸 수 없다(JTAG UART 연결이 하나뿐). 하나를 닫고 다른 것을 연다.
보드는 몇 초마다 화면 줄을 다시 보내므로, 늦게 연결해도 글자는 곧 채워진다. 서명 칸의 획은
다음 서명부터 보인다.
"""
import argparse
import os
import queue
import subprocess
import sys
import threading
import numpy as np
from render_screen import load_font, load_palette

W, H = 640, 480
BM, BM_X0, BM_Y0 = 192, 8, 32       # hdl/vga_ui.v의 서명 칸
INK = 6                             # hdl/vga_ui.v의 INK 기본값(흰색)


class Screen:
    """보드 화면의 복사본. 적용 규칙은 hdl/vga_ui.v(그리고 그 시험 모델)와 같다."""

    def __init__(self):
        self.cells = np.zeros((30, 80), dtype=np.uint16)         # attr << 8 | ch
        self.bitmap = np.zeros((BM, BM), dtype=bool)
        self.cursor = (0, 0, 0, 0)                              # on, colour, x, y
        self.dirty = True

    def apply(self, line):
        """'@' 줄 하나를 적용. 알아들으면 True. 깨진 줄은 무시한다(JTAG 전송 중 잘릴 수 있음)."""
        p = line.split()
        try:
            if p[0] == "@T":
                row, col, hexs = int(p[1]), int(p[2]), p[3] if len(p) > 3 else ""
                if len(hexs) % 4 or not (0 <= row < 30 and 0 <= col < 80):
                    return False
                for i in range(len(hexs) // 4):
                    if col + i < 80:
                        self.cells[row, col + i] = int(hexs[4*i:4*i+4], 16)
            elif p[0] == "@K":
                self.bitmap[:] = False
            elif p[0] == "@L":
                self.line(*(int(v) for v in p[1:5]))
            elif p[0] == "@P":
                self.cursor = tuple(int(v) for v in p[1:5])
            else:
                return False
        except (ValueError, IndexError, TypeError):
            return False
        self.dirty = True
        return True

    def line(self, x0, y0, x1, y1):
        """Bresenham, hdl/vga_ui.v와 같은 순서. 칸 밖의 점은 건너뛴다."""
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x1 >= x0 else -1), (1 if y1 >= y0 else -1)
        err = dx + dy
        while True:
            if 0 <= x0 < BM and 0 <= y0 < BM:
                self.bitmap[y0, x0] = True
            if x0 == x1 and y0 == y1:
                return
            e2 = 2 * err
            if dy <= e2 <= dx:
                err += dy + dx; x0 += sx; y0 += sy
            elif e2 >= dy:
                err += dy; x0 += sx
            else:
                err += dx; y0 += sy

    def render(self, font, pal):
        """640x480 RGB 배열. 우선순위: 커서 > 글자 > 비트맵 > 칸 배경 (hdl/vga_ui.v)."""
        ch = (self.cells & 0x7F).astype(np.int64)
        fg = (self.cells >> 8) & 15
        bg = (self.cells >> 12) & 15
        rows = font[ch[:, :, None] * 16 + np.arange(16)]                    # 30 x 80 x 16 바이트
        bits = (rows[..., None] >> (7 - np.arange(8))) & 1                  # 30 x 80 x 16 x 8
        glyph = bits.transpose(0, 2, 1, 3).reshape(H, W).astype(bool)
        index = np.where(glyph, np.repeat(np.repeat(fg, 16, 0), 8, 1), np.repeat(np.repeat(bg, 16, 0), 8, 1))
        bm = np.zeros((H, W), dtype=bool)
        bm[BM_Y0:BM_Y0 + 2*BM, BM_X0:BM_X0 + 2*BM] = np.repeat(np.repeat(self.bitmap, 2, 0), 2, 1)
        index = np.where(~glyph & bm, INK, index)
        on, colour, cx, cy = self.cursor
        if on:
            px, py = BM_X0 + 2*cx, BM_Y0 + 2*cy
            arm = lambda d: ((-8 <= d) & (d <= -2)) | ((3 <= d) & (d <= 9))
            dx = np.arange(W)[None, :] - px
            dy = np.arange(H)[:, None] - py
            cross = (arm(dx) & ((dy == 0) | (dy == 1))) | (arm(dy) & ((dx == 0) | (dx == 1)))
            index = np.where(cross, colour, index)
        return pal[index]


def nios_terminal():
    """nios2-terminal을 띄워 그 출력을 줄 단위로 넘긴다."""
    proc = subprocess.Popen(["nios2-terminal", "-q", "--no-quit-on-ctrl-d"], stdout=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, text=True, errors="replace")
    return proc, proc.stdout


def run_window(args):
    import tkinter as tk
    from PIL import Image, ImageTk
    font = np.array(load_font(), dtype=np.uint8)
    pal = np.array(load_palette(), dtype=np.uint8)
    scr = Screen()
    lines = queue.Queue()
    log = open(args.log, "a", encoding="ascii", errors="replace") if args.log else None

    if args.replay:
        src, proc = open(args.replay, errors="replace"), None
    else:
        proc, src = nios_terminal()

    def reader():
        for line in src:
            lines.put(line)
        lines.put(None)
    threading.Thread(target=reader, daemon=True).start()

    root = tk.Tk()
    root.title("DE2 MAGIC PEN (보드 화면 중계)")
    root.configure(bg="black")
    # 처음 크기: 화면에 들어가는 가장 큰 배율(작업 표시줄·제목 줄 몫으로 120픽셀 남김)
    fit = min((root.winfo_screenwidth() - 40) / W, (root.winfo_screenheight() - 120) / H)
    scale = min(args.scale or fit, fit)
    root.geometry("%dx%d" % (int(W * scale), int(H * scale)))
    label = tk.Label(root, bg="black", borderwidth=0)
    label.pack(fill="both", expand=True)
    state = {"photo": None, "ended": False, "size": None}

    def tick():
        n = 0
        while n < 2000:                    # 한 번에 너무 오래 붙잡지 않게
            try:
                line = lines.get_nowait()
            except queue.Empty:
                break
            n += 1
            if line is None:
                if not state["ended"]:
                    print("[screen.py] 보드 연결이 끝났다 (nios2-terminal 종료)")
                state["ended"] = True
                break
            if line.startswith("@"):
                scr.apply(line)
            else:
                sys.stdout.write(line)
                if log:
                    log.write(line)
        # 창 크기에 맞춰 가로세로 비율을 지키며 그린다. 창을 늘리고 줄여도 따라간다.
        size = (max(label.winfo_width(), 64), max(label.winfo_height(), 48))
        if scr.dirty or size != state["size"]:
            img = Image.fromarray(scr.render(font, pal))
            k = min(size[0] / W, size[1] / H)
            target = (max(int(W * k), 1), max(int(H * k), 1))
            # 정수 배율이면 픽셀을 그대로 키우고(가장 선명), 아니면 부드럽게 줄인다(글자가 덜 깨진다)
            img = img.resize(target, Image.NEAREST if k == int(k) else Image.LANCZOS)
            state["photo"] = ImageTk.PhotoImage(img)
            label.configure(image=state["photo"])
            state["size"] = size
            scr.dirty = False
        root.after(30, tick)

    def close():
        if proc:
            proc.terminate()
        if log:
            log.close()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", close)
    root.after(30, tick)
    root.mainloop()


def check(screen_txt):
    """nios/test_host.c가 만든 relay 줄을 적용한 결과가 펌웨어 화면(같은 실행의 칸 덤프)과 같은지."""
    scr = Screen()
    stream = open(screen_txt + ".relay").read().splitlines()
    for line in stream:
        assert scr.apply(line), line
    want = np.array([[int(v) for v in l.split()] for l in open(screen_txt) if l.strip()]).reshape(30, 80, 2)
    got = np.stack([scr.cells & 0xFF, scr.cells >> 8], -1)
    assert (got == want).all(), np.argwhere(got != want)[:5]
    assert scr.cursor == (1, 8, 60, 170) and scr.bitmap[20, 10] and scr.bitmap[170, 60] and scr.bitmap.sum() > 200
    assert sum(l.startswith("@P") for l in stream) == 1               # 같은 커서는 한 번만 보낸다
    assert sum(l.startswith("@T 0 ") for l in stream) == 2            # 처음 + 다시 보내기
    # 깨진 줄은 상태를 망가뜨리지 않는다
    before = scr.cells.copy()
    for bad in ("@T 3 5 12", "@T 99 0 0041", "@L 1 2", "@P x y", "@Q", "@T"):
        assert not scr.apply(bad), bad
    assert (scr.cells == before).all()
    img = scr.render(np.array(load_font(), dtype=np.uint8), np.array(load_palette(), dtype=np.uint8))
    assert img.shape == (H, W, 3)
    # 커서 픽셀은 커서 색(팔레트 8)이어야 한다: 커서 중심에서 오른쪽으로 5픽셀
    assert tuple(img[BM_Y0 + 2*170, BM_X0 + 2*60 + 5]) == tuple(load_palette()[8])
    print("screen OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", help="'@'가 아닌 줄(수집 로그)을 이 파일에 덧붙인다")
    ap.add_argument("--scale", type=float, default=0, help="처음 창 배율. 생략하면 화면에 맞춘다")
    ap.add_argument("--replay", help="보드 대신 저장된 출력 파일을 읽는다(시험용)")
    ap.add_argument("--check", metavar="SCREEN_TXT")
    args = ap.parse_args()
    if args.check:
        return check(args.check)
    if args.log:
        os.makedirs(os.path.dirname(os.path.abspath(args.log)), exist_ok=True)
    run_window(args)


if __name__ == "__main__":
    main()
