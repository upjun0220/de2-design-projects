# 물품 도착 후 작업 순서 (브링업)

코드는 미리 작성·시뮬레이션되어 있다. 이 문서는 물품이 온 날 순서대로 따라 하는 절차다.
**실물로 확인한 적이 없다.** 시뮬레이션을 통과했어도 아래에서 처음 드러나는 문제가 있을 수 있다.

## 0. 안전 규칙

- 센서 전원은 **3.3 V(헤더 29번 핀)만** 쓴다. **헤더 11번 핀은 5 V다. 절대 연결하지 않는다.** Cyclone II는 5 V에 견디지 못한다.
- GND는 헤더 12번 또는 30번.
- 센서를 만지기 전에 접지된 금속을 만져 정전기를 뺀다(예비 센서가 없다).

## 1. 빌드 (이미 한 번 통과했다, Windows + Quartus 13.0 SP1)

```bash
sh design2/run_checks.sh
```

```bash
sh design2/quartus/build.sh
```

```bash
sh design2/nios/build.sh
```

결과물: `design2/build/q/output_files/magic_pen_time_limited.sof`, `design2/build/app/magic_pen.elf`.

`_time_limited`는 Nios II/f를 무료판으로 쓴다는 뜻이다. USB-Blaster로 PC와 연결된 동안만 돈다(OpenCore Plus, 포럼 보고이며 보드에서 확인 필요). 시연도 PC를 연결한 채로 한다. 끊고 돌려야 하면 `quartus/create_sys.tcl`의 `impl Fast`를 `Tiny`로 바꾼다(곱셈기가 없어 위치 MLP가 50 Hz를 못 맞출 수 있다).

## 2. 보드에 올리기

Nios II Command Shell에서 (경로는 저장소 기준):

```bash
quartus_pgm -m jtag -o "p;design2/build/q/output_files/magic_pen_time_limited.sof"
```

```bash
nios2-download -g design2/build/app/magic_pen.elf
```

```bash
nios2-terminal
```

센서 없이 먼저 올려 본다. 기대 동작: 터미널에 스캔 결과 없음, LCD에 `SENSORS OK 0/4`, 이어서 `BASELINE`, `READY`.
여기서 멈추면 센서 문제가 아니라 보드·SDRAM 문제다. 가장 의심할 곳은 SDRAM 클럭 위상(`de2_top.v`의 -3 ns)이다.

## 3. 센서 한 개로 I²C 확인 (센서 도착 당일 필수)

처음엔 **센서 1개만** 연결한다. 고장 센서를 빨리 찾고 예비 없는 부품을 보호한다.

| 센서 모듈 | DE2 헤더 (GPIO_0) |
|---|---|
| VIN | 29번 (3.3 V) |
| GND | 30번 |
| SDA | 1번 (`GPIO_0[0]`) |
| SCL | 3번 (`GPIO_0[2]`) |

전원을 켜면 터미널에 `I2C bus 0: device at 0x..`가 나와야 한다.

- 나온 주소를 기록한다(0x18 또는 0x0C로 예상).
- 안 나오면: 오실로스코프로 SDA/SCL이 3.3 V 근처로 올라가는지, 클럭이 나오는지 본다.

## 4. 센서 4개 연결: 두 가지 방법

**권장: 버스 4개, 납땜 없음.** 센서마다 별도의 SDA/SCL을 쓰면 네 개가 같은 주소여도 된다.

| 버스 | SDA 헤더 핀 | SCL 헤더 핀 |
|---|---|---|
| 0 | 1 | 3 |
| 1 | 5 | 7 |
| 2 | 13 | 15 |
| 3 | 17 | 19 |

`nios/config.h`의 `SENSOR_CFG`를 `{ 0x018, 0x118, 0x218, 0x318 }`로 바꾼다((버스 << 8) | 주소, 주소가 0x18일 때). FPGA는 다시 컴파일하지 않는다.
**방법 B: 버스 1개.** README 결정안이다. A0/A1을 3.3 V에 묶어 주소를 0x18~0x1B로 만든다(납땜 필요 가능). 기본값이 이 설정이다.

이전에 "버스를 나누면 표본화 속도가 오른다"고 썼는데 틀렸다. 데이터시트로 계산하면 버스 1개로도 한 프레임 전송이 약 1.5 ms(350 kHz)라 50 Hz에 충분하다(변환 대기 포함 약 9 ms). 또 이 구현은 I²C 마스터가 하나라서 버스를 나눠도 순차로 읽는다. 버스를 나누는 이득은 **납땜과 주소 설정을 없애는 것**이다.

## 5. 장착 교정과 게이트 1

1. 폼보드에 센서 4개를 ±7 cm 모서리에 고정한다. **실제 간격을 자로 잰다.** 기록한 값을 `--half`에 넣는다.
2. 펜에 자석을 붙인다. 펜 없이 `SW[1:0]=10`, KEY0으로 기준값을 잰다.
3. 종이에 ±3 cm, 3 cm 간격의 격자 9점을 그린다.
4. `python design2/pc/collect.py --participant 0 --role genuine --target 0`
5. 왼쪽 아래 점부터 x가 커지는 쪽으로, 펜을 수직으로 약 1초 대고 KEY1을 누른다. 9점 반복. Ctrl+C.
6. 장착 설정 찾기: `python design2/pc/gate1.py 로그파일 --find-mount`. 첫 줄 값을 `nios/config.h`의 `MOUNT_ROT`, `FIELD_SIGN`에 넣는다.
7. 위치 오차: `python design2/pc/gate1.py 로그파일 --rot a b c d --sign s --half 0.07`. **게이트 1 기준 ≤10 mm.**

잔차(µT)가 크게 나오면(수십 µT 이상) 모델이 안 맞는 것이다. 자석 세기 `--m0`, 센서 간격 `--half`를 의심한다.

## 6. 보드용 값 맞추기

실측 자석 세기·간격으로 MLP를 다시 학습한다(약 10~20분).

```bash
cd design2/pc && python train_mlp.py --m0 측정값 --half 측정값 --zmin 측정높이
```

`nios/config.h`의 `Z_DOWN`, `Z_UP`을 조정한다. 펜이 닿았을 때 로그의 z를 보고 그보다 약 3 mm 위, 6 mm 위로 잡는다. 시뮬레이션에서 z 추정에 1~2 mm 오차와 치우침이 있었으므로 실측이 꼭 필요하다.

손·소지품 영향도 이때 잰다: 자석 없이 손만 움직이며 값이 변하는지 본다. 시계·팔찌는 푼다.

## 7. 데이터 수집

수집 전 동의를 받는다. 파일명에는 번호만 쓴다. 데이터는 `pc/data/`에 저장되고 저장소에 올라가지 않는다.

```bash
python design2/pc/collect.py --participant 1 --role genuine --target 1
```

role: `genuine` 본인 / `random` 무작위 / `static` 이미지 보고 따라 쓰기 / `dynamic` 영상 보고 연습 후 따라 쓰기. target은 따라 쓰려는 사람 번호다.

평가: `python design2/pc/evaluate.py`. 날짜를 나눠 수집해야 신뢰할 수 있는 값이 나온다.

## 8. 시연 동작

- `SW[1:0]=01`, `SW[4:2]`=슬롯(0~4), 서명 5회 → 등록. LCD에 `1/5`...`5/5`.
- `SW[1:0]=00` → 식별. `SW[5]`로 SW/HW DTW 전환, 7세그에 지연(µs).
- KEY0 기준값 재측정, KEY1 서명 강제 종료, KEY2 마지막 등록 취소, KEY3 리셋.

슬롯은 0~4(5명)이다. README의 0~7(8명)에서 줄였다. 가속기 RAM에 템플릿 25개만 들어가기 때문이다.

## 9. 막히면 여기부터

| 증상 | 먼저 볼 곳 |
|---|---|
| `nios2-download` 실패, sysid 오류 | `.sof`를 다시 올렸는지. 빌드마다 ID가 바뀐다 |
| 부팅 후 LCD 무반응 | 터미널 출력 확인. SDRAM 클럭 위상. `LCD_ON`, 백라이트는 보드마다 다름 |
| `SENSORS OK` 수가 부족 | 주소·배선, 3장의 스캔 결과 |
| 값이 변하지 않음 | ERR 레지스터, SDA/SCL 파형, `reg2` 설정 |
| 펜을 대도 `SIGNING` 안 뜸 | `Z_DOWN` 값, 기준값 재측정, `MOUNT_ROT`, `FIELD_SIGN` |
| 서명이 조각남 | `Z_UP`, `END_UP_FRAMES` |
| 로그에 프레임 번호가 건너뜀 | JTAG 전송이 밀림. 터미널 외 다른 JTAG 프로그램 종료 |
