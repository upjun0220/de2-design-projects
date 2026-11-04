# 마이크로프로세서 DE2 프로젝트

숭실대학교 마이크로프로세서(2026 가을) 과제 저장소. Altera DE2 (Cyclone II EP2C35F672C6), Quartus II 13.0 SP1.
팀: 임창현, 윤재국 (2인)

| 과제 | 내용 | 언어·도구 | 일정 | 상태 |
|---|---|---|---|---|
| [Design Project #1](design1/) | Counter + One Digit Calculator (보너스 4종 포함) | VHDL, Quartus | 시연 11/26, 최종 보고서 12/21 | 구현·시뮬레이션 완료, 보드 최종 확인 필요 |
| [Design Project #2](design2/) | Open Topic — 자석 펜 서명 식별 ("마법 펜") | Verilog, Nios II C, Python | 준비 11/2~11/22, 리허설 11/20 | 설계 확정, 코드 작업 시작 단계 |

Design 2 평가 기준은 Creativity, Quality, Level of understanding이고, 제출물은 Journaling, Prompt, MD file이다.
(PDF에 이 이상의 세부 양식은 없다. 교수님께 확인할 것.)

## 폴더 구조

```
.
├─ README.md            이 문서
├─ CLAUDE.md            Claude Code가 작업 시작 때 읽는 규칙
├─ .gitignore
├─ design1/             Design Project #1
│  ├─ README.md         사용법, 빌드·시뮬레이션 방법
│  ├─ AI_USAGE.md       AI 사용 기록 (교수님 방침: Design 1은 AI 최소화)
│  ├─ src/              DE2_Project1.vhd
│  ├─ quartus/          DE2_pins.qsf (핀 할당)
│  ├─ sim/              tb.vhd, run_sim.sh (GHDL)
│  └─ docs/             코드 설명 HTML (발표 준비용)
├─ design2/             Design Project #2 (마법 펜)
│  ├─ README.md         ★ 코드 작업의 시작점 (설계·결정·할 일)
│  ├─ REPORT.md         제출용 MD 보고서 뼈대
│  ├─ docs/             기획서, 타당성 검토, 구매 목록
│  ├─ sim/              쌍극자 시뮬레이션 (Python)
│  ├─ pc/               수집 로그 파서, 평가, 학습·양자화
│  ├─ hdl/              Verilog (I²C 마스터, 병렬 MAC, 상위 모듈)
│  ├─ nios/             Nios II C
│  └─ quartus/          프로젝트, Qsys, 핀 할당
├─ journal/             Design 2 제출용 작업 일지 (날짜별)
└─ prompts/             Design 2 제출용 프롬프트 기록
```

## 시작하기

```bash
git clone <이 저장소 주소>
cd <저장소 폴더>
claude            # Claude Code 실행 (CLAUDE.md를 자동으로 읽는다)
```

Design 2 작업은 `design2/README.md`의 6장 "할 일"에서 P0부터 시작한다.
Design 1은 `design1/README.md`를 본다.

## 이 저장소에 올리지 않는 것

- 서명 원시 데이터 (개인정보). `design2/pc/data/`는 `.gitignore`로 제외돼 있다.
- Quartus·Qsys·Nios II 빌드 산출물 (`db/`, `output_files/`, `*.sof` 등).
- 학번·실명이 들어간 제출 파일.
