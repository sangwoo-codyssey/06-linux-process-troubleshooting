# [Bug] CPU — CPU_MAX_OCCUPY=80% 환경에서 자가측정 부하가 시스템 임계 50% 통과 시 CpuWorker 자가 종료

## 1. Description (현상 설명)

### 한 줄 요약

`CPU_MAX_OCCUPY=80%` 환경에서는 CpuWorker 가 부하를 점진적으로 ramp 하다가, 자가측정 Load 가 시스템 임계 50% 를 통과하는 시점에 `[CRITICAL] CPU Threshold Violated` 로 자가 종료된다.

### 발생 조건

envfile (`MEMORY_LIMIT=512` / `CPU_MAX_OCCUPY=80` / `MULTI_THREAD_ENABLE=false`) 로 `./agent-leak-app` 실행 시, 부팅 메시지에 `[ CPU ] Limit: 80% [WARNING: Recommend Under 50%]` 가 출력된다. CpuWorker 가 5% 부터 시작해 약 25~34초간 ramp 하여 50% 통과 시점에 즉시 종료된다.

## 2. Evidence & Logs (증거 자료)

### 2.1 Before / After 요약

| 지표 | Before (CPU_MAX_OCCUPY=80) | After (CPU_MAX_OCCUPY=40) |
| --- | ---: | ---: |
| 부팅 시나리오 | CPU (WARNING: Recommend Under 50%) | CPU (OK) |
| 생존시간 | 25~34초 종료 | 50초+ 미종료 |
| 임계 동작 | `[CRITICAL] CpuWorker CPU Threshold Violated` | 없음 (정상 cooldown) |
| ramp 도달 peak (자가측정) | 50.29% ~ 53.74% | 40.00% |
| OS 실측 (top %CPU) 최댓값 | 5.0% | (측정 생략, 자가측정 비례 추정) |
| 종료 후 PID | 사라짐 | 유지, 사이클 반복 |

### 2.2 핵심 로그 라인

```
(Before, CPU_MAX_OCCUPY=80)
[ CPU ] Limit: 80%  [WARNING: Recommend Under 50%]
[CpuWorker] Started. Maximum CPU Limit: 80%
[CpuWorker] Current Load: 5.00%
... (선형 ramp)
[CpuWorker] Current Load: 50.29%
[CRITICAL] [CpuWorker] CPU Threshold Violated! (50.29%).
```

```
(After, CPU_MAX_OCCUPY=40)
[ CPU ] Limit: 40%  [ OK ]
[CpuWorker] Started. Maximum CPU Limit: 40%
[CpuWorker] Current Load: 5.00%
... (선형 ramp)
[CpuWorker] Peak reached (40.00%). Starting cooldown...
[CpuWorker] Current Load: 40.00%
[CpuWorker] Current Load: 37.04%
... (점진적 cooldown)
```

### 2.3 시계열 — Before 회차 (CPU_MAX_OCCUPY=80, 1 코어 환경)

`app.log` 의 CpuWorker 자가측정 Load 와 `top -b -d 1` 의 OS 실측 %CPU 를 시간순으로 병합. PID 25699 는 agent 의 child 프로세스 (Rosetta loader 25692 는 항상 0%).

| 시각 | app.log CpuWorker Load (자가측정) | top %CPU (OS 실측) |
| :--- | ---: | ---: |
| 01:55:22 | 5.00% | 0.0 |
| 01:55:25 | 14.06% | 0.0 |
| 01:55:28 | 18.67% | 0.0 |
| 01:55:31 | 24.49% | 3.0 |
| 01:55:34 | 33.90% | 3.0 |
| 01:55:37 | 35.11% | 4.0 |
| 01:55:40 | 44.76% | 5.0 |
| 01:55:43 | 44.85% | 4.0 |
| 01:55:47 | 50.29% + [CRITICAL] CPU Threshold Violated | (종료) |

### 2.4 시계열 — After 회차 (CPU_MAX_OCCUPY=40, 사이클 1회)

ramp 와 peak, cooldown 의 한 사이클이 그대로 관찰된다. 임계 50% 통과 없이 peak 40% 에서 정상 cooldown 으로 진입한다.

| 시각 | app.log CpuWorker Load (자가측정) | 비고 |
| :--- | ---: | :--- |
| 02:40:56 | 5.00% | ramp 시작 |
| 02:40:59 | 5.95% | |
| 02:41:02 | 7.30% | |
| 02:41:05 | 12.56% | |
| 02:41:08 | 16.23% | |
| 02:41:11 | 21.36% | |
| 02:41:14 | 26.19% | |
| 02:41:17 | 30.25% | |
| 02:41:21 | 35.63% | |
| 02:41:23 | — | `Peak reached (40.00%). Starting cooldown...` |
| 02:41:24 | 40.00% | peak |
| 02:41:27 | 37.04% | cooldown |
| 02:41:30 | 33.09% | |
| 02:41:33 | 27.49% | |
| 02:41:36 | 17.65% | |
| 02:41:39 | 11.44% | |
| 02:41:42 | 10.37% | (실험 종료, 미종료) |

### 2.5 측정 도구별 spike 캡처 가능성

| 측정 도구 | 측정 방식 | spike 캡처 |
| --- | --- | --- |
| `app.log` CpuWorker Current Load | agent 자가측정 | 가능 (5 → 50%+ ramp 그대로 보임) |
| `monitor.log` APP_CPU | ps `%cpu` 누적 평균 | 불가 (시간 따라 평탄화) |
| `top -b -d 1 -p PID` | 1초 순간값 (OS 실측) | 불가 (0~5% 만, 멀티코어/단일코어 무관) |
| `htop` CPU% | top 과 동일 메커니즘 | 불가 |

OS 실측이 0~5% 에 머무는 것은 코어 수와 무관하다 (1 코어 / 10 코어 환경에서 동일). 자가측정 Load 와 OS 실측이 다른 의미를 가진다는 사실 자체가 본 시나리오의 진단 포인트다.

## 3. Root Cause Analysis (원인 분석)

### 3.1 데이터 정합

- `app.log` 의 `[CpuWorker] Current Load` 는 약 3초 간격으로 출력되며, 시작값 5% 부터 점진적으로 증가하는 ramp 패턴을 가진다.
- ramp 속도는 회차마다 다소 변동되어 (시스템 부하 영향 추정), 50% 통과 시점이 25~34초 사이에 나타난다.
- `top -b -d 1 -p PID` 로 1초 간격 실시간 %CPU 를 측정해도 child PID 의 OS 실측 사용량은 0~5% 사이를 변동할 뿐, 자가측정 Load 와는 기울기·절댓값 모두 일치하지 않는다.
- Rosetta loader PID 와 child PID 가 각각 별도 프로세스로 보이며, 부하는 child PID 에 집중된다.
- `CPU_MAX_OCCUPY=20` 환경에서는 50초 안에 ramp + cooldown 사이클이 2회 완전 반복되어, peak amplitude 가 작을수록 사이클 주기가 짧아진다는 추가 관찰이 가능하다.

### 3.2 원인 분석 (CPU 과점유)

agent-leak-app 의 CpuWorker 는 가동 시작 시 5% 부하로 시작해 점진적으로 부하 비율을 증가시킨다 (자가측정 기준). 환경변수 `CPU_MAX_OCCUPY` 가 ramp 의 목표 peak 를 지정한다. 그러나 시스템이 인정하는 임계 (자가측정 기준 고정 50%) 가 별도로 존재하며, ramp 도중 50% 를 통과하는 순간 CpuWorker 가 [CRITICAL] CPU Threshold Violated 라인을 출력하고 프로세스를 자가 종료한다.

즉 `CPU_MAX_OCCUPY` 의 ramp 목표값이 시스템 임계 50% 보다 크면 항상 자가 종료를 유발한다. `CPU_MAX_OCCUPY=80` 은 위험 영역에 해당한다.

### 3.3 시스템 동작 (CPU_MAX_OCCUPY 에 따른 분기)

envfile 의 `CPU_MAX_OCCUPY` 값에 따라 ramp 의 도달 가능성이 갈린다.

**(Before) CPU_MAX_OCCUPY=80 — 위험 영역 (50% 초과 목표)**

- 부팅 시 `[ CPU ] Limit: 80% [WARNING: Recommend Under 50%]` 출력
- CpuWorker 가 5% → 80% 목표로 ramp 시작
- 50% 통과 시점에 즉시 `[CRITICAL] CPU Threshold Violated` 로 자가 종료
- PID 가 사라지며 프로세스 종료

**(After) CPU_MAX_OCCUPY ≤ 50 — 안전 영역**

- 부팅 시 `[ CPU ] Limit: XX% [ OK ]` 출력 (WARNING 없음)
- CpuWorker 가 peak 도달 시 `Peak reached. Starting cooldown...` 로 cooldown 진입
- cooldown 이 약 5% 까지 떨어지면 `Cooldown complete. Resuming load increase...` 후 ramp 재개
- ramp 와 cooldown 사이클이 반복되며 프로세스가 영구 생존
- peak amplitude 가 작을수록 사이클 주기가 짧다 (예: 20% peak 시 약 30초, 40% peak 시 약 50초+)

이는 OS-level signal (외부에서 보내는 SIGKILL/SIGTERM) 이 아니라, agent 가 자기 자가측정으로 임계 도달을 인식하여 자체적으로 종료하는 내부 보호 메커니즘이다. 미션 §4.3 의 Watchdog 정책에 해당한다.

### 3.4 측정 도구의 함정 — 학습자 가설 검증 과정

CPU 시나리오 분석 도중, `htop` 으로 agent-leak-app 의 CPU% 를 봐도 자가측정 Load 와 같은 spike (50% 근처) 가 보이지 않는 현상이 관찰되었다. 이를 설명하기 위해 다음 가설을 차례로 검증했다.

| 가설 | 검증 방법 | 결과 |
| --- | --- | --- |
| (1) 측정 시점이 ramp 초반이라 spike 가 짧음 | `top -b -d 1` 로 25초간 연속 캡처 | ✗ 반박. 25초 캡처해도 최댓값 5% |
| (2) `monitor.log` APP_CPU 가 ps 누적 평균이라 평탄화 | ps 정의 확인 | ○ 부분 맞음. 하지만 다른 도구도 비슷 |
| (3) `htop`/`top` CPU% 가 시스템 전체 기준 (10 코어 분산) | docker `--cpus=1` 로 단일 코어 환경에서 재실험 | ✗ 반박. 1 코어 환경에서도 OS 실측 0~5% |
| (4) Rosetta translation 측정 오버헤드 | Rosetta loader PID 와 child PID 분리 관찰 | △ child PID 에 부하 집중, Rosetta loader 는 0% |
| (5) agent 자가측정 ≠ OS 실측 | (1)~(4) 모두 반박/부분맞음 후 남는 가설 | ✓ 확정 |

확정된 결론: CpuWorker 의 `Current Load: XX%` 는 agent 내부의 시뮬레이션 비율 또는 자가 인식 기준값이며, 실제 OS 가 본 CPU 사용량 (0~5%) 과는 다른 의미의 값이다. 시스템 임계 50% 도 자가측정 기준이지 OS 실측 기준이 아니다.

운영 관점의 시사점: 진단 시 자가측정 (`app.log`) 과 OS 실측 (top/htop/ps) 을 둘 다 보면서, 임계 위반의 진짜 기준이 어느 쪽인지 분리해서 판단해야 한다. 한쪽만 보면 실제 spike 는 없는데 종료된 것처럼 보이거나, spike 가 있는데 측정 도구로 안 보이는 상황으로 오해할 수 있다.

## 4. Workaround & Verification (조치 및 검증)

### 4.1 조치

envfile `/home/agent-admin/agent-leak-app.env` 의 `CPU_MAX_OCCUPY` 값을 80 → 40 으로 하향. 시스템 임계 50% 미만의 안전 영역으로 ramp 목표를 옮겨, CpuWorker 가 임계를 통과하지 않고 정상 cooldown 사이클로 동작하도록 한다.

### 4.2 검증 (Before / After)

| 항목 | Before (80) | After (40) | 변화 |
| --- | --- | --- | --- |
| 생존시간 | 25~34초 종료 | 50초+ 미종료 | 종료 → 생존 |
| 임계 동작 | `[CRITICAL] CPU Threshold Violated` | 정상 cooldown | 자가 종료 → 사이클 반복 |
| ramp 도달 peak (자가측정) | 50.29~53.74% (임계 통과 직후) | 40.00% (목표값 도달) | — |
| 부팅 표시 | `WARNING: Recommend Under 50%` | `OK` | 위험 → 안전 |

### 4.3 근본 해결 제안

실제 운영 관점에서는 OOM 시나리오와 동일한 단계적 접근이 적절하다.

1. **우회 조치 (즉시)** — `CPU_MAX_OCCUPY` 를 시스템 임계 50% 미만으로 하향 (권장: 40) 하여 CpuWorker 의 ramp 가 임계를 통과하지 않도록 안전 영역에 두고, peak 도달 후 정상 cooldown 으로 사이클 동작을 확보한다. 본 리포트 §4.1 의 조치가 이에 해당한다.

2. **정공법 (근본)** — 운영 환경에서 CpuWorker 의 ramp 동작 자체가 필요한지 재검토한다. 의도된 부하 시뮬레이션이 아니라 불필요한 CPU 점유라면, CPU 부하를 발생시키는 소스 코드의 원인 (불필요한 polling, busy loop, 비효율 알고리즘 등) 을 식별하고 제거한다. 부하가 제거되면 `CPU_MAX_OCCUPY` 값에 관계없이 CPU 사용량이 baseline 수준에 머물러야 한다.

우회 조치는 안전 영역에서 시스템 동작을 즉시 확보할 수 있지만 CPU 부하 자체가 사라진 것은 아니므로, 운영 환경에서는 CPU 사용률 모니터링 (자가측정 + OS 실측 분리 관찰) 과 함께 정공법 작업의 우선순위를 별도로 관리해야 한다.
