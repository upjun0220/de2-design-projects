# 구현 설명 (코드 읽는 순서와 README와 달라진 점)

평가 기준 "이해도"에 대비한 문서다. 각 파일 머리 주석에 입출력과 원리가 있고, 여기서는 전체 흐름과 이유만 적는다.

## 전체 흐름

```
MLX90393 ×4 ─I²C→ hdl/i2c_master.v, hdl/mlx_reader.v      프레임마다 12채널을 레지스터에 올린다 (CPU 없이 동작)
                          │ Avalon
                 nios/main.c 프레임 폴링, 기준값 차감
                 nios/position.c  장착 보정 → 세제곱근 압축 → 정수 MLP → (x,y,z,ux,uy)
                 nios/signature.c 펜 내림 판정, 서명 시작/끝, 128×8 int8 전처리
                 nios/dtw.c  또는  hdl/dtw_accel.v + dtw_array.v  (SW[5]로 전환)
                 nios/decide.c    문턱 판정 → LCD, LED, 7세그
                 hdl/vga_trace.v  펜 궤적을 모니터에 실시간 표시 (하드웨어 선 그리기)
PC: pc/train_mlp.py(가중치) pc/collect.py(수집) pc/gate1.py(오차) pc/evaluate.py(평가)
```

읽는 순서 추천: `hw/dtw_ref.py` → `hdl/dtw_array.v` → `nios/signature.c` → `hdl/mlx_reader.v`.

## 핵심 원리 네 가지

**1. 왜 PE 배열로 DTW를 병렬화할 수 있나.** 칸 (i,j)는 (i-1,j), (i,j-1), (i-1,j-1)만 쓴다. 이들은 모두 i+j가 1 또는 2 작다. 그러니 i+j가 같은 칸(안티대각선)끼리는 서로 의존하지 않아 동시에 계산할 수 있다. `hw/dtw_ref.py`가 순서를 바꿔도 값이 같음을 보인다. 대역 ±16 안에서 안티대각선 하나의 칸은 최대 17개다.

**2. 왜 PE 33개인데 절반씩만 일하나.** PE 하나가 오프셋 d = i−j 하나를 맡는다(−16~+16). x는 위에서 아래로, y는 아래에서 위로 한 PE씩 이동한다. 샘플이 두 클럭마다 들어가므로 x[i]와 y[j]는 d = i−j인 PE에서 시각 i+j에 정확히 만난다. PE는 두 클럭에 한 번 일한다. 남는 클럭을 파이프라인으로 써서 첫 클럭에 L1 거리, 다음 클럭에 min+덧셈을 한다. 그래서 곱셈기가 없고 50 MHz를 넘긴다. 공유로 17개까지 줄일 수 있으나 설명이 어려워져 쓰지 않았다. 자원이 모자라면 그때 바꾼다.

**3. 왜 자기장에 세제곱근을 취하나.** 쌍극자 자기장은 거리의 세제곱에 반비례한다. 펜이 가까우면 수 mT, 멀면 수 µT로 범위가 천 배가 넘는다. 그대로 넣으면 MLP가 큰 값에만 반응한다. 세제곱근은 r⁻³을 r⁻¹로 만들어 범위를 약 10배로 줄인다.

**4. 왜 φ 대신 ux, uy인가.** 아래 "달라진 점" 2번.

## README·기획서와 달라진 점 (팀 확인 필요)

| # | README | 구현 | 이유 |
|---|---|---|---|
| 1 | DTW 레지스터에 QUERY_ADDR, TEMPL_ADDR | 없음. CPU가 가속기 내부 RAM 창에 직접 쓴다 | README가 온칩 RAM(≤25 템플릿)을 기본으로 했으므로 주소 레지스터가 필요 없다. CTRL, STATUS, N_TEMPL, CYCLES, RESULT 주소는 README와 같다 |
| 2 | 입력 채널 x,y,z,vx,vy,**θ,φ**,pen | x,y,z,vx,vy,**ux,uy**,pen | φ는 ±180°에서 값이 튄다. DTW는 이것을 큰 거리로 본다. 펜이 거의 수직이면 φ 자체가 불안정하다. 기울기 벡터의 xy 성분은 연속이다 |
| 3 | 슬롯 `SW[4:2]` 0~7 (8명) | 0~4 (5명) | 사람당 5개 × 5명 = 템플릿 25개가 RAM 한계다. 더 넣으면 M4K 사용량이 58%에서 크게 늘어난다 |
| 4 | Qsys에 VGA Pixel Buffer, Character LCD(University Program) | VGA는 직접 만든 `hdl/vga_trace.v`(320×240, 1비트, 2D 궤적). LCD는 표준 `altera_avalon_lcd_16207` | 이 PC에 University Program IP가 설치되어 있지 않다. 3D 표시·한글 이름은 없다 |
| 5 | 대역 값, 윈도 | 사람과의 거리 = 그 사람 템플릿 5개 중 **최솟값** | README에 정해져 있지 않았다. 평균과의 비교는 `evaluate.py`에 추가할 수 있다 |
| 6 | 버스 1개 고정 | 레지스터로 센서별 버스·주소 설정 (`config.h`의 `SENSOR_CFG`) | 납땜을 피할 수 있게. 기본값은 README대로 버스 1개 |

코드에 쓰지 않은 것: 임베딩 CNN, VGA 3D 표시와 한글 이름, Nios II 커스텀 명령어. README Tier 2이거나 합의되지 않은 제안이다. CNN은 실제 서명 데이터가 있어야 학습할 수 있다.

## 검증 범위

| 무엇 | 어떻게 | 결과 |
|---|---|---|
| DTW 기준 모델 | 행 순서 = 안티대각선 순서, 셀 수 3952 | 통과 |
| C 코어 | Python과 비트 단위 비교 (`nios/test_host.c`) | 통과. 일부러 넣은 버그 5개 중 4개 검출 |
| DTW 가속기 RTL | ModelSim 테스트 벡터 100개, 템플릿 25개 | 100/100, 비교당 276클럭 |
| I²C 리더 RTL | 동작 모델 센서 4개: 초기화, 프레임 주기, 부호 확장, 주소 탐지, 버스 전환, 리셋 복구, SCL 합선, 데이터시트 타이밍(SCL Low·High, EX→RT 대기) | 통과 |
| VGA RTL | 선 7종을 소프트웨어 Bresenham과 비교, 클리어, 줄·프레임 주기, 픽셀 클럭 위상 | 통과 |
| 시스템 전체 | ModelSim에서 실제 Nios II 코어가 C 코드 실행 (`quartus/sim_system.sh`) | 센서 읽기, MLP가 Python과 일치(캐시 빈 상태 약 2.1 ms). DTW 측정 중 |
| FPGA 전체 | Quartus 컴파일 | 22,852 LE (69 %), 메모리 74 %, 50 MHz 타이밍 여유 +4.80 ns (합성 리포트) |
| 전체 경로 | `pc/sim_e2e.py` 가상 서명 | 끊김 없음. 수치는 실제 식별률이 아니다 |

**확인 못 한 것:** 실제 센서, 실제 SDRAM 타이밍, LCD 표시, JTAG 통신량, 실제 자석의 위치 오차, 실제 사람의 서명. 동작 모델 센서는 데이터시트를 보고 내가 쓴 것이므로, 데이터시트를 잘못 읽었다면 시뮬레이션도 같이 틀린다.
