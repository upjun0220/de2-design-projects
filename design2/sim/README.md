# sim/

쌍극자 시뮬레이션 코드 (numpy, scipy). 모두 시뮬레이션이며 실측이 아니다. 각 파일의 내용과 결과는 `../README.md` 5장.

- `sim_sensors.py` — 센서 배치별(4/9/16개) 위치 오차
- `sim_interference.py` — 외란이 있을 때 오차
- `sim_layout_opt.py` — 센서 배치 최적화
- `sim_sig_tracking.py` — 서명형 궤적 추적 (z = 4.5 cm, M0 = 0.55 기준)
- `sim_scenarios.py` — `sim_sig_tracking.py`를 M0 = 0.9로 바꿔 확정 구조(모서리 ±7 cm, 판 위 30 mm, 허공 8·12 cm)를 비교. 실행: `python sim/sim_scenarios.py`
