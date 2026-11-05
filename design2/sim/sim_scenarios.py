import os, re, sys, numpy as np
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sim_sig_tracking.py'), encoding='utf-8').read().split('if __name__')[0]
src = src.replace('M0 = 0.55', 'M0 = 0.9')
src = src.replace('z = 0.045 + 0.004*np.sin(2*np.pi*1.7*t + p[4])', 'z = ZB + ZA*np.sin(2*np.pi*1.7*t + p[4])')
src = src.replace('[(0, 0, 0.05), (-0.03, -0.03, 0.04), (0.03, 0.03, 0.06), (0.03, -0.03, 0.05)]',
                  '[(0, 0, ZB), (-0.03, -0.03, ZB*0.9), (0.03, 0.03, ZB*1.2), (0.03, -0.03, ZB)]')
ns = {'ZB':0.045,'ZA':0.004}
exec(src, ns)
def run(name, S, ZB, ZA, ntraj=3):
    ns['ZB']=ZB; ns['ZA']=ZA
    # peak field check
    bmax=0
    for _ in range(2):
        t,pos,th,ph = ns['make_traj']()
        for i in range(0,len(pos),5):
            B = ns['field'](S,pos[i],ns['M0']*ns['dirv'](th[i],ph[i]))
            bmax=max(bmax,np.abs(B).max())
    r = ns['evaluate'](S, True, ntraj)
    print(f"{name:34s} z={ZB*1e3:4.0f}mm | 최대자기장 {bmax*1e3:6.1f} mT | xy {r[0]:5.2f} mm  z {r[1]:5.2f} mm  기울기 {r[2]:5.1f}도 | 속도상관 {r[5]:.3f}", flush=True)
g = ns['grid']
run("A 현재안: 2x2 ±3cm, 판 위 30mm", g(2,0.03), 0.036, 0.003)
run("B 코너형: 2x2 ±7cm, 종이와 같은 높이", g(2,0.07), 0.010, 0.003)
run("C 허공 높이 8cm: 2x2 ±3cm", g(2,0.03), 0.08, 0.01)
run("D 허공 높이 8cm: 2x2 ±6cm", g(2,0.06), 0.08, 0.01)
run("E 허공 높이 12cm: 2x2 ±6cm", g(2,0.06), 0.12, 0.01)
