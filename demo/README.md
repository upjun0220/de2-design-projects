# 발표 시연용 통합 이미지

Design 1(카운터·계산기)과 Design 2(마법 펜)를 FPGA 하나에 같이 올리고 **`SW9`로 전환**한다. 보드를 다시 굽지 않고 두 과제를 번갈아 보여 줄 수 있다.

| `SW9` | 키·스위치·LED·7세그먼트의 주인 |
|---|---|
| 위(1) | **Design 1** |
| 아래(0) | **Design 2** |

`SW9`는 두 설계 모두 쓰지 않는 스위치다. 두 설계의 소스(`design1/src/DE2_Project1.vhd`, `design2/quartus/de2_top.v`)는 고치지 않았고, `demo_top.v`가 둘을 함께 넣고 입출력만 고른다.

- **두 설계는 항상 같이 돈다.** Design 1을 보여 주는 동안에도 Design 2의 Nios는 계속 돌고 등록된 서명이 남아 있다.
- **Design 1을 보여 줄 때 Design 2는 키를 못 받는다.** `KEY3`(Design 2 리셋)이나 `KEY0`(기준값 재측정)을 눌러도 Design 2는 영향받지 않는다. Design 2의 스위치 값은 `SW9`를 올리기 직전 값으로 고정된다.
- **Design 2를 보여 줄 때 Design 1은 키를 못 받는다.** 카운터 값이 그대로 남는다.
- **LCD, VGA 모니터, 센서는 항상 Design 2 것이다.** Design 1은 쓰지 않는다.
- **Design 1을 보여 주는 동안 LCD 글자는 꺼진다.** `SW9`만은 Design 2에 그대로 들어가고, Nios가 LCD에 "표시 끄기" 명령을 보낸다. `SW9`를 내리면 마지막 글자가 다시 보인다. `LCD_ON`(LCD 전원)은 끄지 않는다. 전원을 끄면 LCD 초기 설정이 지워져 Design 2로 돌아와도 글자가 안 나오기 때문이다.

## 준비 (한 번)

```bash
sh design2/quartus/build.sh     # Design 2 이미지 (이미 있으면 생략)
sh design2/nios/build.sh        # Design 2 프로그램 (이미 있으면 생략)
sh demo/build.sh                # 통합 이미지
```

`demo/build.sh`는 빌드할 때의 `design1/src/DE2_Project1.vhd`를 그대로 넣는다. **Design 1을 고치면 `demo/build.sh`를 다시 돌린다.**
또 Design 2의 Qsys 시스템(`design2/build/q`)을 그대로 가져다 쓴다. 그래서 시스템 ID가 같고, `magic_pen.elf`를 다시 빌드하지 않아도 통합 이미지에서 돈다. **`design2/quartus/build.sh`를 다시 돌리면 시스템 ID가 바뀌므로 `nios/build.sh`와 `demo/build.sh`도 다시 돌린다.**

## 시연 당일

```bash
sh demo/run.sh
```

이 명령이 세 가지를 차례로 한다: FPGA 굽기, Design 2 프로그램 올리기, 노트북 화면 띄우기. **발표가 끝날 때까지 이 창을 닫지 않는다.** 무료판 Nios II라서 프로그래머가 끝나면 CPU가 멈춘다.

이후 순서는 다음과 같다.

1. `SW9`를 내린다(Design 2). LCD에 `SENSORS OK 4/4`가 나오는지 본다.
2. 펜을 패드에서 멀리 두고 `KEY0`을 눌러 기준값을 잡는다.
3. 서명을 등록하고 식별한다(`design2/docs/BRINGUP.md`).
4. `SW9`를 올린다(Design 1). 스위치를 Design 1 표에 맞추고 카운터와 계산기를 보여 준다(`design1/README.md`).
5. `SW9`를 다시 내리면 Design 2로 돌아간다. 등록된 서명은 그대로다.

**스위치를 같이 쓰는 점에 주의한다.**
- Design 1 계산기는 `SW17~10`을 숫자 입력으로 쓴다. Design 2로 돌아오기 전에 **`SW17`(펜 스위치)과 `SW1~0`(모드)을 Design 2에 맞게 되돌린다.**
- Design 2 쪽은 `SW9`를 올리는 순간의 값으로 고정되므로, Design 1을 조작하는 동안에는 문제가 없다.

## 확인 상태

- **Quartus 전체 컴파일 통과(2026-11-23):** 80줄 Design 1(3b6dc90)을 넣었다. 오류 0, 논리 소자 25,524 / 33,216(77 %). Design 2 단독은 72 %였다. 타이밍 여유는 모두 양수(setup 최소 5.087 ns, hold 최소 0.215 ns). 시스템 ID 타임스탬프는 `design2/build/q`와 같다.
- **전환 로직 시뮬레이션 통과:** `sh demo/sim.sh`(ModelSim). 두 설계를 가짜 모듈로 바꿔 끼우고 다음을 검사한다.
  - `SW9`에 따라 출력이 바뀌는지.
  - 상대 설계에 키가 들어가지 않는지.
  - Design 2 스위치가 고정되는지(`SW9`만 통과).
  
  두 설계 자체는 각자의 테스트로 검사한다.
- **보드 동작은 아직 확인하지 않았다.** 시연 전에 실제로 확인해야 한다. 특히 다음 두 가지를 본다.
  - SDRAM: `nios2-download`의 Verify가 통과하는지. Design 2의 클럭 위상 −1 ns는 Design 2 단독 배치에서 찾은 값이다.
  - `SW9` 전환 때 Design 2 등록이 유지되는지.
