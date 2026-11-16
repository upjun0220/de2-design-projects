"""보드 펌웨어가 만든 문자 화면을 PNG로 그린다(실제 폰트 ROM과 팔레트 사용).

nios/test_host.c가 ui.c를 PC에서 돌려 칸 내용을 파일로 내보내면, 이 스크립트가 hdl/font8x16.v의
글자 모양과 hdl/vga_ui.v의 팔레트로 640x480 그림을 만든다. 보드 없이 화면을 확인하는 용도다.
서명 칸의 비트맵(획, 종이 테두리)과 펜 커서는 여기서 그리지 않는다.

실행: python pc/render_screen.py build/screen.txt build/screen.png
"""
import os
import re
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def load_font():
    txt = open(os.path.join(HERE, "..", "hdl", "font8x16.v")).read()
    rom = [0] * 2048
    for i, v in re.findall(r"rom\[(\d+)\] = 8'h([0-9A-F]{2});", txt):
        rom[int(i)] = int(v, 16)
    return rom


def load_palette():
    txt = open(os.path.join(HERE, "..", "hdl", "vga_ui.v")).read()
    pal = {int(i): v for i, v in re.findall(r"4'd(\d+):\s+palette = 12'h([0-9A-F]{3});", txt)}
    pal[15] = re.search(r"default: palette = 12'h([0-9A-F]{3});", txt).group(1)
    return [tuple(int(c, 16) * 17 for c in pal[i]) for i in range(16)]


def main(src, dst):
    rom, pal = load_font(), load_palette()
    cells = [tuple(int(v) for v in line.split()) for line in open(src) if line.strip()]
    assert len(cells) == 2400, len(cells)
    img = Image.new("RGB", (640, 480))
    px = img.load()
    for i, (ch, attr) in enumerate(cells):
        col, row = i % 80, i // 80
        fg, bg = pal[attr & 15], pal[attr >> 4]
        for y in range(16):
            bits = rom[ch * 16 + y]
            for x in range(8):
                px[col * 8 + x, row * 16 + y] = fg if bits >> (7 - x) & 1 else bg
    img.save(dst)
    print("wrote", dst)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
