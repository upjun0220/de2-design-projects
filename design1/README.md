# Design Project #1 — Counter + One Digit Calculator

DE2 보드(Cyclone II EP2C35F672C6), Quartus II 13.0 SP1, **VHDL**. 파일 하나(`src/DE2_Project1.vhd`, 169줄)로 구성한다.
시연 11/26, 최종 보고서 12/21. 평가: 카운터 정상 동작, 사칙연산과 0으로 나누기 예외 처리, 읽기 쉽고 간결한 코드(줄 수 최소화), 소스코드 발표에서의 이해도.

## 동작

스위치는 위로 올리면 1이다.

| 입력 | 카운터 모드 (`SW0` = 0) | 계산기 모드 (`SW0` = 1) |
|---|---|---|
| `SW0` | 0 = 카운터, 1 = 계산기 | |
| `SW1` | 0: +1 / +2 / -1, 1: +5 / +10 / -5 | 연산 선택 (`SW2` `SW1`): 00 덧셈, 01 뺄셈, 10 곱셈, 11 나눗셈 |
| `SW2` | 사용 안 함 | (위와 같음) |
| `SW3` | 사용 안 함 | 0 = 십진수(A, B = 0~9), 1 = 16진수(A, B = 0~F) |
| `SW17~14` | 사용 안 함 | 숫자 A (4비트) |
| `SW13~10` | 사용 안 함 | 숫자 B (4비트) |
| `KEY3 / KEY2 / KEY1` | 증가(+s1) / 증가(+s2) / 감소(-s1) | 사용 안 함 |
| `KEY0` | 0으로 리셋 | 사용 안 함 |
| 표시 | HEX3~0 = 값, LEDR = 값의 이진수 | HEX6 = A, HEX4 = B, HEX3~0 = 결과 |

- 카운터는 0~9999에서 포화(넘치거나 모자라면 끝값에 고정).
- 뺄셈 결과가 음수면 HEX3에 `-`. 나눗셈은 `몫 r 나머지`(7 ÷ 3 → `2 r1`). 0으로 나누면 ` Err`.
- 십진수 모드에서 A나 B가 10 이상이면 그 입력과 결과 칸을 비운다(한 자리 계산기).

**보너스 구현:** LED로 카운터 값 표시(+5), 777 잭팟 — 초록 LED 전체 + HEX7~4에 `7777`(+5), 나눗셈 나머지(+5), 16진수 표시(+5).

## 빌드 (Quartus, 사용자 PC)

1. 프로젝트 이름과 최상위 엔티티를 `DE2_Project1`로 만든다. 장치는 Cyclone II EP2C35F672C6.
2. `src/DE2_Project1.vhd`를 프로젝트에 추가한다.
3. 핀 할당: `quartus/DE2_pins.qsf`의 내용을 프로젝트 `.qsf`에 붙여 넣거나 Assignments → Import Assignments로 가져온다. (출처는 서드파티 저장소 정리본이며 Terasic 공식 파일이 아니다. 결과가 이상하면 DE2 User Manual과 대조한다.)
4. Processing → Start Compilation (Ctrl+L).
5. Tools → Programmer: USB-Blaster, JTAG 모드, `output_files/DE2_Project1.sof`를 선택해 Start. 보드의 RUN/PROG 스위치는 RUN.

## 시뮬레이션 (선택, GHDL)

```bash
sh sim/run_sim.sh
```

`sim/tb.vhd`가 카운터(롱프레스, 포화, 잭팟, LED)와 계산기(십진수·16진수 전 조합, 십진수 모드의 범위 밖 입력)를 검사한다. 마지막 줄이 `TOTAL checks=2154 errors=0`이면 통과.
시뮬레이션은 로직 검증이며 Quartus 합성·핀 할당·보드 동작을 대신하지 않는다.

## 코드 이해와 발표

`docs/DE2_Project1_code_explanation.html`에 줄별 설명, 동작 예시, 발표 예상 질문 15개, 시연 순서가 있다.

## 미확인 사항

- 보너스 포함 최종 버전의 Quartus 컴파일과 보드 동작은 사용자가 확인한다. 컴파일에서 의심되는 곳은 정수 `/`, 상수에 대한 `mod`, `numeric_std`의 `/`(나눗셈)이다.
