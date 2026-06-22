# [Bug] Deadlock — 동시성 모드(MULTI_THREAD_ENABLE=true)에서 두 워커 스레드의 역순 락 획득으로 순환 대기 교착 발생

## 1. Description (현상 설명)

### 한 줄 요약

동시성 모드(`MULTI_THREAD_ENABLE=true`) 환경에서는 두 워커 스레드가 서로 다른 순서로 락을 잡은 뒤 상대가 쥔 락을 무한히 기다리는 순환 대기(deadlock)에 빠진다. 프로세스는 종료되지 않고 PID 가 유지되나, 모든 스레드가 무활동 상태로 영구 정지한다.

### 발생 조건

envfile (`MEMORY_LIMIT=512` / `CPU_MAX_OCCUPY=20` / `MULTI_THREAD_ENABLE=true`) 로 `./agent-leak-app` 실행 시, 부팅 메시지에 `[ THREAD ] Concurrency: True [ WARNING ]` 와 `>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.` 가 출력된다. 기동 약 7초 후 두 워커 스레드가 락 획득 → 교차 대기로 진입하며, 이후 추가 로그 출력 없이 무응답 상태가 무기한 지속된다.

이 현상은 메모리·CPU 자원 부족과 무관하다(RSS 30MB, CPU 0%대 정적). 즉 자원의 양이 아니라 동시성 제어 로직의 결함이다.

## 2. Evidence & Logs (증거 자료)

### 2.1 Before / After 요약

| 지표 | Before (MT=true) | After (MT=false) |
| --- | --- | --- |
| 부팅 분기 | `Concurrency: True [ WARNING ]` + DEADLOCK 경고 | `Concurrency: False [ OK ]` |
| 진입 시나리오 | concurrent transaction processors (strict locking) | Healthy System Monitoring |
| 워커 동작 | 락 획득 후 교차 대기, 영구 정지 | Scheduler 가 Thread-B/C/A 순차 실행, 전부 100% 완료 |
| 프로세스 | PID 유지(살아있음) | PID 유지 |
| 스레드 상태 | 3개 전부 `S(sleeping)`, CPU 0%, 누적 TIME 0:00 | 작업 완료 후 정상 종료/대기 |
| app.log | `WAITING ... BLOCKED` 2줄 이후 침묵 | 정상 워크로드 사이클 지속 |
| APP_RSS_MB | 30.1 고정 | 정상 변동(MemoryWorker 사이클) |

### 2.2 핵심 로그 라인 — Before app.log (MT=true)

```
 [ THREAD ] Concurrency: True 		[ WARNING ]
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.

16:57:11,335 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
16:57:11,335 [WARNING] [System] CAUTION: Strict resource locking is enabled.
16:57:16,339 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
16:57:16,339 [INFO] [Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
16:57:16,340 [INFO] [Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
16:57:16,341 [INFO] [Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
16:57:18,353 [INFO] [Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
16:57:18,353 [INFO] [Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
16:57:18,357 [INFO] [Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
16:57:18,357 [INFO] [Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
(16:57:18 이후 90초+ 추가 출력 없음)
```

락 보유/대기 관계를 정리하면 다음과 같다.

| 스레드 | 보유 중인 락 | 대기 중인 락 | 대기 락 보유자 |
| --- | --- | --- | --- |
| Worker-Thread-1 | Shared_Memory_A | Socket_Pool_B | Worker-Thread-2 |
| Worker-Thread-2 | Socket_Pool_B | Shared_Memory_A | Worker-Thread-1 |

두 스레드가 락을 **서로 다른 순서로** 잡았고(T1: A 먼저 / T2: B 먼저), 각자 보유한 락을 상대가 요구하는 형태로 대기 관계가 원형 고리를 이룬다.

### 2.3 프로세스 / 스레드 스냅샷 — Before (정지 상태)

**[증거1] PID 존재 (`ps -ef | grep agent`)** — 프로세스는 살아있다.

```
agent-a+ 32824     0  ... /run/rosetta/rosetta .../agent-leak-app ./agent-leak-app   (loader)
agent-a+ 32833 32824  ... /run/rosetta/rosetta .../agent-leak-app ./agent-leak-app   (child, 부하 집중)
```

**[증거2] 스레드별 상태 (`ps -L -p 32833`)** — child 의 스레드 3개가 모두 sleeping, CPU 0%, 누적 TIME 0:00.

```
  PID   TID STAT %CPU     TIME COMMAND
32833 32833 SNl   0.0 00:00:00 agent-leak-app   (main)
32833 33004 SNl   0.0 00:00:00 agent-leak-app   (Worker-Thread-1)
32833 33007 SNl   0.0 00:00:00 agent-leak-app   (Worker-Thread-2)
```

**[증거3] 정지 영속성 (78초 간격 2차 스냅샷)** — 16:57:32 → 16:58:50 사이 두 워커의 누적 `TIME` 이 `0:00.00` 그대로다. 락 획득 직후 멈춰 그 이후로 단 한 틱의 CPU 도 쓰지 않았음을 의미한다.

**[증거4] 커널 관점 상태 (`/proc/32833/task/*/status`)**

```
TID 32833: State:	S (sleeping)
TID 33004: State:	S (sleeping)
TID 33007: State:	S (sleeping)
```

스레드가 `R(running)` 이 아니라 `S(sleeping)` 라는 것은 바쁘게 도는 무한 루프(busy-wait)가 아니라, 락이 풀리기를 기다리며 커널에 의해 대기 큐에 들어간 상태임을 보여준다. CPU 를 태우지 않으므로 §2.4 의 CPU 사용량도 0 으로 수렴한다.

### 2.4 시계열 — Before 회차 (monitor.log, 무활동 입증)

OOM/CPU 시나리오가 *변화하는 시계열*(RSS·CPU ramp)로 진단됐다면, deadlock 은 반대로 **변화가 없다는 것 자체**가 증거다.

| 시각 | PIDS | APP_CPU | APP_RSS_MB | THREADS | 비고 |
| :--- | :--- | ---: | ---: | ---: | :--- |
| 16:57:11 | 32824,32833 | 10.1% | 30.2 | 2 | 기동 직후 |
| 16:57:16 | 32824,32833 | 2.5% | 30.1 | 4 | 워커 스레드 생성, 락 획득 |
| 16:57:18 | 32824,32833 | 2.0% | 30.1 | 4 | 교차 대기 진입(BLOCKED) |
| 16:57:30 | 32824,32833 | 0.8% | 30.1 | 4 | 정지 |
| 16:58:01 | 32824,32833 | 0.2% | 30.1 | 4 | 정지 |
| 16:58:49 | 32824,32833 | 0.0% | 30.1 | 4 | 정지(98초 경과) |

- `APP_RSS_MB` 가 16:57:16 이후 **30.1MB 에 완전히 고정**된다. 메모리를 더 할당하지도, 회수하지도 않는다.
- `APP_CPU`(ps 누적 평균)가 2.5% → 0.0% 로 *수렴*한다. 기동 초기에 잠깐 쓴 CPU 의 평균이 시간이 흐르며 0 으로 희석되는 것으로, 신규 CPU 사용이 전혀 없음을 보여준다.
- `THREADS:4` 로 스레드 수는 유지(프로세스·스레드 모두 살아있음)되나 어느 것도 진전이 없다.

### 2.5 After 회차 (MT=false, 대조군)

동일 envfile 에서 `MULTI_THREAD_ENABLE` 만 false 로 바꾸면 부팅 분기가 갈린다.

```
 [ THREAD ] Concurrency: False 		[ OK ]
>>> Scenario Selected: [Healthy System Monitoring]
[Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
[Thread-B] Task Completed. (100%)
[Thread-C] Task Completed. (100%)
[Thread-A] Task Completed. (100%)
[Scheduler] All tasks completed.
```

동시성 모드가 꺼지면 락 경합 자체가 발생하지 않아 Scheduler 가 작업을 순차 실행하고 모두 정상 완료한다. 이후 MemoryWorker / CpuWorker 의 정상 사이클로 이어진다. 즉 `MULTI_THREAD_ENABLE` 은 deadlock 코드 경로를 켜고 끄는 스위치이며, 결함 자체는 동시성 경로 안의 락 획득 로직에 있다.

## 3. Root Cause Analysis (원인 분석)

### 3.1 데이터 정합 (살아있으나 무활동)

세 종류 증거가 같은 결론을 가리킨다.

- **프로세스 계층**: `ps -ef` 상 PID 32824/32833 가 끝까지 존재 → 죽지 않았다.
- **스레드 계층**: `ps -L` / `/proc` 상 3개 스레드가 전부 `S(sleeping)`, 누적 CPU TIME 0:00 불변 → 깨어나 일하지 못한다.
- **자원 계층**: `monitor.log` 상 RSS 30.1MB·CPU 0% 정적 → 자원이 모자란 게 아니라 자원을 쓸 수 없는 상태다.

"프로세스가 살아있다"와 "정상 동작한다"는 다른 명제다. 본 시나리오는 전자는 참, 후자는 거짓인 무응답(hang) 상태다.

### 3.2 원인 분석 (역순 락 획득으로 인한 순환 대기)

agent-leak-app 은 동시성 모드에서 두 개의 공유 자원(`Shared_Memory_A`, `Socket_Pool_B`)을 각각 별도 락으로 보호하며, 두 워커 스레드가 작업을 끝내려면 두 락을 모두 획득해야 한다. 그러나 두 스레드의 락 획득 순서가 다음과 같이 엇갈린다.

- Worker-Thread-1: `Shared_Memory_A` 를 먼저 잡고, `Socket_Pool_B` 를 요구
- Worker-Thread-2: `Socket_Pool_B` 를 먼저 잡고, `Shared_Memory_A` 를 요구

각 스레드가 자기 락을 쥔 채로 상대의 락을 기다리므로, 두 대기 관계가 닫힌 고리를 이루어 어느 쪽도 영원히 진행하지 못한다. 만약 두 스레드가 *동일한 순서*(예: 둘 다 A → B)로 락을 잡았다면, 한 스레드는 첫 락 단계에서 대기하다가 다른 스레드가 두 락을 모두 쓰고 반납한 뒤 진행했을 것이다. 이 경우는 일시적 지연(contention)일 뿐 영구 교착이 아니다. 교착으로 굳는 결정적 조건은 **락 획득 순서가 엇갈렸다는 점**이다.

### 3.3 교착상태 4대 조건 매핑

deadlock 은 다음 4조건이 동시 충족될 때만 성립한다(Coffman conditions). raw 로그에서 각 조건을 입증한다.

| 조건 | raw 증거 | 입증 방식 |
| --- | --- | --- |
| 점유 대기 (Hold and Wait) | `LOCK ACQUIRED: [A]` … `Need [B]` … `WAITING for [B]` | 명시적. 한 스레드가 락을 쥔 채(ACQUIRED) 다른 락을 기다린다(WAITING) |
| 순환 대기 (Circular Wait) | T1(A 보유, B 대기) ↔ T2(B 보유, A 대기) | 명시적. 두 ACQUIRED 와 두 WAITING 이 교차해 닫힌 고리를 형성 |
| 상호 배제 (Mutual Exclusion) | T2 가 A 를 `WAITING`(T1 이 보유 중) | 암묵적. 공유 가능한 자원이라면 기다릴 이유가 없다. 기다린다는 사실이 곧 배타적 점유의 증거 |
| 비선점 (No Preemption) | T2 가 A 를 뺏지 않고 `BLOCKED` 로 유지 | 암묵적. 강제 회수가 가능했다면 멈추지 않았다. 뺏는 대신 멈춰 있다는 것이 비선점의 증거 |

상호 배제·비선점은 로그에 직접 찍히지 않지만, "락" 이라는 동기화 도구의 정의상 항상 참이며, `WAITING ... BLOCKED` 라는 결과가 역으로 그 두 전제의 존재를 증명한다.

### 3.4 시스템 동작 (MULTI_THREAD_ENABLE 에 따른 분기)

envfile 의 `MULTI_THREAD_ENABLE` 값이 코드 실행 경로를 가른다.

**(Before) MULTI_THREAD_ENABLE=true — 동시성 경로**

- 부팅 시 `Concurrency: True [ WARNING ]` + DEADLOCK 경고 출력
- concurrent transaction processors 시나리오로 진입, strict resource locking 활성화
- 두 워커가 역순으로 락을 잡고 교차 대기 → 순환 대기 교착
- 프로세스·스레드는 유지되나 영구 무응답. `PROCESS_DOWN` 마커는 끝내 찍히지 않는다(죽지 않으므로)

**(After) MULTI_THREAD_ENABLE=false — 단일 처리 경로**

- 부팅 시 `Concurrency: False [ OK ]` 출력
- Healthy System Monitoring 시나리오로 진입
- Scheduler 가 작업을 순차 실행하여 락 경합이 발생하지 않음
- 정상 워크로드 사이클(MemoryWorker / CpuWorker)로 이어짐

OOM/CPU 의 임계 동작(MemoryGuard 자가 종료, CpuWorker Watchdog)은 *프로세스를 죽이는* 보호 메커니즘이었지만, deadlock 에는 그런 자가 감지·회복 장치가 동작하지 않는다는 점이 다르다. 자원 한도를 넘긴 게 아니라 로직이 멈춘 것이라, 외부 개입(모니터링·재시작) 없이는 영구히 방치된다.

## 4. Workaround & Verification (조치 및 검증)

### 4.1 조치

envfile `/home/agent-admin/agent-leak-app.env` 의 `MULTI_THREAD_ENABLE` 값을 true → false 로 변경하여 동시성 경로를 비활성화하고, Healthy System Monitoring 시나리오로 진입시킨다.

다만 이 조치는 deadlock 을 유발하는 동시성 처리 기능 자체를 끄는 것이므로, 동시 트랜잭션 처리 능력을 포기하는 기능 축소(degraded) 우회다. 락 로직의 결함이 사라진 것은 아니다.

### 4.2 검증 (Before / After)

| 항목 | Before (true) | After (false) | 변화 |
| --- | --- | --- | --- |
| 진입 시나리오 | concurrent transaction processors | Healthy System Monitoring | 경로 분기 |
| 워커 진행 | 락 획득 후 영구 정지 | 작업 전부 100% 완료 | 정지 → 완료 |
| 스레드 상태 | 3개 전부 sleeping, TIME 0:00 | 정상 진행 | 무활동 → 활동 |
| 응답성 | 무응답(hang) | 정상 사이클 지속 | 교착 → 정상 |
| 동시성 기능 | (교착으로 사용 불가) | 비활성화됨 | 기능 상실 → 기능 미사용 |

### 4.3 근본 해결 제안

deadlock 은 자원량 조정으로는 절대 해결되지 않는(메모리·CPU 를 늘려도 무의미한) 로직 결함이므로, 동시성을 유지하면서 순환 고리를 끊는 정공법이 필요하다.

1. **우회 조치 (즉시)** — `MULTI_THREAD_ENABLE=false` 로 동시성 경로를 비활성화하여 무응답을 즉시 제거한다(§4.1). 단 동시 처리 능력을 잃으므로 임시 대응으로 한정한다.

2. **정공법 (근본)** — 4대 조건 중 하나를 깨도록 락 로직을 수정한다. 순환 대기를 깨는 것이 가장 실용적이다.
   - **락 획득 순서 전역 통일 (lock ordering)** — 모든 스레드가 `Shared_Memory_A → Socket_Pool_B` 와 같은 단일 순서로만 락을 획득하도록 강제하면 순환 고리가 구조적으로 닫힐 수 없다. 가장 표준적인 예방책이다.
   - **락 타임아웃 / tryLock + 백오프** — 일정 시간 내 두 번째 락을 못 잡으면 보유 락을 반납하고 재시도(점유 대기 조건을 깸). 영구 정지 대신 재시도로 전환된다.
   - **락 통합 / 임계 구역 축소** — 두 자원을 하나의 락으로 보호하거나, 두 락을 동시에 보유해야 하는 구간 자체를 없애 락 중첩을 제거한다.

3. **운영 모니터링** — 근본 수정 전까지 교착을 조기에 감지한다.
   - `app.log` 의 `WAITING ... (Status: BLOCKED)` 패턴이 일정 시간 이상 마지막 줄로 고정되면 알람.
   - `ps -L` 의 스레드 누적 `TIME` 정체 또는 `/proc/PID/task/*/status` 의 `S` 상태 지속을 주기 점검.
   - deadlock 은 `PROCESS_DOWN` 으로 잡히지 않으므로, "프로세스 살아있음" 만 보는 헬스체크로는 탐지되지 않는다. 진행성(progress) 기반 헬스체크(최근 로그 갱신 여부 등)를 별도로 둔다.
