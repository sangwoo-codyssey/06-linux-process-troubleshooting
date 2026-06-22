# [Analysis] 로그 패턴 분석을 통한 스케줄링 알고리즘 추론

## 1. 로그 관찰 개요

`agent-leak-app` 의 정상 실행 상태(`MULTI_THREAD_ENABLE=false`, Healthy System Monitoring 시나리오)에서, 기동 직후 Scheduler 가 세 워커 작업(Thread-A/B/C)을 실행한다. 이 작업들의 타임스탬프와 진행률(Progress) 로그를 근거로, 적용된 스케줄링 기법을 역추론한다.

추론의 신뢰도를 위해 서로 다른 두 회차의 Scheduler 로그를 수집하여 실행 순서의 재현성을 함께 확인했다.

## 2. 증거 자료

### 2.1 회차 1 (16:44:52)

```
[Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
[Scheduler] Starting task execution...
16:44:52,396 [Thread-B] Task Started. Calculating... (20%)
16:44:52,448 [Thread-B] Calculating... (40%)
16:44:52,499 [Thread-B] Calculating... (60%)
16:44:52,554 [Thread-B] Calculating... (80%)
16:44:52,610 [Thread-B] Task Completed. (100%)
16:44:52,663 [Thread-C] Task Started. Calculating... (20%)
   ... (C: 40 → 60 → 80) ...
16:44:52,874 [Thread-C] Task Completed. (100%)
16:44:52,927 [Thread-A] Task Started. Calculating... (20%)
   ... (A: 40 → 60 → 80) ...
16:44:53,144 [Thread-A] Task Completed. (100%)
[Scheduler] All tasks completed.
```

### 2.2 회차 2 (17:05:07)

```
[Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
17:05:07,917 [Thread-B] Task Started. Calculating... (20%)
   ... (B: 40 → 60 → 80) ...
17:05:08,128 [Thread-B] Task Completed. (100%)
17:05:08,184 [Thread-C] Task Started. Calculating... (20%)
   ... (C: 40 → 60 → 80) ...
17:05:08,394 [Thread-C] Task Completed. (100%)
17:05:08,445 [Thread-A] Task Started. Calculating... (20%)
   ... (A: 40 → 60 → 80) ...
17:05:08,659 [Thread-A] Task Completed. (100%)
[Scheduler] All tasks completed.
```

### 2.3 두 회차 비교

| 항목 | 회차 1 | 회차 2 |
| --- | --- | --- |
| 등록 순서 | A, B, C | A, B, C |
| 실행 순서 | B → C → A | B → C → A |
| 진행 방식 | 각 작업 20→40→60→80→100% 연속 | 동일 |
| 작업 교체 | 이전 작업 100% 도달 후 다음 시작 | 동일 |

두 회차 모두 실행 순서가 **B → C → A 로 동일**하며, 각 작업이 중간에 끊기지 않고 100% 까지 진행된 뒤에야 다음 작업이 시작된다.

## 3. 패턴 분석 및 결론

### 3.1 선점(Preemption) 여부 — 없음

선점이 있다면 한 작업이 100% 에 도달하기 전에 다른 작업이 끼어드는 교차 실행(interleaving)이 로그에 나타나야 한다. 예를 들어 `B(20%) → B(40%) → C(20%) → B(60%)` 처럼 진행률이 섞여야 한다.

그러나 두 회차 모두 한 작업(B)이 20→100% 까지 연속으로 진행되는 동안 다른 작업의 로그가 전혀 끼어들지 않는다. 작업 교체는 오직 이전 작업이 100% 를 찍은 직후에만 일어난다. 따라서 **이 스케줄러는 비선점(non-preemptive)** 이며, 실행 중인 작업을 강제로 중단시키지 않고 완료까지 실행하는 run-to-completion 방식이다.

### 3.2 알고리즘 후보 판별

| 알고리즘 | 선점 | 본 데이터와의 부합 |
| --- | --- | --- |
| Round-Robin (작은 quantum) | 선점 | 미부합. 작업보다 작은 quantum 이라면 교차 실행이 나타나야 하나 관측되지 않음 |
| Round-Robin (큰 quantum) | 선점 | 구분 불가(아래 §3.3). 작업이 quantum 보다 짧으면 FCFS 와 동일하게 보임 |
| Priority (선점형) | 선점 | 미부합. 선점 자체가 관측되지 않음 |
| FCFS | 비선점 | 부합. 도착 순서대로 한 작업씩 완료까지 실행 |
| Priority (비선점형) | 비선점 | 구분 불가(아래 §3.3) |

비선점·run-to-completion 동작은 **FCFS** 의 정의와 일치하며, 가장 단순한 설명(parsimony)으로 FCFS 를 최선의 추론으로 채택한다. 미션 예시 로그는 interleaving 을 보여 Round-Robin 으로 결론 냈으나, 본 실측 데이터에는 interleaving 이 없으므로 같은 결론은 적용되지 않는다.

다만 "interleaving 이 없다" 가 곧 "Round-Robin 이 아니다" 를 단정하지는 않는다는 점에 유의한다(§3.3).

### 3.3 단정의 한계 — 구분되지 않는 가설들

FCFS 는 본 데이터와 모순 없는 가장 단순한 가설이지만, 다음 두 가설은 같은 로그를 만들어내므로 본 데이터만으로는 배제할 수 없다.

**(1) 비선점 Priority** — 실행 순서가 B → C → A 로 고정이고 등록 순서(A, B, C)와 다르다는 점은 두 가설로 동일하게 설명된다.

- *FCFS 가설* — 스레드가 스케줄러에 도착한 순서가 B, C, A 였고, 스레드 생성이 결정론적이라 매 회차 동일하게 재현된다.
- *비선점 Priority 가설* — 우선순위가 B > C > A 로 부여되어 매번 그 순서로 실행된다.

구별하려면 우선순위의 양성 증거가 필요한데 본 데이터에는 없다. 세 작업의 길이·성격이 동일하여 우선순위 차이가 드러날 여지가 없고, 선점 이벤트(높은 우선순위가 낮은 작업을 중단)도 관측되지 않았다.

**(2) 큰 quantum 의 Round-Robin** — Round-Robin 은 본질적으로 FCFS(FIFO 큐)에 time quantum 기반 선점을 더한 것이며, quantum 이 무한대에 가까우면 FCFS 와 동일하게 동작한다. 본 작업은 하나당 약 260ms 로 매우 짧아, quantum 이 이보다 크기만 하면 각 작업이 첫 quantum 안에 완료되어 선점이 발생하지 않는다. 이 경우 로그는 FCFS 와 구분되지 않는다.

선점을 발현시켜 Round-Robin 을 식별하려면 작업이 quantum 보다 길어야 하는데, 본 작업이 너무 짧아 그 조건을 만들지 못했다. 따라서 "interleaving 없음" 은 "Round-Robin 아님" 이 아니라 "이 작업 길이에서는 Round-Robin 이라도 선점이 발현되지 않음" 으로 해석하는 것이 정확하다.

**결론** — 비선점·run-to-completion 이라는 관측 사실에 가장 단순하게 부합하는 **FCFS 를 최선의 추론으로 채택**하되, 비선점 Priority 와 큰 quantum 의 Round-Robin 은 본 데이터만으로 배제할 수 없다. 이들을 구분하려면 길이가 서로 다른 작업, 우선순위가 명시된 작업, 또는 quantum 보다 긴 작업을 투입하는 추가 실험이 필요하다.

## 4. 장단점 및 적합 아키텍처

### 4.1 FCFS 의 장단점

**장점**
- 구현이 단순하고 동작이 예측 가능하다(도착 순서 = 실행 순서).
- 도착순 처리라 순서 측면에서 공평하며, 컨텍스트 스위칭 오버헤드가 거의 없다(작업당 한 번 실행).

**단점**
- Convoy effect — 앞에 실행 시간이 긴 작업이 오면 뒤의 짧고 급한 작업까지 모두 대기한다.
- 평균 대기 시간이 길어질 수 있고, 대화형/실시간 응답에 부적합하다(작업이 끝날 때까지 다른 작업이 진전하지 못함).

### 4.2 적합한 서비스 성격

FCFS(비선점·run-to-completion)는 **개별 작업이 짧고 균일하며, 응답 지연보다 처리량·단순성·순서 보장이 중요한** 워크로드에 적합하다.

- 적합 — 배치 처리, 작업 큐 소비자(queue consumer), 순서가 보장되어야 하는 트랜잭션 파이프라인. 본 앱처럼 짧고 균일한 작업을 순차 처리하는 백그라운드 워커에 자연스럽다.
- 부적합 — 실시간 응답이 중요한 웹 서버나 대화형 시스템. 긴 작업 하나가 전체 응답성을 막을 수 있으므로, 이 경우 Round-Robin(응답성)이나 Priority(긴급도 반영)가 더 낫다.
