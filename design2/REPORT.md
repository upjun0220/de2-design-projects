# DE2 마법 펜 — 자석 펜 서명 식별 (제출용 보고서)

> 뼈대만 있는 초안이다. 숫자는 **실측한 값만** 쓰고, 시뮬레이션 값은 "시뮬레이션"이라고 밝힌다.
> 제출 양식(Journaling, Prompt, MD file)의 세부 요구는 교수님께 확인한다.

팀: 임창현, 윤재국 · 과목: 마이크로프로세서 (2026 가을) · 보드: Altera DE2

## 1. 개요

(무엇을 만들었는가, 한 문단. 서명 "식별"이며 "인증·보안"이 아님을 명시.)

## 2. 설계

- 시스템 구성도
- 위치 복원 (쌍극자 모델, LM 기준선, MLP)
- 서명 전처리와 임베딩 CNN, DTW 기준선, 판정 규칙
- DE2 구성 (Qsys, I²C 마스터, 병렬 MAC, 입출력)

## 3. 구현

(Verilog / Nios II C / Python 역할 분담과 핵심 코드 설명. 이해한 내용 중심으로.)

## 4. 결과

| 항목 | 값 | 측정 방법 | 비고 |
|---|---|---|---|
| 위치 오차 xy | | | |
| 등록자 식별 정확도 | | | |
| FAR / FRR | | | 위협 모델별, 95% 신뢰구간 |
| SW 대 HW 지연 | | | |
| LE / 곱셈기 / 메모리 사용량 | | | 합성 리포트 |

## 5. 한계

(시뮬레이션과 실측의 차이, 표본 크기, 위조 방어 불가, 간섭 등.)

## 6. AI 활용

(어디에 어떻게 썼는가, AI가 틀렸던 사례와 검증 방법. 상세 프롬프트는 `../prompts/`, 작업 과정은 `../journal/`.)

## 7. 참고 문헌

(AirSignatureDB, SVC-onGoing, MLX90393 데이터시트, DE2 User Manual 등.)

관련 연구 후보 (2026-11-18 초록·검색 발췌로만 확인. 수치를 인용하기 전에 본문을 확인한다. 각 수치는 그 논문의 조건 기준이라 우리 것과 직접 비교하지 않는다.)

- 자석 위치 추정, 쌍극자 모델 + LM: "Investigation of the Relationship Between Localization Accuracy and Sensor Array", arXiv 2201.02372 (2022). 센서 배치가 정확도에 미치는 영향. → 6.1 위치 복원의 근거.
- 자력계 2개 3D 입력: K.-Y. Chen 외, "uTrack: 3D Input Using Two Magnetic Sensors", UIST 2013. 초록 평균 약 4.84 mm. → 센서가 적어도 수 mm가 가능하다는 사례.
- 합성 데이터로만 학습한 위치 신경망: W. Xie 외, "MobilePosenet", arXiv 2501.02809 (2025), 실측 1.54 mm. M. Wu 외, arXiv 2211.07556 (2022), 센서 16개 FEM 합성 학습, 실측 4 mm. → 위치 MLP를 시뮬레이션 데이터로 학습한 방식의 근거와 한계(시뮬레이션과 실측의 차이).
- 자석 세기를 미지수로 함께 피팅: D. Taylor, A. Abramson, H. Herr, "Low-Latency Tracking of Multiple Permanent Magnets", MIT. V. Biancalana 외, "Fast, cheap, and scalable magnetic tracker with an array of magnetoresistors", arXiv 2009.00338 / MDPI Instruments 2021. → `pc/gate1.py`가 자석 세기를 함께 푸는 근거.
- 센서 배열 축 정렬 보정: M. Pang 외, "Calibration of a Fluxgate Magnetometer Array and Its Application in Magnetic Object Localization" (2013). → 장착 보정(`MOUNT_ROT`, `MIRROR_XY`)은 이것의 단순한 이산 판이다.
- 자기 스타일러스: R.-H. Liang 외, "GaussSense", UIST 2012 (홀 센서 192개 격자). MagHacker (자력계 112개). → 센서 수가 크게 다른 접근. 센서 4개로 가능한 정도를 대비시키는 용도.
- 자석 펜 서명 선행 특허: US 4800240 (펜 끝 자석과 코일로 서명 속도 비교), US 9285903 (자기 스타일러스와 자력계로 서명 프로파일 비교). → "자석 펜 서명"은 처음이 아니다. "최초"라고 쓰지 않는다.
- 등록 서명 5개 기반 DTW 서명 검증: J. M. Pascual-Gaspar 외, "Practical On-Line Signature Verification", ICB 2009 (MCYT). 5개 기준과의 DTW 거리 평균. → 우리 등록 방식의 기준선. `pc/evaluate.py --agg mean`으로 최소/평균을 비교한다.
- FPGA DTW·동적계획법 가속: Gupta 외, DP-HLS (선형 시스톨릭 배열이 일반적인 구조). Yen 외, SIMD wavefront DTW 구조. → 대각선 단위 PE 배열은 표준 구조다. 새로운 점은 구조가 아니라 센서부터 판정까지 이어지는 통합과 SW/HW 비교라고 쓴다.
