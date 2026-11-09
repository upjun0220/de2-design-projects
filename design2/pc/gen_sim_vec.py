"""시스템 시뮬레이션 펌웨어용 시험 데이터(C 헤더). Python 기준 구현의 답을 함께 넣는다.
실행: python pc/gen_sim_vec.py build/app_sim/sim_vec.h"""
import os
import sys
import numpy as np
import pen_model as pm
from gen_golden import load_weights

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hw"))
import dtw_ref


def arr2d(name, a):
    rows = ",".join("{" + ",".join(str(int(v)) for v in r) + "}" for r in a)
    return "static const int8_t %s[128][8] __attribute__((aligned(4))) = {%s};\n" % (name, rows)


def main(path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    _, x, y = dtw_ref.make_vectors()[0]
    lsb = [1200, -800, 300, -40, 950, -220, 610, 75, -1300, -15, -480, 700]
    o, _ = pm.mlp_forward_int(load_weights(), pm.input_from_lsb(lsb))
    with open(path, "w") as f:
        f.write("#include <stdint.h>\n")
        f.write(arr2d("vec_x", x) + arr2d("vec_y", y))
        f.write("static const uint32_t vec_expected = %d;\n" % dtw_ref.dtw_fast(x, y))
        f.write("static const int32_t vec_lsb[12] = {%s};\n" % ",".join(map(str, lsb)))
        f.write("static const int16_t vec_pos[5] = {%s};\n" % ",".join(map(str, pm.output_to_units(o))))


if __name__ == "__main__":
    main(sys.argv[1])
